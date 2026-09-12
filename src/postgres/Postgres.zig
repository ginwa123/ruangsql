//! PostgreSQL backend for nalar. Provides an interface that mirrors the
//! SQLite backend in `sqlite/Sqlite.zig` exactly — same public functions
//! (`init` / `deinit` / `exec` / `queryRow` / `query` / `changes` /
//! `begin` / `savepoint`), same `Error` variants, same `Row` / `Rows` /
//! `Transaction` shapes — so call sites can swap `SqliteBackend` for
//! `PostgresBackend` without rewriting any logic.
//!
//! **`?` placeholder translation.** SQLite-style `?` placeholders are
//! translated to PostgreSQL-style `$N` (1-indexed) before being sent to
//! the server. The translator preserves `?` inside:
//!   - single-quoted string literals (`'...'`) with `''` escape
//!   - double-quoted identifiers (`"..."`) with `""` escape
//!   - line comments (`-- ...`)
//!   - block comments (`/* ... */`)
//!   - dollar-quoted strings (`$tag$...$tag$`, PostgreSQL-specific)
//!
//! See `translatePlaceholders` for the full rules.
//!
//! **Text-only binding.** Like the SQLite backend, all argument values
//! are bound as text. Empty `[]const u8` args bind as SQL NULL (project
//! convention). NUL-terminated copies are allocated per-call because
//! libpq's `PQexecParams` requires `*[*:0]const u8` for text format and
//! does not honor `paramLengths` for text input.
//!
//! **`changes()` semantics.** `PQcmdTuples(result)` returns the number
//! of rows affected by the last INSERT/UPDATE/DELETE as a C string
//! (e.g. `"3"`). This is parsed into `last_changes` after every
//! successful `exec`. CREATE/SELECT statements yield 0.
//!
//! **Connection string.** `init` takes a libpq conninfo string instead
//! of a SQLite file path. Example: `host=/tmp port=54329 user=ginwa
//! dbname=mydb`. See <https://www.postgresql.org/docs/current/libpq-connect.html>
//! for the full keyword/value grammar.
//!
//! See `postgres_test.zig` for the canonical documentation of the
//! public API surface and usage patterns.

const std = @import("std");
const builtin = @import("builtin");

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
    /// Returned by any Transaction method (exec/query/queryRow/commit/
    /// rollback) called after the transaction has been completed.
    /// Mirrors the SQLite contract — see `sqlite/Sqlite.zig` for the
    /// full discussion and recommended defer pattern.
    TransactionClosed,
};

