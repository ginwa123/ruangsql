//! SQLite backend used everywhere nalar needs a database. Provides
//! basic `exec` / `query` / `queryRow` for single-statement operations
//! and a `Transaction` RAII type for multi-statement atomic operations.
//!
//! See `sqlite_test.zig` (the canonical documentation of the public
//! API surface) for usage patterns and test coverage.
//!
//! The `c` declarations are platform-scoped (Linux uses `@cImport` with
//! the system sqlite3.h; macOS/Windows use manual extern declarations
//! because the headers aren't on the default include path).

const std = @import("std");
const builtin = @import("builtin");

// Alternative sqlite3_bind_text binding that takes the destructor parameter
// as `isize` (a raw integer) instead of a `sqlite3_destructor_type` function
// pointer. The cImport-generated binding uses the function-pointer type,
// which Zig's comptime alignment check rejects when we try to pass `-1`
// (the SQLITE_TRANSIENT sentinel) because `-1` (= 0xFFFFFFFFFFFFFFFF) is not
// 8-byte aligned on aarch64-macos. At the C ABI level both isize and a
// function pointer occupy one 8-byte register on x86_64/aarch64 — the
// bits pass through unchanged. SQLite's compiled check
// `if (xDel == SQLITE_TRANSIENT)` is a bitwise comparison and succeeds
// regardless of whether we declared the parameter as isize or as a
// function pointer on the Zig side.
// Wrapper for `sqlite3_bind_text` that takes the destructor parameter as
// `isize` (a raw integer) instead of `sqlite3_destructor_type` (a function
// pointer). The cImport-generated binding uses the function-pointer type,
// which Zig's comptime alignment check rejects when we try to construct
// the SQLITE_TRANSIENT sentinel (= -1 cast to a function pointer, but
// `0xFFFFFFFFFFFFFFFF` is not 8-byte aligned on aarch64-macos).
//
// We side-step the alignment check by declaring this wrapper with an
// `isize` destructor parameter. At the C ABI level both `isize` and a
// function pointer occupy one 8-byte register on x86_64/aarch64 — the
// bits pass through unchanged. SQLite's compiled check
// `if (xDel == SQLITE_TRANSIENT)` is a bitwise comparison and succeeds
// regardless of whether we declared the parameter as `isize` or as a
// function pointer on the Zig side.
//
// The `@extern` builtin returns `?*const FnType` (nullable); we unwrap with
// `orelse unreachable` because the symbol is statically linked from
// `vendor/sqlite3/sqlite3.c` on all platforms.
const sqlite3_bind_text_isize_Fn = fn (
    ?*anyopaque,
    c_int,
    [*]const u8,
    c_int,
    isize,
) callconv(.c) c_int;
const sqlite3_bind_text_isize_opt: ?*const sqlite3_bind_text_isize_Fn =
    @extern(*const sqlite3_bind_text_isize_Fn, .{ .name = "sqlite3_bind_text" });
const sqlite3_bind_text_isize: *const sqlite3_bind_text_isize_Fn =
    sqlite3_bind_text_isize_opt orelse unreachable;

pub const Error = error{
    OpenFailed,
    DatabaseNotFound,
    PermissionDenied,
    DiskFull,
    DatabaseCorrupt,
    QueryFailed,
    PrepareFailed,
    BindFailed,
    ExecuteFailed,
    RowNotFound,
    OutOfMemory,
    Canceled,
    /// Returned by any Transaction method (exec/query/queryRow/commit/rollback)
    /// called after the transaction has been completed. Indicates the tx
    /// is single-use and must not be touched again. The mutex is no longer
    /// held, so any further use would race with concurrent writers on the
    /// same backend. The recommended defer pattern is:
    ///   `defer tx.rollback() catch |err| switch (err) {
    ///       error.TransactionClosed => {},
    ///       else => return err,
    ///   };`
    TransactionClosed,
};

