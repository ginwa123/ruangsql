//! PostgreSQL backend for nalar — same public surface and `Error` variants as `sqlite/Sqlite.zig`
//! so the two stay swappable. `init` takes a libpq conninfo string; `?` args rewrite to `$N`.

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
    /// Returned by any Transaction method called after the transaction has been finalized;
    /// mirrors the SQLite contract — see `sqlite/Sqlite.zig` for the defer pattern.
    TransactionClosed,
};

/// Cross-platform libpq bindings. `c` lives INSIDE `PostgresBackend` and resolves lazily, so
/// `@import("Postgres.zig")` never forces libpq headers onto the include path (as in `Sqlite.zig`).
pub const PostgresBackend = struct {
    /// libpq C bindings, `pub` so tests can open the admin connection that `CREATE DATABASE`s the
    /// target (see `postgres_test.zig`); resolved lazily at first use of the struct.
    pub const c = if (builtin.os.tag == .linux)
        @cImport(@cInclude("libpq-fe.h"))
    else
        // Manual declarations for macOS/Windows (only the signatures we use); a non-Linux build must
        // add libpq's include path in build.zig — /opt/homebrew/opt/libpq or C:/vcpkg/installed/x64-windows.
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
    /// Allocator for param buffers and the begin/savepoint/commit SQL strings (those entry points take
    /// no allocator). NOT used for the `Row`/`Rows` payload — that follows the caller's per-call allocator.
    alloc: std.mem.Allocator = std.heap.page_allocator,
    /// Transaction nesting depth: 0 = none, 1 = top-level BEGIN, 2+ = SAVEPOINT. Mirrors
    /// `SqliteBackend.transaction_depth` — see that file for COMMIT vs RELEASE sp_<n> and mutex release.
    transaction_depth: u32 = 0,
    /// Rows changed by the most recent data-mutating exec, parsed from `PQcmdTuples(result)`;
    /// CREATE/SELECT statements reset it to 0.
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
            // Any connection-level failure maps to OpenFailed: libpq reports no distinct code here,
            // and telling a missing db from an unreachable server would need a fallback SQL probe.
            return Error.OpenFailed;
        }
        self.conn = pgconn;
    }

    pub fn deinit(self: *PostgresBackend) void {
        if (self.conn) |conn| {
            c.PQfinish(conn);
        }
        // CRITICAL: null `conn` after finishing, or the Transaction code's `self.backend.conn == null`
        // use-after-free guard never fires (mirrors SQLite's `self.db = null`).
        self.conn = null;
    }

    /// Translate SQLite-style `?` to PostgreSQL `$N` (1-indexed), numbering only placeholders seen in
    /// code mode — `?` inside literals, identifiers, comments and dollar-quoted strings is preserved.
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

            // Dollar-quoted string: $tag$...$tag$, tag empty or [_A-Za-z0-9]; an unterminated one is
            // passed through unchanged so the server reports it.
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

    /// Allocate a NUL-terminated copy of `sql` — libpq requires `*[*:0]const u8`, not a slice.
    /// Caller frees with `allocator.free`.
    fn dupSqlZ(allocator: std.mem.Allocator, sql: []const u8) ![:0]u8 {
        return try allocator.allocSentinel(u8, sql.len, 0);
    }

    /// NUL-terminated copies of every non-empty arg plus a parallel `?[*:0]const u8` array — `null`
    /// for empty args, the SQL NULL convention. Caller frees the buffer pool and the pointer array.
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

    /// Inner impl: translate, bind, run, then update `last_changes`. Caller MUST hold the backend
    /// mutex — `exec` takes it, `Transaction.exec` does not (the tx already holds it).
    fn executeStatement(
        self: *PostgresBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!void {
        const conn = self.conn orelse return Error.DatabaseNotFound;

        // Empty SQL is a successful no-op rather than libpq's PGRES_EMPTY_QUERY, matching SQLite, so
        // callers never special-case "".
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

    /// Inner impl: prepare, bind and step ONCE for a single-row SELECT. Caller MUST hold the backend
    /// mutex — `queryRow` takes it, `Transaction.queryRow` does not.
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
        /// Number of columns, captured at iteration start so each `next` can alloc the
        /// right-sized values array.
        nfields: c_int = 0,
        /// Most recent PostgreSQL error message, captured the first time `next()` would have errored;
        /// mirrors the SQLite Rows.last_error_msg contract (see `getLastErrorMessage`).
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

        /// Capture `PQresultErrorMessage(result)` into `last_error_msg`. Best-effort: a failed dupe
        /// leaves it null, and the caller still gets the Error enum either way.
        fn captureError(self: *Rows) void {
            if (self.result) |r| {
                const err_msg_c = c.PQresultErrorMessage(r);
                const span = std.mem.span(err_msg_c);
                if (self.last_error_msg) |old| self.allocator.free(old);
                self.last_error_msg = self.allocator.dupe(u8, span) catch null;
            }
        }

        /// Most recent PostgreSQL error message, or null; the slice is owned by Rows and valid
        /// until `deinit()`.
        pub fn getLastErrorMessage(self: *Rows) ?[]const u8 {
            return self.last_error_msg;
        }

        pub fn next(self: *Rows) Error!?Row {
            // Once exhausted, keep returning null without further work (mirrors the SQLite
            // Rows.done guard).
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

    /// Inner impl: run a SELECT-like statement and return a `Rows` iterator. Caller MUST hold the
    /// backend mutex — `query` takes it, `Transaction.query` does not.
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
        // CRITICAL: no `defer c.PQclear(result)` here — `Rows` takes ownership and frees it in
        // `Rows.deinit`, so a defer would free it before `next()` reads it; error paths clear explicitly.

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

    /// A database transaction, mirroring `sqlite/Sqlite.zig::Transaction`: same mutex semantics and
    /// single-use enforcement. The mutex is held for the whole tx, so `db.exec()` here would deadlock.
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

        /// Commit if not yet finalized (mirrors `sqlite/Sqlite.zig::Transaction::commitOrRollback`):
        /// `defer tx.commitOrRollback() catch {}` plus `errdefer tx.rollback()`; never a raw BEGIN/COMMIT.
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

    /// Begin a new top-level transaction — same mutex semantics and BEGIN/COMMIT/ROLLBACK SQL as
    /// `sqlite/Sqlite.zig::begin`.
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

    /// Open a nested savepoint named `sp_<depth>`, auto-generated from the current depth; mirrors
    /// `sqlite/Sqlite.zig::savepoint`.
    pub fn savepoint(self: *PostgresBackend) Error!Transaction {
        if (self.conn == null) return Error.DatabaseNotFound;
        if (self.transaction_depth == 0) return Error.ExecuteFailed;

        self.transaction_depth += 1;
        const new_depth = self.transaction_depth;

        // Pass the SQL as a `[:0]const u8`, never a bare `[32:0]u8`: `[N:0]u8` has its implicit sentinel
        // at the array's natural end, so PQexec would read past our runtime NUL into the stack tail.
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

    /// Rows changed by the most recent INSERT/UPDATE/DELETE — same contract as
    /// `sqlite/Sqlite.zig::changes()`, backed by `PQcmdTuples(PGresult)` instead of `sqlite3_changes`.
    pub fn changes(self: *PostgresBackend) i64 {
        return self.last_changes;
    }
};