/// Cross-platform libpq bindings.
///
/// IMPORTANT: The `c` declarations are scoped INSIDE `PostgresBackend`
/// (lazily resolved when the struct is referenced) — not at file
/// level. The reason mirrors `Sqlite.zig`'s rationale: `@cImport` is
/// header-driven, so hoisting it to file level would force every
/// translation unit that `@import("Postgres.zig")`s to provide libpq
/// headers on the include path. Same pattern, same comment.
pub const PostgresBackend = struct {
    /// libpq C bindings. `pub` so test files and external callers
    /// can access them (e.g. for the per-test admin connection that
    /// `CREATE DATABASE`s the test target — see `postgres_test.zig`).
    /// The `c` is lazily resolved via the `@cImport`/`else` branch
    /// at the first use of the struct, mirroring `Sqlite.zig`'s
    /// pattern of scoping the c bindings inside the backend.
    pub const c = if (builtin.os.tag == .linux)
        @cImport(@cInclude("libpq-fe.h"))
    else
        // Manual declarations for macOS/Windows. Mirrors Sqlite.zig's
        // cross-platform scaffolding — only the function signatures we
        // actually use are declared here. To compile this on non-Linux
        // platforms, add the matching macOS Homebrew / Windows vcpkg
        // paths to build.zig (libpq in /opt/homebrew/opt/libpq or
        // C:/vcpkg/installed/x64-windows).
        struct {
            pub const PGconn = opaque {};
            pub const PGresult = opaque {};

            pub const CONNECTION_OK: c_int = 0;
            pub const PGRES_COMMAND_OK: c_int = 1;
            pub const PGRES_TUPLES_OK: c_int = 2;
            pub const PGRES_EMPTY_QUERY: c_int = 3;
            pub const PGRES_COPY_OUT: c_int = 4;
            pub const PGRES_COPY_IN: c_int = 5;
            pub const PGRES_BAD_RESPONSE: c_int = 6;
            pub const PGRES_NONFATAL_ERROR: c_int = 7;
            pub const PGRES_FATAL_ERROR: c_int = 8;
            pub const PGRES_COPY_BOTH: c_int = 9;
            pub const PGRES_SINGLE_TUPLE: c_int = 10;

            pub extern fn PQconnectdb(conninfo: [*c]const u8) ?*PGconn;
            pub extern fn PQfinish(conn: ?*PGconn) void;
            pub extern fn PQstatus(conn: ?*PGconn) c_int;
            pub extern fn PQerrorMessage(conn: ?*PGconn) [*:0]const u8;
            pub extern fn PQexec(conn: ?*PGconn, command: [*:0]const u8) ?*PGresult;
            pub extern fn PQexecParams(
                conn: ?*PGconn,
                command: [*:0]const u8,
                nParams: c_int,
                paramTypes: ?*const c_int,
                paramValues: [*c]const ?[*:0]const u8,
                paramLengths: ?*const c_int,
                paramFormats: ?*const c_int,
                resultFormat: c_int,
            ) ?*PGresult;
            pub extern fn PQresultStatus(res: ?*PGresult) c_int;
            pub extern fn PQresultErrorMessage(res: ?*PGresult) [*:0]const u8;
            pub extern fn PQclear(res: ?*PGresult) void;
            pub extern fn PQntuples(res: ?*PGresult) c_int;
            pub extern fn PQnfields(res: ?*PGresult) c_int;
            pub extern fn PQgetvalue(res: ?*PGresult, row: c_int, col: c_int) [*:0]const u8;
            pub extern fn PQgetlength(res: ?*PGresult, row: c_int, col: c_int) c_int;
            pub extern fn PQgetisnull(res: ?*PGresult, row: c_int, col: c_int) c_int;
            pub extern fn PQcmdTuples(res: ?*PGresult) [*:0]const u8;
            pub extern fn PQreset(conn: ?*PGconn) void;
        };

    io: std.Io = .failing,
    conn: ?*c.PGconn = null,
    mutex: std.Io.Mutex = .init,
    /// Allocator used for per-call parameter buffers and tiny
    /// internal SQL strings (e.g. SAVEPOINT/RELEASE/ROLLBACK
    /// names). Set during `init`. NOT used to allocate the
    /// `Row` / `Rows` payload — those follow the per-call
    /// allocator that the caller passes to `exec`/`query`.
    /// This exists so that `begin`/`savepoint`/`commit` can
    /// allocate their SQL strings without taking an allocator
    /// parameter (those entry points don't take one).
    alloc: std.mem.Allocator = std.heap.page_allocator,
    /// Tracks the current transaction nesting depth (0 = no tx active;
    /// 1 = top-level BEGIN in flight; 2+ = nested SAVEPOINT). Mirrors
    /// `SqliteBackend.transaction_depth` — see that file for the full
    /// semantics (COMMIT vs RELEASE sp_<n>, the depth-gated mutex
    /// release, etc.).
    transaction_depth: u32 = 0,
    /// Number of rows changed by the most recent data-mutating exec.
    /// Populated after every successful `executeStatement` from
    /// `PQcmdTuples(result)`. CREATE/SELECT statements reset it to 0.
    last_changes: i64 = 0,

    pub fn init(self: *PostgresBackend, io: std.Io, conninfo: [:0]const u8) Error!void {
        self.io = io;
        const pgconn = c.PQconnectdb(conninfo.ptr);
        if (pgconn == null) {
            // Should never happen — PQconnectdb returns NULL only on
            // out-of-memory for the PGconn allocation itself.
            return Error.OutOfMemory;
        }
        if (c.PQstatus(pgconn) != c.CONNECTION_OK) {
            c.PQfinish(pgconn);
            // Map connection failures to the closest SQLite Error variant.
            // PostgreSQL doesn't have distinct error codes for these at the
            // connection level (vs server-side errors that come back via
            // PGresult). We map any connection failure to OpenFailed — the
            // caller sees one of OpenFailed vs DatabaseNotFound based on
            // whether the server was reachable but the db was missing
            // (we'd need a fallback SQL probe to distinguish, which is out
            // of scope for the wrapper).
            return Error.OpenFailed;
        }
        self.conn = pgconn;
    }

    pub fn deinit(self: *PostgresBackend) void {
        if (self.conn) |conn| {
            c.PQfinish(conn);
        }
        // CRITICAL: null out `conn` after finishing so the Transaction
        // code's `self.backend.conn == null` use-after-free guard fires.
        // Mirrors the SQLite backend's `self.db = null` pattern.
        self.conn = null;
    }

    /// Translate SQLite-style `?` placeholders to PostgreSQL `$N`
    /// (1-indexed). Preserves `?` inside string literals, identifiers,
    /// comments, and dollar-quoted strings.
    ///
    /// The translator walks the SQL byte-by-byte, tracking whether
    /// we're inside a literal/comment. When we hit `?` in "code"
    /// mode (outside any literal), we replace it with `$N` where N
    /// increments from 1. The first `?` becomes `$1`, the second `$2`,
    /// etc.
    fn translatePlaceholders(allocator: std.mem.Allocator, sql: []const u8) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        var placeholder_idx: usize = 1; // PostgreSQL is 1-indexed

        while (i < sql.len) {
            const ch = sql[i];

            // Line comment: -- to end of line. Preserved verbatim.
            if (ch == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
                try out.append(allocator, '-');
                try out.append(allocator, '-');
                i += 2;
                while (i < sql.len and sql[i] != '\n') {
                    try out.append(allocator, sql[i]);
                    i += 1;
                }
                continue;
            }

            // Block comment: /* to */. Preserved verbatim.
            if (ch == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
                try out.append(allocator, '/');
                try out.append(allocator, '*');
                i += 2;
                while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) {
                    try out.append(allocator, sql[i]);
                    i += 1;
                }
                if (i + 1 < sql.len) {
                    try out.append(allocator, '*');
                    try out.append(allocator, '/');
                    i += 2;
                } else {
                    // Unterminated block comment — pass through the
                    // rest so the server can give its own error.
                    while (i < sql.len) {
                        try out.append(allocator, sql[i]);
                        i += 1;
                    }
                }
                continue;
            }

            // Single-quoted string literal: '...' with '' as escape.
            if (ch == '\'') {
                try out.append(allocator, '\'');
                i += 1;
                while (i < sql.len) {
                    if (sql[i] == '\'') {
                        try out.append(allocator, '\'');
                        i += 1;
                        if (i < sql.len and sql[i] == '\'') {
                            // Escaped quote ('' inside the literal).
                            try out.append(allocator, '\'');
                            i += 1;
                        } else {
                            break; // closing quote
                        }
                    } else {
                        try out.append(allocator, sql[i]);
                        i += 1;
                    }
                }
                continue;
            }

            // Double-quoted identifier: "..." with "" as escape.
            if (ch == '"') {
                try out.append(allocator, '"');
                i += 1;
                while (i < sql.len) {
                    if (sql[i] == '"') {
                        try out.append(allocator, '"');
                        i += 1;
                        if (i < sql.len and sql[i] == '"') {
                            try out.append(allocator, '"');
                            i += 1;
                        } else {
                            break;
                        }
                    } else {
                        try out.append(allocator, sql[i]);
                        i += 1;
                    }
                }
                continue;
            }

            // Dollar-quoted string: $tag$...$tag$ (PostgreSQL-specific,
            // used for function bodies and similar). The tag is empty
            // ($tag$ = just $$) or contains [_A-Za-z0-9]. If we don't
            // see a closing $tag$, we pass the rest through unchanged
            // so the server gets to error with its own message.
            if (ch == '$') {
                var tag_end: usize = i + 1;
                while (tag_end < sql.len and
                    (sql[tag_end] == '_' or
                        (sql[tag_end] >= 'a' and sql[tag_end] <= 'z') or
                        (sql[tag_end] >= 'A' and sql[tag_end] <= 'Z') or
                        (sql[tag_end] >= '0' and sql[tag_end] <= '9')))
                {
                    tag_end += 1;
                }
                if (tag_end < sql.len and sql[tag_end] == '$') {
                    const tag = sql[i .. tag_end + 1]; // includes both $
                    try out.appendSlice(allocator, tag);
                    i = tag_end + 1;
                    // Find the matching closing tag.
                    var found_close = false;
                    while (i + tag.len <= sql.len) {
                        if (std.mem.eql(u8, sql[i .. i + tag.len], tag)) {
                            try out.appendSlice(allocator, tag);
                            i += tag.len;
                            found_close = true;
                            break;
                        }
                        try out.append(allocator, sql[i]);
                        i += 1;
                    }
                    if (!found_close) {
                        // Pass the rest through unchanged so the
                        // server can report the unterminated string.
                        while (i < sql.len) {
                            try out.append(allocator, sql[i]);
                            i += 1;
                        }
                    }
                    continue;
                }
            }

            // The actual placeholder.
            if (ch == '?') {
                var buf: [16]u8 = undefined;
                const formatted = std.fmt.bufPrint(&buf, "${d}", .{placeholder_idx}) catch
                    return Error.OutOfMemory;
                try out.appendSlice(allocator, formatted);
                placeholder_idx += 1;
                i += 1;
                continue;
            }

            try out.append(allocator, ch);
            i += 1;
        }

        return out.toOwnedSlice(allocator);
    }

    /// Allocate a NUL-terminated copy of `sql`. libpq's PQexecParams
    /// requires `*[*:0]const u8` SQL — we cannot pass our arbitrary
    /// slice directly. Caller frees with `allocator.free`.
    fn dupSqlZ(allocator: std.mem.Allocator, sql: []const u8) ![:0]u8 {
        return try allocator.allocSentinel(u8, sql.len, 0);
    }

    /// Allocate NUL-terminated copies of every non-empty arg, plus a
    /// parallel `?[*:0]const u8` array pointing to each (or `null` for
    /// empty args — the SQL NULL convention).
    ///
    /// Returns the buffer pool (free in defer) and the pointer array
    /// (free in defer).
    fn prepareParams(
        allocator: std.mem.Allocator,
        argv: []const []const u8,
    ) !struct {
        bufs: [][:0]u8,
        values: []?[*:0]const u8,
    } {
        const bufs = try allocator.alloc([:0]u8, argv.len);
        const values = try allocator.alloc(?[*:0]const u8, argv.len);
        for (argv, 0..) |arg, i| {
            if (arg.len == 0) {
                // Empty arg → bind NULL (project convention).
                values[i] = null;
                bufs[i] = try allocator.allocSentinel(u8, 0, 0);
            } else {
                const buf = try allocator.allocSentinel(u8, arg.len, 0);
                @memcpy(buf, arg);
                bufs[i] = buf;
                values[i] = @ptrCast(buf.ptr);
            }
        }
        return .{ .bufs = bufs, .values = values };
    }

    /// Inner implementation: translate placeholders, allocate
    /// NUL-terminated copies of args, run the statement on the
    /// connection, check status, update `last_changes`. Caller MUST
    /// hold the backend mutex. Used by both `exec` (with lock) and
    /// `Transaction.exec` (without re-locking — the tx already holds
    /// it).
    fn executeStatement(
        self: *PostgresBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!void {
        const conn = self.conn orelse return Error.DatabaseNotFound;

        // Empty SQL is a successful no-op. libpq would return
        // PGRES_EMPTY_QUERY for this, but we treat it as a no-op
        // up front to match SQLite's documented behavior — callers
        // don't need to special-case "" themselves.
        if (sql.len == 0) {
            self.last_changes = 0;
            return;
        }

        // Translate ? → $N
        const translated = try translatePlaceholders(allocator, sql);
        defer allocator.free(translated);

        // Allocate NUL-terminated SQL copy (PG requires [*:0]const u8).
        const sql_z = try allocator.allocSentinel(u8, translated.len, 0);
        defer allocator.free(sql_z);
        @memcpy(sql_z, translated);

        // Allocate NUL-terminated copies of every non-empty arg.
        const prepared = prepareParams(allocator, argv) catch return Error.OutOfMemory;
        const bufs = prepared.bufs;
        const values = prepared.values;
        defer allocator.free(bufs);
        defer allocator.free(values);
        defer for (bufs) |b| allocator.free(b);

        const result = c.PQexecParams(
            conn,
            sql_z.ptr,
            @intCast(argv.len),
            null, // paramTypes — let server infer
            values.ptr,
            null, // paramLengths — ignored for text format
            null, // paramFormats — text (0) for input
            0, // resultFormat — text (0) for output
        );
        defer if (result) |r| c.PQclear(r);

        const status = c.PQresultStatus(result);
        switch (status) {
            c.PGRES_COMMAND_OK, c.PGRES_TUPLES_OK => {
                // Track affected rows for changes().
                if (result) |r| {
                    const tuples_str = c.PQcmdTuples(r);
                    if (tuples_str[0] != 0) {
                        // Has a numeric count — parse it.
                        const span = std.mem.span(tuples_str);
                        self.last_changes = std.fmt.parseInt(i64, span, 10) catch 0;
                    } else {
                        // No command-tuples (SELECT/CREATE/etc.)
                        self.last_changes = 0;
                    }
                } else {
                    self.last_changes = 0;
                }
                return;
            },
            c.PGRES_EMPTY_QUERY => {
                self.last_changes = 0;
                return;
            },
            c.PGRES_FATAL_ERROR, c.PGRES_NONFATAL_ERROR => {
                return Error.ExecuteFailed;
            },
            else => return Error.ExecuteFailed,
        }
    }

    pub fn exec(self: *PostgresBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeStatement(self, allocator, sql, argv);
    }

    /// Inner implementation: prepare + bind + step ONCE for a
    /// single-row SELECT. Caller MUST hold the backend mutex. Used
    /// by both `queryRow` (with lock) and `Transaction.queryRow`
    /// (without re-locking).
    fn executeQueryRow(
        self: *PostgresBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Row {
        const conn = self.conn orelse return Error.DatabaseNotFound;

        if (sql.len == 0) return Error.RowNotFound;

        const translated = try translatePlaceholders(allocator, sql);
        defer allocator.free(translated);

        const sql_z = try allocator.allocSentinel(u8, translated.len, 0);
        defer allocator.free(sql_z);
        @memcpy(sql_z, translated);

        const prepared = prepareParams(allocator, argv) catch return Error.OutOfMemory;
        const bufs = prepared.bufs;
        const values = prepared.values;
        defer allocator.free(bufs);
        defer allocator.free(values);
        defer for (bufs) |b| allocator.free(b);

        const result = c.PQexecParams(
            conn,
            sql_z.ptr,
            @intCast(argv.len),
            null,
            values.ptr,
            null,
            null,
            0,
        );

        if (result == null) {
            return Error.QueryFailed;
        }
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        switch (status) {
            c.PGRES_TUPLES_OK => {},
            c.PGRES_COMMAND_OK => {
                // No rows returned — treat as RowNotFound, matching
                // SQLite's contract.
                return Error.RowNotFound;
            },
            c.PGRES_EMPTY_QUERY => return Error.RowNotFound,
            else => {
                return Error.QueryFailed;
            },
        }

        const ntuples = c.PQntuples(result);
        if (ntuples == 0) return Error.RowNotFound;

        const nfields = c.PQnfields(result);
        const values_out = try allocator.alloc([]u8, @intCast(nfields));
        errdefer {
            for (values_out) |v| allocator.free(v);
            allocator.free(values_out);
        }

        for (0..@intCast(nfields)) |col| {
            const is_null = c.PQgetisnull(result, 0, @intCast(col));
            if (is_null != 0) {
                values_out[col] = try allocator.alloc(u8, 0);
                continue;
            }
            const col_text = c.PQgetvalue(result, 0, @intCast(col));
            const len: usize = @intCast(c.PQgetlength(result, 0, @intCast(col)));
            if (len == 0) {
                // Even non-NULL text can be empty — empty []u8 matches
                // SQLite's NULL-mapping convention.
                values_out[col] = try allocator.alloc(u8, 0);
                continue;
            }
            const slice = std.mem.span(col_text);
            // PQgetlength is authoritative — use it instead of strlen
            // so we don't depend on NUL-termination.
            values_out[col] = try allocator.alloc(u8, len);
            @memcpy(values_out[col][0..len], slice[0..len]);
        }

        return Row{ .values = values_out };
    }

    pub fn queryRow(self: *PostgresBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeQueryRow(self, allocator, sql, argv);
    }

    pub const Row = struct {
        values: [][]u8,

        pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
            for (self.values) |v| {
                allocator.free(v);
            }
            allocator.free(self.values);
        }
    };

    pub const Rows = struct {
        allocator: std.mem.Allocator,
        /// Owned PGresult — holds the entire result set. Freed in
        /// `deinit`. NULL until `firstNext` populates it.
        result: ?*c.PGresult = null,
        /// Current row cursor (0-indexed; advances through every
        /// `next()` call until it equals `ntuples`).
        row_idx: c_int = 0,
        /// Total row count — captured at iteration start so we know
        /// when to return `null`.
        ntuples: c_int = 0,
        /// Number of columns in the result — captured at iteration
        /// start so each `next` can alloc the right-sized values
        /// array.
        nfields: c_int = 0,
        /// Most recent PostgreSQL error message. Captured the first
        /// time `next()` would have returned an error (mirrors the
        /// SQLite Rows.last_error_msg contract — see that file for
        /// the rationale and the `getLastErrorMessage()` getter).
        last_error_msg: ?[]u8 = null,
        done: bool = false,

        pub fn deinit(self: *Rows) void {
            if (self.last_error_msg) |msg| {
                self.allocator.free(msg);
                self.last_error_msg = null;
            }
            if (self.result) |r| {
                c.PQclear(r);
                self.result = null;
            }
        }

        /// Capture `PQresultErrorMessage(result)` into `last_error_msg`
        /// so callers can surface a useful error. Best-effort — silently
        /// no-ops on allocation failure; the caller still gets the
        /// Error enum either way.
        fn captureError(self: *Rows) void {
            if (self.result) |r| {
                const err_msg_c = c.PQresultErrorMessage(r);
                const span = std.mem.span(err_msg_c);
                if (self.last_error_msg) |old| self.allocator.free(old);
                self.last_error_msg = self.allocator.dupe(u8, span) catch null;
            }
        }

        /// Returns the most recent PostgreSQL error message, or null
        /// if no error has been captured yet. The slice is owned by
        /// Rows and is valid until `deinit()` is called.
        pub fn getLastErrorMessage(self: *Rows) ?[]const u8 {
            return self.last_error_msg;
        }

        pub fn next(self: *Rows) Error!?Row {
            // Defensive: once we've returned null (exhausted), keep
            // returning null without further work. Mirrors the
            // SQLite Rows.done guard.
            if (self.done) return null;
            if (self.result == null) return null;

            if (self.row_idx >= self.ntuples) {
                self.done = true;
                return null;
            }

            const values = self.allocator.alloc([]u8, @intCast(self.nfields)) catch
                return Error.OutOfMemory;
            errdefer {
                for (values) |v| self.allocator.free(v);
                self.allocator.free(values);
            }

            for (0..@intCast(self.nfields)) |col| {
                const is_null = c.PQgetisnull(self.result, self.row_idx, @intCast(col));
                if (is_null != 0) {
                    values[col] = self.allocator.alloc(u8, 0) catch return Error.OutOfMemory;
                    continue;
                }
                const col_text = c.PQgetvalue(self.result, self.row_idx, @intCast(col));
                const len: usize = @intCast(c.PQgetlength(self.result, self.row_idx, @intCast(col)));
                if (len == 0) {
                    values[col] = self.allocator.alloc(u8, 0) catch return Error.OutOfMemory;
                    continue;
                }
                values[col] = self.allocator.alloc(u8, len) catch return Error.OutOfMemory;
                const slice = std.mem.span(col_text);
                @memcpy(values[col][0..len], slice[0..len]);
            }

            self.row_idx += 1;
            return Row{ .values = values };
        }
    };

    /// Inner implementation: run a SELECT-like statement and return a
    /// `Rows` iterator. Caller MUST hold the backend mutex. Used by
    /// both `query` (with lock) and `Transaction.query` (without
    /// re-locking).
    fn executeQuery(
        self: *PostgresBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Rows {
        const conn = self.conn orelse return Error.DatabaseNotFound;

        if (sql.len == 0) {
            // Empty SQL → no result. Return an empty iterator so the
            // caller's loop sees exhaustion immediately.
            return Rows{
                .allocator = allocator,
                .result = null,
                .ntuples = 0,
                .nfields = 0,
            };
        }

        const translated = try translatePlaceholders(allocator, sql);
        defer allocator.free(translated);

        const sql_z = try allocator.allocSentinel(u8, translated.len, 0);
        defer allocator.free(sql_z);
        @memcpy(sql_z, translated);

        const prepared = prepareParams(allocator, argv) catch return Error.OutOfMemory;
        const bufs = prepared.bufs;
        const values = prepared.values;
        defer allocator.free(bufs);
        defer allocator.free(values);
        defer for (bufs) |b| allocator.free(b);

        const result = c.PQexecParams(
            conn,
            sql_z.ptr,
            @intCast(argv.len),
            null,
            values.ptr,
            null,
            null,
            0,
        );
        // CRITICAL: do NOT `defer c.PQclear(result)` here. The Rows
        // struct takes ownership of the result and will free it in
        // Rows.deinit. A defer here would free the result BEFORE the
        // test code can iterate via Rows.next — and `q.next()` would
        // dereference freed memory, segfaulting on the first
        // PQgetisnull/PQgetvalue call.
        //
        // The error paths below explicitly `c.PQclear(result)` before
        // returning, so the result is always freed exactly once —
        // either by `Rows.deinit` (success path) or by the explicit
        // `c.PQclear` (error path).

        if (result == null) {
            return Error.QueryFailed;
        }

        const status = c.PQresultStatus(result);
        switch (status) {
            c.PGRES_TUPLES_OK => {},
            else => {
                c.PQclear(result);
                return Error.QueryFailed;
            },
        }

        return Rows{
            .allocator = allocator,
            .result = result,
            .ntuples = c.PQntuples(result),
            .nfields = c.PQnfields(result),
        };
    }

    pub fn query(self: *PostgresBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeQuery(self, allocator, sql, argv);
    }

    /// A database transaction. Mirrors `sqlite/Sqlite.zig::Transaction`
    /// — same mutex semantics, same single-use enforcement, same
    /// `commitOrRollback` defer idiom. See that file for the full
    /// discussion of why the backend mutex is held for the entire tx
    /// lifetime and why `db.exec()` from within the same thread would
    /// deadlock.
    pub const Transaction = struct {
        backend: *PostgresBackend,
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

        fn _doFinalizeCommit(self: *Transaction) Error!void {
            const conn = self.backend.conn orelse {
                self.completed = true;
                self.backend.transaction_depth -= 1;
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.DatabaseNotFound;
            };

            const sql_z: [:0]const u8 = if (self.depth == 1) "COMMIT" else blk: {
                var buf: [32:0]u8 = undefined;
                const written = std.fmt.bufPrint(buf[0..31], "RELEASE sp_{d}", .{self.depth}) catch
                    return Error.ExecuteFailed;
                buf[written.len] = 0;
                break :blk buf[0..];
            };

            const result = c.PQexec(conn, sql_z.ptr);
            defer if (result) |r| c.PQclear(r);
            if (result == null) {
                self.completed = true;
                self.backend.transaction_depth -= 1;
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.ExecuteFailed;
            }
            const status = c.PQresultStatus(result);
            self.completed = true;
            self.backend.transaction_depth -= 1;
            if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);

            switch (status) {
                c.PGRES_COMMAND_OK => return,
                else => {
                    return Error.ExecuteFailed;
                },
            }
        }

        pub fn commit(self: *Transaction) Error!void {
            if (self.completed) return Error.TransactionClosed;
            return self._doFinalizeCommit();
        }

        /// Commit the transaction if it has not yet been finalized.
        /// Mirrors `sqlite/Sqlite.zig::Transaction::commitOrRollback`
        /// — see that file for the defer idiom.
        pub fn commitOrRollback(self: *Transaction) Error!void {
            if (self.completed) return;
            return self._doFinalizeCommit();
        }

        pub fn rollback(self: *Transaction) Error!void {
            if (self.completed) return Error.TransactionClosed;
            const conn = self.backend.conn orelse {
                self.completed = true;
                self.backend.transaction_depth -= 1;
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.DatabaseNotFound;
            };

            const sql_z: [:0]const u8 = if (self.depth == 1) "ROLLBACK" else blk: {
                var buf: [32:0]u8 = undefined;
                const written = std.fmt.bufPrint(buf[0..31], "ROLLBACK TO sp_{d}", .{self.depth}) catch
                    return Error.ExecuteFailed;
                buf[written.len] = 0;
                break :blk buf[0..];
            };

            const result = c.PQexec(conn, sql_z.ptr);
            defer if (result) |r| c.PQclear(r);
            if (result == null) {
                self.completed = true;
                self.backend.transaction_depth -= 1;
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.ExecuteFailed;
            }
            const status = c.PQresultStatus(result);
            self.completed = true;
            self.backend.transaction_depth -= 1;
            if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);

            switch (status) {
                c.PGRES_COMMAND_OK => return,
                else => {
                    return Error.ExecuteFailed;
                },
            }
        }
    };

    /// Begin a new top-level transaction. Mirrors
    /// `sqlite/Sqlite.zig::begin` — same mutex semantics, same
    /// BEGIN/COMMIT/ROLLBACK SQL.
    pub fn begin(self: *PostgresBackend) Error!Transaction {
        if (self.conn == null) return Error.DatabaseNotFound;

        // Acquire the mutex BEFORE issuing BEGIN.
        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);

        const result = c.PQexec(self.conn.?, "BEGIN");
        defer if (result) |r| c.PQclear(r);
        if (result == null) {
            return Error.ExecuteFailed;
        }
        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK) {
            return Error.ExecuteFailed;
        }

        self.transaction_depth += 1;
        return Transaction{
            .backend = self,
            .depth = self.transaction_depth,
            .completed = false,
        };
    }

    /// Open a nested savepoint within the current transaction. The
    /// savepoint is named `sp_<depth>` (auto-generated based on the
    /// current depth). Mirrors `sqlite/Sqlite.zig::savepoint`.
    pub fn savepoint(self: *PostgresBackend) Error!Transaction {
        if (self.conn == null) return Error.DatabaseNotFound;
        if (self.transaction_depth == 0) return Error.ExecuteFailed;

        self.transaction_depth += 1;
        const new_depth = self.transaction_depth;

        // Format the SQL and pass it to libpq as a NUL-terminated
        // many-pointer. We use a `[:0]const u8` (sentinel-terminated
        // slice) cast from a stack-allocated `[:0]u8` rather than
        // a fixed-size `[N:0]u8` array — the latter has an implicit
        // sentinel at the array's NATURAL end position (e.g. position
        // 32 for `[32:0]u8`), and libpq's PQexec will read up to that
        // natural sentinel, consuming the stack's undefined tail
        // past our runtime NUL. Using `[:0]u8` directly makes the
        // slice end at the runtime NUL we set.
        var sql_buf: [32:0]u8 = undefined;
        const written = std.fmt.bufPrint(sql_buf[0..31], "SAVEPOINT sp_{d}", .{new_depth}) catch
            return Error.ExecuteFailed;
        sql_buf[written.len] = 0;
        const sql_z: [:0]const u8 = sql_buf[0..];

        const result = c.PQexec(self.conn.?, sql_z.ptr);
        defer if (result) |r| c.PQclear(r);
        if (result == null) {
            self.transaction_depth -= 1;
            return Error.ExecuteFailed;
        }
        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK) {
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
    /// statement. Mirrors `sqlite/Sqlite.zig::changes()` — same
    /// contract, different underlying call (`PQcmdTuples(PGresult)`
    /// instead of `sqlite3_changes(PGconn)`).
    pub fn changes(self: *PostgresBackend) i64 {
        return self.last_changes;
    }
};