/// Cross-platform sqlite3 bindings.
///
/// IMPORTANT: The `c` declarations are scoped INSIDE `SqliteBackend` (lazily
/// resolved when the struct is referenced) — not at file level. The reason is
/// that `@cImport(@cInclude("sqlite3.h"))` requires the sqlite3 header to be
/// present in the compiler's include path AT THE TIME the import is resolved.
/// On macOS, the system's `sqlite3.h` is keg-only and not in the default
/// include path; CI installs only `openssl@3`, not `sqlite3`. Hoisting the
/// `@cImport` to file level would force every translation unit that
/// `@import("Sqlite.zig")`s to provide sqlite3 headers — including the test
/// target, which has no good reason to need them at type-check time. The
/// original (pre-windows-compatibility) code put cImport inside the struct
/// for this reason; we preserve that pattern here.
///
/// On Windows (where vendored sqlite3 is compiled in from source), the
/// `c` is a struct of manual `extern fn` declarations — also evaluated
/// lazily because the struct field of the same name is referenced only
/// when SqliteBackend is actually used.
pub const SqliteBackend = struct {
    const c = @cImport(@cInclude("sqlite3.h"));

    // `SQLITE_TRANSIENT` sentinel — passed as -1 via the
    // `sqlite3_bind_text_isize` wrapper above (which takes isize instead
    // of the cImport-generated `sqlite3_destructor_type` function pointer
    // type). See the long comment on the wrapper for why this matters.
    const SQLITE_DESTRUCTOR_TRANSIENT: isize = -1;

    io: std.Io = .failing,
    db: ?*c.sqlite3 = null,
    mutex: std.Io.Mutex = .init,
    /// Tracks the current transaction nesting depth (0 = no tx active;
    /// 1 = top-level BEGIN in flight; 2+ = nested SAVEPOINT). Incremented
    /// by `begin` / `savepoint`, decremented by `commit` / `rollback`.
    /// Used to choose between `BEGIN` / `COMMIT` (depth 0↔1) and
    /// `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` (depth >= 1).
    transaction_depth: u32 = 0,

    pub fn init(self: *SqliteBackend, io: std.Io, db_path: [:0]const u8) Error!void {
        self.io = io;
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            _ = c.sqlite3_close(db);
            return switch (rc) {
                c.SQLITE_CANTOPEN => Error.DatabaseNotFound,
                c.SQLITE_PERM => Error.PermissionDenied,
                c.SQLITE_FULL => Error.DiskFull,
                c.SQLITE_CORRUPT => Error.DatabaseCorrupt,
                else => error.OpenFailed,
            };
        }
        self.db = db;

        // Enable WAL mode for better concurrent access (crucial for multi-threaded usage)
        // WAL allows concurrent reads and single writer, preventing "database is locked" errors
        // Note: Using null for err_msg - we don't need the error details
        _ = c.sqlite3_exec(db, "PRAGMA journal_mode=WAL;", null, null, null);

        // Also enable busy timeout for better concurrency handling
        _ = c.sqlite3_exec(db, "PRAGMA busy_timeout=5000;", null, null, null); // 5 second timeout
    }

    /// Inner implementation: prepare + bind + step a single SQL statement.
    /// Caller MUST hold the backend mutex. Used by both `exec` (with lock)
    /// and `Transaction.exec` (without re-locking — the tx already holds it).
    fn executeStatement(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!void {
        _ = allocator;
        const db = self.db orelse return Error.DatabaseNotFound;

        // Empty SQL is a successful no-op. sqlite3_prepare_v2 with a
        // zero-length input returns OK with stmt=NULL; calling step()
        // on a NULL stmt is documented as harmless. Treat the whole
        // thing as a no-op up front to avoid the NULL-stmt edge case
        // and to make the documented behavior explicit at the wrapper
        // level (callers don't need to special-case "" themselves).
        if (sql.len == 0) return;

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        defer {
            if (stmt) |s| {
                _ = c.sqlite3_finalize(s);
            }
        }
        if (rc != c.SQLITE_OK) {
            const err_msg = c.sqlite3_errmsg(db);
            std.log.warn("sqlite3 prepare failed: {s} (sql: {s})", .{ err_msg, sql });
            return Error.PrepareFailed;
        }

        for (argv, 0..) |arg, i| {
            const param_idx: c_int = @intCast(i + 1);
            if (arg.len == 0) {
                rc = c.sqlite3_bind_null(stmt, param_idx);
            } else {
                rc = sqlite3_bind_text_isize(@ptrCast(stmt), param_idx, arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
            }
            if (rc != c.SQLITE_OK) {
                return Error.BindFailed;
            }
        }

        while (true) {
            rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_ROW) {
                continue;
            } else if (rc == c.SQLITE_DONE) {
                break;
            } else {
                const err_msg = c.sqlite3_errmsg(db);
                std.log.warn("sqlite3 step failed: {s} (sql: {s})", .{ err_msg, sql });
                return Error.ExecuteFailed;
            }
        }
    }

    pub fn exec(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeStatement(self, allocator, sql, argv);
    }

    /// Inner implementation: prepare + bind + step ONCE for a single-row
    /// SELECT. Caller MUST hold the backend mutex. Used by both `queryRow`
    /// (with lock) and `Transaction.queryRow` (without re-locking).
    fn executeQueryRow(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Row {
        const db = self.db orelse return Error.DatabaseNotFound;

        var stmt: ?*c.sqlite3_stmt = null;
        const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prep_rc != c.SQLITE_OK) {
            return Error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        for (argv, 0..) |arg, i| {
            const bind_rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
            if (bind_rc != c.SQLITE_OK) {
                return Error.BindFailed;
            }
        }

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_ROW) {
            return Error.RowNotFound;
        }

        const col_count = c.sqlite3_column_count(stmt);
        var values = try allocator.alloc([]u8, @intCast(col_count));

        for (0..@intCast(col_count)) |i| {
            const col_text = c.sqlite3_column_text(stmt, @intCast(i));
            if (col_text) |text| {
                const len = c.sqlite3_column_bytes(stmt, @intCast(i));
                values[i] = try allocator.alloc(u8, @intCast(len));
                @memcpy(values[i][0..@intCast(len)], text[0..@intCast(len)]);
            } else {
                values[i] = try allocator.alloc(u8, 0);
            }
        }

        return Row{ .values = values };
    }

    pub fn queryRow(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeQueryRow(self, allocator, sql, argv);
    }

    pub const Rows = struct {
        allocator: std.mem.Allocator,
        stmt: ?*c.sqlite3_stmt,
        /// Non-owning reference to the db, captured at query time. Needed
        /// so that `next()` can call `sqlite3_errmsg(db)` when
        /// `sqlite3_step()` returns an error — the stmt pointer alone
        /// does not give access to the db handle. See `captureError`.
        db: ?*c.sqlite3,
        /// Tracks whether the iterator has reached SQLITE_DONE so that
        /// subsequent `next()` calls short-circuit to null without
        /// re-invoking `sqlite3_step()`. See `next` for the rationale.
        done: bool = false,
        /// Most recent SQLite error message, captured by `next()` when
        /// `sqlite3_step()` returns a non-ROW rc. Owned by Rows; freed
        /// in `deinit`. Callers can read it via `getLastErrorMessage()`
        /// to surface a USEFUL error to the user — without this, the
        /// only signal was the `Error.QueryFailed` enum name and the
        /// raw SQLite message was lost (logged but not returned).
        last_error_msg: ?[]u8 = null,

        pub fn deinit(self: *Rows) void {
            if (self.last_error_msg) |msg| {
                self.allocator.free(msg);
                self.last_error_msg = null;
            }
            if (self.stmt) |s| {
                _ = c.sqlite3_finalize(s);
            }
        }

        /// Capture `sqlite3_errmsg(db)` into `last_error_msg` so callers
        /// can surface it. Best-effort: silently no-ops when `db` is
        /// null (backend closed) or when allocation fails — the caller
        /// still gets the Error enum either way, this just enriches it.
        fn captureError(self: *Rows) void {
            if (self.db) |d| {
                const err_msg_c = c.sqlite3_errmsg(d);
                const span = std.mem.span(err_msg_c);
                if (self.last_error_msg) |old| self.allocator.free(old);
                self.last_error_msg = self.allocator.dupe(u8, span) catch null;
            }
        }

        /// Returns the most recent SQLite error message, or null if no
        /// error has been captured yet. The returned slice is owned by
        /// Rows and is valid until `deinit()` is called.
        pub fn getLastErrorMessage(self: *Rows) ?[]const u8 {
            return self.last_error_msg;
        }

        pub fn next(self: *Rows) Error!?Row {
            // Defensive: once we've returned null (DONE) for a query,
            // subsequent calls should keep returning null without
            // re-invoking sqlite3_step. Empirically, calling step()
            // after DONE on a SELECT can return ROW again (with the
            // same row data) on some SQLite versions/configurations —
            // which would surface as a duplicated final row in the
            // caller's loop. Track the done state explicitly so we
            // don't depend on sqlite's rc-after-DONE behavior.
            if (self.done) return null;
            const rc = c.sqlite3_step(self.stmt);
            if (rc == c.SQLITE_DONE) {
                self.done = true;
                return null;
            }
            if (rc == c.SQLITE_MISUSE) {
                // The statement has already returned DONE and step()
                // was called again. Treat the same as DONE.
                self.done = true;
                return null;
            }
            if (rc != c.SQLITE_ROW) {
                // Capture the SQL error message so callers can surface it
                // (e.g. "fts5: syntax error" instead of bare "QueryFailed").
                self.captureError();
                return Error.QueryFailed;
            }

            const col_count = c.sqlite3_column_count(self.stmt);
            const values = self.allocator.alloc([]u8, @intCast(col_count)) catch return Error.OutOfMemory;

            for (0..@intCast(col_count)) |i| {
                const col_text = c.sqlite3_column_text(self.stmt, @intCast(i));
                if (col_text) |text| {
                    const len = c.sqlite3_column_bytes(self.stmt, @intCast(i));
                    values[i] = self.allocator.alloc(u8, @intCast(len)) catch return Error.OutOfMemory;
                    @memcpy(values[i][0..@intCast(len)], text[0..@intCast(len)]);
                } else {
                    values[i] = self.allocator.alloc(u8, 0) catch return Error.OutOfMemory;
                }
            }

            return Row{ .values = values };
        }
    };

    pub const Row = struct {
        values: [][]u8,

        pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
            for (self.values) |v| {
                allocator.free(v);
            }
            allocator.free(self.values);
        }
    };

    /// A database transaction. Mirrors Go's `sql.Tx` — acquire one via
    /// `SqliteBackend.begin()` (top-level) or `SqliteBackend.savepoint(name)`
    /// (nested). Run statements with the tx methods, then `commit()` to make
    /// changes permanent or `rollback()` to discard them.
    ///
    /// **Mutex semantics:** The `SqliteBackend.mutex` is acquired and held
    /// for the entire lifetime of the transaction. Concurrent `exec`/`query`
    /// calls from other threads block until `commit()`/`rollback()` releases
    /// it. DO NOT call `db.exec()` / `db.query()` from within the same thread
    /// that holds a tx — `std.Io.Mutex` is NOT reentrant; calling a
    /// lock-acquiring method on the backend from inside `tx.exec` will
    /// deadlock. Use `tx.exec` / `tx.query` / `tx.queryRow` instead.
    ///
    /// **Single-use:** All methods (`exec`, `query`, `queryRow`, `commit`,
    /// `rollback`) return `Error.TransactionClosed` if called after a
    /// successful `commit()` or `rollback()`. This is a SAFETY check, not
    /// ergonomics: after the mutex is released by commit/rollback, any
    /// further `tx.*` call would invoke SQL on the underlying connection
    /// WITHOUT the mutex held, racing with concurrent writers. Returning an
    /// error prevents the UB. The recommended idiom is:
    ///
    /// ```zig
    /// var tx = try db.begin();
    /// defer tx.rollback() catch |err| switch (err) {
    ///     error.TransactionClosed => {}, // already committed/rolled back
    ///     else => return err,
    /// };
    /// ```
    ///
    /// The `defer tx.rollback() catch |err| switch(err) { error.TransactionClosed => {}, ... }`
    /// pattern mirrors Go's `defer tx.Rollback()` (which silently succeeds
    /// on `sql.ErrTxDone`); the explicit switch is required because Zig
    /// surfaces all errors.
    ///
    /// **Borrowed slices:** As with the non-tx `Row` type, slices returned
    /// from `tx.queryRow()` / `tx.query()` are allocated by the caller's
    /// allocator; the caller must call `Row.deinit(allocator)` to free them.
    pub const Transaction = struct {
        backend: *SqliteBackend,
        depth: u32,
        completed: bool = false,

        pub fn exec(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
            if (self.completed) return Error.TransactionClosed;
            return executeStatement(self.backend, allocator, sql, argv);
        }

        pub fn queryRow(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
            if (self.completed) return Error.TransactionClosed;
            return executeQueryRow(self.backend, allocator, sql, argv);
        }

        pub fn query(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
            if (self.completed) return Error.TransactionClosed;
            return executeQuery(self.backend, allocator, sql, argv);
        }

        /// Internal helper: run COMMIT (or RELEASE sp_<n> for nested tx),
        /// decrement depth, release the mutex on the outermost commit,
        /// and flip `completed`. Shared between `commit` (which gates
        /// on `completed` first and returns `TransactionClosed` on
        /// re-finalization) and `commitOrRollback` (which silently
        /// no-ops on re-finalization).
        ///
        /// MUST NOT be called directly — callers are `commit` and
        /// `commitOrRollback`, which both gate on `self.completed`
        /// BEFORE calling this helper. Calling without the gate
        /// would skip the re-finalization check and could release
        /// the mutex twice (UB).
        fn _doFinalizeCommit(self: *Transaction) Error!void {
            const db = self.backend.db orelse {
                self.completed = true;
                // On backend-closed: depth is a property of the backend
                // (not the connection), so we decrement it for consistency.
                // Only release the mutex on the outermost commit/rollback —
                // inner savepoints hold the mutex on behalf of the outer tx.
                self.backend.transaction_depth -= 1;
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.DatabaseNotFound;
            };

            // SQL depends on depth:
            //   depth == 1 → top-level COMMIT
            //   depth >= 2 → RELEASE for the matching SAVEPOINT
            var sql_buf: [32:0]u8 = undefined;
            const sql_slice = if (self.depth == 1)
                std.fmt.bufPrint(sql_buf[0..31], "COMMIT", .{}) catch return Error.ExecuteFailed
            else
                std.fmt.bufPrint(sql_buf[0..31], "RELEASE sp_{d}", .{self.depth}) catch
                    return Error.ExecuteFailed;
            sql_buf[sql_slice.len] = 0;

            const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
            self.completed = true;
            self.backend.transaction_depth -= 1;
            // Only the OUTERMOST commit releases the mutex. An inner
            // savepoint commit (depth >= 2) leaves the mutex held so
            // the surrounding outer transaction can keep using it.
            if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);

            if (rc != c.SQLITE_OK) {
                return Error.ExecuteFailed;
            }
        }

        pub fn commit(self: *Transaction) Error!void {
            if (self.completed) return Error.TransactionClosed;
            return self._doFinalizeCommit();
        }

        /// Commit the transaction if it has not yet been finalized. If the
        /// transaction was already committed or rolled back, this is a no-op
        /// returning success (NOT `Error.TransactionClosed` — that would defeat
        /// the point of the defer-idiom). Mirrors Go's
        /// `(*Tx).CommitOrRollback` (Go 1.21+).
        ///
        /// The recommended defer-idiom for transactions:
        ///
        /// ```zig
        /// var tx = try db.begin();
        /// defer tx.commitOrRollback() catch {}; // commits if not yet finalized
        /// // ... use tx ...
        /// ```
        ///
        /// This replaces the more verbose pattern:
        ///
        /// ```zig
        /// defer tx.rollback() catch |err| switch (err) {
        ///     error.TransactionClosed => {}, // already committed
        ///     else => return err,
        /// };
        /// ```
        ///
        /// **Why use commitOrRollback instead of `commit` in defer?**
        /// Because if your code path called `commit()` explicitly before the
        /// defer fired, `commitOrRollback` is a silent no-op — whereas
        /// `tx.commit()` would return `Error.TransactionClosed` (and the catch
        /// would log it). Both are correct; commitOrRollback is just
        /// ergonomically cleaner for the deferred-finalize pattern.
        ///
        /// **Why use commitOrRollback instead of `rollback` in defer?**
        /// Same reason: if `commit()` ran before the defer fired,
        /// `rollback()` returns `Error.TransactionClosed`. The
        /// `defer rollback() catch switch(TransactionClosed => {})` pattern
        /// works but is verbose.
        ///
        /// **Error semantics:**
        /// - If the COMMIT (or RELEASE for nested tx) SQL fails: returns
        ///   `Error.ExecuteFailed`. `completed` is set so a future
        ///   `rollback()` returns `TransactionClosed`.
        /// - If the backend was deinitialized during the tx: returns
        ///   `Error.DatabaseNotFound`.
        /// - Otherwise: returns success.
        pub fn commitOrRollback(self: *Transaction) Error!void {
            if (self.completed) return; // already finalized — silent no-op
            return self._doFinalizeCommit();
        }

        pub fn rollback(self: *Transaction) Error!void {
            if (self.completed) return Error.TransactionClosed;
            const db = self.backend.db orelse {
                self.completed = true;
                self.backend.transaction_depth -= 1;
                // Same depth-gated mutex release as commit(): only the
                // outermost rollback actually frees the lock.
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.DatabaseNotFound;
            };

            var sql_buf: [32:0]u8 = undefined;
            const sql_slice = if (self.depth == 1)
                std.fmt.bufPrint(sql_buf[0..31], "ROLLBACK", .{}) catch return Error.ExecuteFailed
            else
                std.fmt.bufPrint(sql_buf[0..31], "ROLLBACK TO sp_{d}", .{self.depth}) catch
                    return Error.ExecuteFailed;
            sql_buf[sql_slice.len] = 0;

            const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
            self.completed = true;
            self.backend.transaction_depth -= 1;
            // See commit() above — inner savepoint rollback must NOT
            // release the mutex; the outer transaction is still alive.
            if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);

            if (rc != c.SQLITE_OK) {
                return Error.ExecuteFailed;
            }
        }
    };

    /// Inner implementation: prepare + bind a SELECT statement, returning
    /// a `Rows` iterator. Caller MUST hold the backend mutex. Used by
    /// both `query` (with lock) and `Transaction.query` (without re-locking).
    fn executeQuery(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Rows {
        const db = self.db orelse return Error.DatabaseNotFound;

        var stmt: ?*c.sqlite3_stmt = null;
        const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prep_rc != c.SQLITE_OK) {
            return Error.PrepareFailed;
        }

        for (argv, 0..) |arg, i| {
            const bind_rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
            if (bind_rc != c.SQLITE_OK) {
                _ = c.sqlite3_finalize(stmt);
                return Error.BindFailed;
            }
        }

        return Rows{
            .allocator = allocator,
            .stmt = stmt,
            .db = db,
        };
    }

    pub fn query(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeQuery(self, allocator, sql, argv);
    }

    pub fn deinit(self: *SqliteBackend) void {
        if (self.db) |d| {
            _ = c.sqlite3_close(d);
        }
        // CRITICAL: null out `db` after closing so the Transaction code's
        // `self.backend.db == null` use-after-free guard actually fires.
        // Without this, the pointer dangles and any subsequent operation
        // would dereference freed memory.
        self.db = null;
    }

    /// Begin a new top-level transaction on this backend. Returns a
    /// `Transaction` whose `exec`/`query` methods operate inside the
    /// transaction until `commit()` or `rollback()` is called.
    ///
    /// The backend's mutex is acquired and held for the entire transaction
    /// lifetime. Concurrent `exec`/`query` calls on the same backend
    /// (from other threads) block until the transaction ends.
    ///
    /// Returns `Error.DatabaseNotFound` if the backend is not initialized.
    /// Returns `Error.ExecuteFailed` if the underlying `BEGIN` SQL fails
    /// (e.g. already inside a transaction — should not happen if the
    /// caller respects the mutex contract).
    ///
    /// Cancel-safe: if the Io runtime cancels mid-`lock()`, returns
    /// `error.Canceled` without acquiring the lock or starting a tx.
    pub fn begin(self: *SqliteBackend) Error!Transaction {
        if (self.db == null) return Error.DatabaseNotFound;

        // Acquire the mutex BEFORE issuing BEGIN. This is the critical
        // correctness invariant: while the tx is alive, no other
        // backend.exec / backend.query call can interleave.
        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);

        // Issue BEGIN. On any failure, the errdefer releases the mutex.
        const rc = c.sqlite3_exec(self.db.?, "BEGIN", null, null, null);
        if (rc != c.SQLITE_OK) {
            return Error.ExecuteFailed;
        }

        // Track depth BEFORE returning the Transaction so commit/rollback
        // can choose the correct SQL (COMMIT vs RELEASE sp_<n>).
        self.transaction_depth += 1;
        return Transaction{
            .backend = self,
            .depth = self.transaction_depth,
            .completed = false,
        };
    }

    /// Open a nested savepoint within the current transaction. Must be
    /// called WHILE a tx is already open (i.e. between `begin()` /
    /// `savepoint()` and the corresponding `commit()` / `rollback()`).
    ///
    /// Savepoints let you roll back PART of a transaction without
    /// discarding the whole thing — useful for "try this batch, discard
    /// if it fails, keep going" patterns.
    ///
    /// The savepoint is named `sp_<depth>` (auto-generated based on the
    /// current depth). The returned Transaction's `depth` field is >= 2.
    ///
    /// **Caller must hold an active transaction.** Calling `savepoint()`
    /// when `transaction_depth == 0` returns `Error.ExecuteFailed`
    /// (SQLite rejects SAVEPOINT outside an outer tx).
    pub fn savepoint(self: *SqliteBackend) Error!Transaction {
        if (self.db == null) return Error.DatabaseNotFound;
        if (self.transaction_depth == 0) return Error.ExecuteFailed;

        // Mutex is already held by the outer tx — do NOT re-lock.

        self.transaction_depth += 1;
        const new_depth = self.transaction_depth;

        // Build a NUL-terminated SAVEPOINT name. We use a fixed-size
        // sentinel-terminated buffer because sqlite3_exec takes a C string.
        // `sql_buf[0..31]` is `[]u8` (what bufPrint expects); the 32nd byte
        // holds the NUL sentinel we set after formatting.
        var sql_buf: [32:0]u8 = undefined;
        const sql_slice = std.fmt.bufPrint(sql_buf[0..31], "SAVEPOINT sp_{d}", .{new_depth}) catch
            return Error.ExecuteFailed;
        sql_buf[sql_slice.len] = 0;

        const rc = c.sqlite3_exec(self.db.?, &sql_buf, null, null, null);
        if (rc != c.SQLITE_OK) {
            self.transaction_depth -= 1;
            return Error.ExecuteFailed;
        }

        return Transaction{
            .backend = self,
            .depth = new_depth,
            .completed = false,
        };
    }

    /// Number of rows changed by the most recent INSERT/UPDATE/DELETE
    /// statement. Used by callers that need to know whether their
    /// `db.exec` actually matched any rows (the API doesn't return the
    /// change count directly). See `sqlite3_changes` in the C API.
    /// Caller is responsible for being on the same thread (or holding
    /// the mutex) as the most recent write — the count is per-connection
    /// state in SQLite, not per-statement.
    pub fn changes(self: *SqliteBackend) i64 {
        const db = self.db orelse return 0;
        return c.sqlite3_changes(db);
    }
};
