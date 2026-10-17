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
    /// The pool is at `Config.max_conns` with every connection busy and `Config.conn_wait_ms` expired. `exec` / `query` / `queryRow`
    /// never surface it — they fall back to the primary connection — so only a caller driving `pool.claimOrWait` directly can observe it.
    PoolExhausted,
    RowNotFound,
    OutOfMemory,
    Canceled,
    /// Returned by any Transaction method called after the transaction has been finalized;
    /// mirrors the SQLite contract — see `sqlite/Sqlite.zig` for the defer pattern.
    TransactionClosed,
};

/// Connection policy applied to a `PostgresBackend` at `initWithConfig`; `init` opens with `.{}`.
pub const Config = struct {
    /// Extra connections opened and pre-warmed by `init`, and the floor the pool never shrinks below. One connection serialises every
    /// statement behind a single mutex, which is what the pool is for; 0 disables pooling and runs every statement on the primary connection.
    conns: usize = 7,
    /// Ceiling on the pool, never below `conns`. 0 = UNLIMITED. The SQLite reader pool's ceiling falls out of this process's descriptor budget; here the binding resource belongs
    /// to the SERVER, and a connection past its `max_connections` is an `OpenFailed` the pool cannot recover from, so the default is a policy cap rather than no cap at all.
    max_conns: usize = 32,
    /// How long a statement waits for a pooled connection to come free before it is served on the
    /// primary connection instead. Default 5 s; 0 = never wait.
    conn_wait_ms: u32 = 5_000,
    /// How long an idle connection above `conns` may sit before the pool closes it. 0 = close it on the
    /// next reaping pass, which is how `postgres_pool_test.zig` tests shrinking without sleeping.
    max_idle_time_ms: u64 = 60_000,
    /// Minimum gap between two automatic reaping passes, in milliseconds. 0 = derive it from
    /// `max_idle_time_ms` (a quarter of it, floored at 1 s).
    reap_interval_ms: u64 = 0,
    /// Allocator for the pooled connections and the pool's index lists; null (the default) uses `std.heap.smp_allocator`. CONSTRUCTOR lifetime, NOT the per-call allocator
    /// `query` / `exec` take: a pooled connection outlives the statement that opened it, so a request arena would leave `slots` holding pointers into freed memory.
    allocator: ?std.mem.Allocator = null,
};

/// Longest single park inside `ConnPool.waitForConnLocked`: a waiter wakes on this slice even when
/// nothing signalled it, so it re-reads the clock and can still honour its budget.
pub const MAX_WAIT_SLICE_MS: i64 = 250;

/// How long a primary-connection fallback stays quiet once logged: the fallback is a property of the
/// POOL being saturated, not of any one statement, so a burst must not print one line per statement.
pub const FALLBACK_LOG_INTERVAL_MS: i64 = 60_000;

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
    /// The primary connection: `begin` / `savepoint` / every `Transaction` method run here, and it is
    /// also where a statement lands when the pool cannot supply one.
    conn: ?*c.PGconn = null,
    /// Guards ONLY the primary connection: its `transaction_depth`, and every statement that runs
    /// there. A pooled connection carries its own mutex and takes this one only to fall back.
    mutex: std.Io.Mutex = .init,
    /// Transaction nesting depth on the PRIMARY connection: 0 = none, 1 = top-level BEGIN, 2+ =
    /// SAVEPOINT. Mirrors `SqliteBackend.transaction_depth` — see that file for COMMIT vs RELEASE.
    transaction_depth: u32 = 0,
    /// Rows changed by the most recent data-mutating exec, parsed from `PQcmdTuples(result)`;
    /// CREATE/SELECT statements reset it to 0. Atomic because pooled execs report it from other work.
    last_changes: std.atomic.Value(i64) = .init(0),
    /// Elastic pool of extra connections that serve `exec` / `query` / `queryRow` concurrently; empty
    /// and disabled when `Config.conns == 0`, in which case every statement runs on the primary.
    pool: ConnPool = .{},
    /// This connection's index in its pool's `slots`, or null when it is not pooled (the primary
    /// connection). Exists so a release is O(1) instead of a linear scan of every open connection.
    pool_index: ?usize = null,
    /// Statements served on the primary connection because the pool could not supply one.
    /// Read `readFallbackCount`.
    fallbacks: std.atomic.Value(u64) = .init(0),
    /// Monotonic timestamp (ms) of the last fallback warning, so a saturated pool reports once per
    /// interval instead of once per statement.
    fallback_logged_ms: std.atomic.Value(i64) = .init(0),

    /// Open `conninfo` with the default `Config`.
    pub fn init(self: *PostgresBackend, io: std.Io, conninfo: [:0]const u8) Error!void {
        return self.initWithConfig(io, conninfo, .{});
    }

    /// Open `conninfo` and, unless `cfg.conns == 0`, pre-warm the connection pool.
    pub fn initWithConfig(
        self: *PostgresBackend,
        io: std.Io,
        conninfo: [:0]const u8,
        cfg: Config,
    ) Error!void {
        try openSingle(self, io, conninfo);

        // Best-effort: a backend whose pool cannot open still works, one statement at a time, rather
        // than failing to start.
        self.pool.enable(io, conninfo, cfg);
        if (!self.pool.enabled) return;
        self.pool.prewarm(io, cfg.conns) catch |err| {
            std.log.warn("postgres: connection pool warm-up failed ({s}); the pool will grow on demand", .{@errorName(err)});
        };
    }

    /// The building block for the primary connection AND every pooled one.
    fn openSingle(slot: *PostgresBackend, io: std.Io, conninfo: [:0]const u8) Error!void {
        slot.io = io;
        const pgconn = c.PQconnectdb(conninfo.ptr) orelse {
            // Should never happen — PQconnectdb returns NULL only on
            // out-of-memory for the PGconn allocation itself.
            return Error.OutOfMemory;
        };
        if (c.PQstatus(pgconn) != c.CONNECTION_OK) {
            c.PQfinish(pgconn);
            // Any connection-level failure maps to OpenFailed: libpq reports no distinct code here,
            // and telling a missing db from an unreachable server would need a fallback SQL probe.
            return Error.OpenFailed;
        }
        slot.conn = pgconn;
    }

    pub fn deinit(self: *PostgresBackend) void {
        // Pooled connections are owned by this backend; close them with it.
        if (self.pool.enabled) self.pool.closeAll(self.io);
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

    /// Inner impl: translate, bind, run, then update `last_changes`. Caller MUST own `self`'s
    /// connection — either as the primary (its mutex held) or as a pool slot claimed for this call.
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
            self.last_changes.store(0, .monotonic);
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
                        self.last_changes.store(std.fmt.parseInt(i64, span, 10) catch 0, .monotonic);
                    } else {
                        // No command-tuples (SELECT/CREATE/etc.)
                        self.last_changes.store(0, .monotonic);
                    }
                } else {
                    self.last_changes.store(0, .monotonic);
                }
                return;
            },
            c.PGRES_EMPTY_QUERY => {
                self.last_changes.store(0, .monotonic);
                return;
            },
            c.PGRES_FATAL_ERROR, c.PGRES_NONFATAL_ERROR => {
                return Error.ExecuteFailed;
            },
            else => return Error.ExecuteFailed,
        }
    }

    pub fn exec(self: *PostgresBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
        // No statement outlives this call: a pooled slot is handed back before it returns.
        const slot = self.claimConn();
        if (slot == self) {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return executeStatement(self, allocator, sql, argv);
        }
        defer self.pool.release(self.io, slot);
        try slot.mutex.lock(slot.io);
        defer slot.mutex.unlock(slot.io);
        try executeStatement(slot, allocator, sql, argv);
        // `changes()` reads THIS backend, and the statement just ran on `slot`.
        self.last_changes.store(slot.last_changes.load(.monotonic), .monotonic);
    }

    /// Inner impl: prepare, bind and step ONCE for a single-row SELECT. Caller MUST own `self`'s
    /// connection — either as the primary (its mutex held) or as a pool slot claimed for this call.
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
        const slot = self.claimConn();
        if (slot == self) {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return executeQueryRow(self, allocator, sql, argv);
        }
        defer self.pool.release(self.io, slot);
        try slot.mutex.lock(slot.io);
        defer slot.mutex.unlock(slot.io);
        return executeQueryRow(slot, allocator, sql, argv);
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

    /// Inner impl: run a SELECT-like statement and return a `Rows` iterator. Caller MUST own `self`'s
    /// connection — either as the primary (its mutex held) or as a pool slot claimed for this call.
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
        // `PQexecParams` buffers the WHOLE result set into the `PGresult`, so the connection goes back
        // to the pool before the caller iterates: unlike SQLite, a live `Rows` pins no connection.
        const slot = self.claimConn();
        if (slot == self) {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return executeQuery(self, allocator, sql, argv);
        }
        defer self.pool.release(self.io, slot);
        try slot.mutex.lock(slot.io);
        defer slot.mutex.unlock(slot.io);
        return executeQuery(slot, allocator, sql, argv);
    }

    /// A database transaction, mirroring `sqlite/Sqlite.zig::Transaction`: same mutex semantics and single-use enforcement. It runs on the PRIMARY
    /// connection, held until commit, so a `db.exec()` issued while a tx is open runs OUTSIDE it (pooled) — or, with the pool off or exhausted, BLOCKS on it.
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
    /// `sqlite/Sqlite.zig::savepoint`. Runs on the primary connection, which the open tx already holds.
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

    /// Rows changed by the most recent INSERT/UPDATE/DELETE — same contract as `sqlite/Sqlite.zig::changes()`, backed by `PQcmdTuples(PGresult)`
    /// instead of `sqlite3_changes`. A pooled exec reports it from its own thread, so under concurrency the LAST exec to finish wins.
    pub fn changes(self: *PostgresBackend) i64 {
        return self.last_changes.load(.monotonic);
    }

    /// Take a connection for one statement, or the primary connection when the pool cannot supply one. NEVER returns an error:
    /// a statement served on the primary is merely serialized behind the tx mutex, a refused one is a 500 the caller sees.
    fn claimConn(self: *PostgresBackend) *PostgresBackend {
        if (!self.pool.enabled) return self;
        return self.pool.claimOrWait(self.io, self.pool.cfg.conn_wait_ms) catch |err| blk: {
            self.fallbacks.store(self.fallbacks.load(.monotonic) + 1, .monotonic);
            self.logFallbackOnce(err);
            break :blk self;
        };
    }

    fn logFallbackOnce(self: *PostgresBackend, err: Error) void {
        const now = ConnPool.nowMs(self.io);
        const last = self.fallback_logged_ms.load(.monotonic);
        if (last != 0 and now >= last and now - last < FALLBACK_LOG_INTERVAL_MS) return;
        self.fallback_logged_ms.store(now, .monotonic);
        std.log.warn(
            "postgres: pool supplied no connection within {d}ms ({s}); serving this statement on the primary connection",
            .{ self.pool.cfg.conn_wait_ms, @errorName(err) },
        );
    }

    /// Statements — reads and writes alike — served on the primary connection because the pool could not supply one. Zero is
    /// the only healthy value; named after `SqliteBackend.readFallbackCount` so a consumer can call it on either backend.
    pub fn readFallbackCount(self: *const PostgresBackend) u64 {
        return self.fallbacks.load(.monotonic);
    }

    /// Pooled connections handed out and not yet returned. Zero means every claim has been released;
    /// anything else is a statement path that dropped a connection.
    pub fn outstandingClaims(self: *PostgresBackend) usize {
        return self.pool.outstandingClaims();
    }

    /// Elastic pool of extra connections, owned by the primary `PostgresBackend` and shared by every caller that runs a statement
    /// through it. `claim` hands a connection to EXACTLY ONE statement until `release`, so statements no longer queue behind one mutex.
    const ConnPool = struct {
        /// One open connection. `claimed` is the authority on who owns it; `idle_since_ms` is only its age stamp, and they are NOT the same fact.
        /// Conflating them was a use-after-free waiting to happen: a duplicated `idle` entry let `claim` hand the SAME connection to two statements.
        const Slot = struct {
            conn: *PostgresBackend,
            claimed: bool = false,
            /// `.awake` stamp of the return to the idle list.
            idle_since_ms: ?i64 = null,
        };

        enabled: bool = false,
        io: std.Io = .failing,
        /// Owned copy of the conninfo: the pool opens connections lazily, long after the `conninfo`
        /// argument of `initWithConfig` has gone out of scope, so a borrow would dangle.
        conninfo: ?[:0]u8 = null,
        cfg: Config = .{},
        /// Every open connection, claimed or idle.
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        /// Indices into `slots` that are free to claim. An index is in
        /// exactly one of the two lists at any time.
        idle: std.ArrayListUnmanaged(usize) = .empty,
        /// Guards `slots` / `idle` structure only. Held briefly — never
        /// across a statement — so it is not the hot path's limiter.
        mutex: std.Io.Mutex = .init,
        /// Bumped by `release` / `reapIdle` / `closeAll` so a claim blocked on a full pool re-checks it as soon as a connection comes free. NOT
        /// `std.Io.Condition`: `Condition.wait` has no timeout, so a claim that must be able to give up needs `futexWaitTimeout` over this word.
        conns_epoch: std.atomic.Value(u32) = .init(0),
        /// Connections handed out and not yet returned: `outstandingClaims()` returning to zero is the
        /// only thing that proves the pool gave back what it lent, and it is assertable from a test.
        outstanding: std.atomic.Value(usize) = .init(0),
        /// Monotonic time (ms) before which no reaping pass runs: `reapLocked` walks the whole idle list, so running it from `release` on every statement
        /// made every statement pay an O(idle) scan. It bounds a pass's FREQUENCY, not a stale connection's AGE — that is `max_idle_time_ms + reap_interval_ms`.
        next_reap_ms: i64 = 0,

        fn enable(self: *ConnPool, io: std.Io, conninfo: [:0]const u8, cfg: Config) void {
            // cfg FIRST: the conninfo below is allocated with `self.alloc()`, and `closeAll` frees it
            // the same way, so a cfg stored after the dupe would free with a different allocator.
            self.cfg = cfg;
            self.conninfo = self.alloc().dupeZ(u8, conninfo) catch {
                // Without the conninfo the pool cannot open anything, so leave it disabled: every
                // statement falls back to the primary connection, which is correct, just serialized.
                std.log.warn("postgres: could not copy the conninfo; connection pool disabled", .{});
                return;
            };
            self.enabled = true;
            self.io = io;
        }

        /// An error rather than an `unreachable`: `closeAll` clears the conninfo, so a `claim` racing
        /// shutdown would otherwise turn a shutdown-ordering bug into a panic.
        fn conninfoZ(self: *ConnPool) Error![:0]const u8 {
            return self.conninfo orelse Error.DatabaseNotFound;
        }

        /// Resolved per call rather than captured in a `const`: `Config.allocator` is set at
        /// construction, and a connection is created long afterwards.
        fn alloc(self: *const ConnPool) std.mem.Allocator {
            return self.cfg.allocator orelse std.heap.smp_allocator;
        }

        /// 0 when `max_idle_time_ms` is 0, which means reap on every pass — how the pool tests
        /// exercise reaping without sleeping.
        fn reapIntervalMs(self: *const ConnPool) i64 {
            if (self.cfg.max_idle_time_ms == 0) return 0;
            if (self.cfg.reap_interval_ms != 0) {
                return @intCast(self.cfg.reap_interval_ms);
            }
            return @max(@as(i64, @intCast(self.cfg.max_idle_time_ms / 4)), 1_000);
        }

        /// Caller holds `mutex`. Returns how many connections were closed, which is what the callers
        /// use to decide whether a waiter has to be woken.
        fn reapIfDueLocked(self: *ConnPool, now: i64) usize {
            if (now < self.next_reap_ms) return 0;
            self.next_reap_ms = now + self.reapIntervalMs();
            return self.reapLocked(now);
        }

        fn nowMs(io: std.Io) i64 {
            // `.awake` is monotonic (CLOCK_MONOTONIC on Linux), so consecutive reads never go
            // backwards; there is no other clock in src.
            return std.Io.Timestamp.now(io, .awake).toMilliseconds();
        }

        /// Open up to `n` connections now so a burst does not each pay for a
        /// connection open.
        fn prewarm(self: *ConnPool, io: std.Io, n: usize) !void {
            self.mutex.lock(io) catch return Error.Canceled;
            defer self.mutex.unlock(io);
            const now = nowMs(io);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (self.atCap()) break;
                const conn = self.alloc().create(PostgresBackend) catch return Error.OutOfMemory;
                // `pool = .{}` — a pooled connection never nests a pool of its own.
                conn.* = .{};
                openSingle(conn, io, try self.conninfoZ()) catch |err| {
                    conn.deinit();
                    self.alloc().destroy(conn);
                    return err;
                };
                try self.slots.append(self.alloc(), .{ .conn = conn, .idle_since_ms = now });
                conn.pool_index = self.slots.items.len - 1;
                try self.idle.append(self.alloc(), self.slots.items.len - 1);
            }
        }

        /// Open one more connection. ONE cleanup path, deliberately: the `errdefer`s fire on EVERY error
        /// return, so pairing them with an explicit `alloc.destroy` on any one of those paths is a double free.
        fn openSlot(self: *ConnPool, io: std.Io) !*PostgresBackend {
            const conn = self.alloc().create(PostgresBackend) catch return Error.OutOfMemory;
            // `pool = .{}` — a pooled connection never nests a pool of its own.
            conn.* = .{};
            // `deinit`, not a bare `alloc.destroy`: `openSingle` can fail AFTER assigning `conn.conn`, so the libpq handle must be closed
            // or its descriptor leaks for the life of the process. `deinit` is safe on a half-open backend: every step null-checks first.
            errdefer self.alloc().destroy(conn);
            errdefer conn.deinit();
            try openSingle(conn, io, try self.conninfoZ());

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.atCap()) return error.PoolExhausted;
            try self.slots.append(self.alloc(), .{ .conn = conn, .claimed = true, .idle_since_ms = null });
            conn.pool_index = self.slots.items.len - 1;
            _ = self.outstanding.fetchAdd(1, .monotonic);
            return conn;
        }

        /// The policy ceiling, or 0 when there is none. Never below `conns`: a `max_conns` at or under the warm floor `prewarm` just opened would make
        /// the pool refuse connections it already holds, so a misconfigured pair degrades to the floor rather than to no connections at all.
        fn effectiveCap(self: *const ConnPool) usize {
            if (self.cfg.max_conns == 0) return 0;
            return @max(self.cfg.max_conns, self.cfg.conns);
        }

        fn atCap(self: *const ConnPool) bool {
            const cap = self.effectiveCap();
            return cap != 0 and self.slots.items.len >= cap;
        }

        /// Take an idle connection, if there is one. Caller holds `mutex`. A stale entry (out of range, or naming a slot some other path already handed
        /// out) is dropped rather than returned: handing a CLAIMED connection to a second statement is the one mistake this pool cannot recover from.
        fn popIdleLocked(self: *ConnPool) ?*PostgresBackend {
            while (self.idle.pop()) |idx| {
                if (idx >= self.slots.items.len) continue;
                if (self.slots.items[idx].claimed) continue;
                self.slots.items[idx].claimed = true;
                self.slots.items[idx].idle_since_ms = null;
                _ = self.outstanding.fetchAdd(1, .monotonic);
                return self.slots.items[idx].conn;
            }
            return null;
        }

        /// Take ownership of a connection, opening one if every existing connection is busy. Never
        /// blocks on another statement.
        pub fn claim(self: *ConnPool, io: std.Io) Error!*PostgresBackend {
            try self.mutex.lock(io);
            if (self.popIdleLocked()) |conn| {
                self.mutex.unlock(io);
                return conn;
            }
            // Slow path: everything is busy. Reap first: connections that went idle long ago and were
            // never reaped still occupy slots, and `atCap` counts slots, not free connections.
            _ = self.reapIfDueLocked(nowMs(io));
            self.mutex.unlock(io);
            return self.openSlot(io);
        }

        /// Wake claims blocked on `claimOrWait`, so they re-check the pool. Safe with the mutex held or not; what matters is that the announced change is already visible in `slots` / `idle`. `epoch` is bumped BEFORE the
        /// futex wake, which closes the race: a waiter that sampled the old epoch either already parked (and gets woken) or has not parked (and its `futexWaitTimeout` returns immediately, because the word no longer matches).
        fn wakeWaiters(self: *ConnPool, io: std.Io) void {
            _ = self.conns_epoch.fetchAdd(1, .release);
            io.futexWake(u32, &self.conns_epoch.raw, std.math.maxInt(u32));
        }

        /// Block until a connection is released or `timeout_ms` elapses, then re-take `mutex` and return. Caller holds `mutex` on entry and again on exit. Uncancelable and bounded
        /// by the timeout rather than by a signal: the caller has to be able to give up eventually, and a cancel would leave the statement with nowhere to report the error.
        fn waitForConnLocked(self: *ConnPool, io: std.Io, timeout_ms: i64) void {
            if (timeout_ms <= 0) return;
            // Sample BEFORE unlocking: sampling after would let a release
            // land in between and go unnoticed until the next timeout.
            const epoch = self.conns_epoch.load(.acquire);
            self.mutex.unlock(io);
            defer self.mutex.lockUncancelable(io);
            io.futexWaitTimeout(
                u32,
                &self.conns_epoch.raw,
                epoch,
                .{ .duration = .{
                    .raw = .{ .nanoseconds = @intCast(@min(timeout_ms, MAX_WAIT_SLICE_MS) * std.time.ns_per_ms) },
                    .clock = .awake,
                } },
            ) catch {};
        }

        /// `claim`, but WAIT up to `budget_ms` for a connection to be released when the pool is at its
        /// ceiling instead of failing at once. Returns `error.PoolExhausted` when the budget expires.
        pub fn claimOrWait(self: *ConnPool, io: std.Io, budget_ms: u32) Error!*PostgresBackend {
            if (self.claim(io)) |conn| {
                return conn;
            } else |err| switch (err) {
                error.PoolExhausted => {},
                else => return err,
            }
            if (budget_ms == 0) return error.PoolExhausted;

            const deadline = nowMs(io) + @as(i64, budget_ms);
            var locked = true;
            try self.mutex.lock(io);
            defer if (locked) self.mutex.unlock(io);

            while (true) {
                if (self.popIdleLocked()) |conn| return conn;
                if (self.reapIfDueLocked(nowMs(io)) > 0) self.wakeWaiters(io);
                if (self.popIdleLocked()) |conn| return conn;
                if (!self.atCap()) {
                    // Room to grow — but `openSlot` locks the mutex itself.
                    locked = false;
                    self.mutex.unlock(io);
                    return self.openSlot(io);
                }
                const remaining = deadline - nowMs(io);
                if (remaining <= 0) return error.PoolExhausted;
                self.waitForConnLocked(io, remaining);
            }
        }

        /// Hand a connection back. Call ONLY once the statement that claimed it has finished.
        pub fn release(self: *ConnPool, io: std.Io, slot: *PostgresBackend) void {
            // `slots.items` and `slot.pool_index` are both pool-owned, so the lookup MUST happen under the mutex: a concurrent
            // `claim` -> `openSlot` can reallocate that slice, and the reaper renumbers indices when it closes a gap.
            self.mutex.lock(io) catch return;
            const handed_back = blk: {
                defer self.mutex.unlock(io);
                // O(1): the connection carries its own index. The bounds and identity checks cover the only way it can be stale (the reaper
                // closed a gap and renumbered). On a mismatch, fall back to a scan: slow, but it cannot hand out the wrong connection.
                var idx = slot.pool_index orelse (self.indexOf(slot) orelse break :blk false);
                if (idx >= self.slots.items.len or self.slots.items[idx].conn != slot) {
                    idx = self.indexOf(slot) orelse break :blk false;
                }
                break :blk self.releaseAtLocked(io, idx);
            };
            // Announced after the entry is visible in `idle`: a woken waiter whose first act is to
            // re-acquire the mutex has to find something to take, or it sleeps again having lost nothing.
            if (handed_back) self.wakeWaiters(io);
        }

        /// The hand-back itself, with `mutex` held. Returns whether a connection was actually returned, which
        /// is also what the outstanding counter keys off: every early return leaves the connection claimed.
        fn releaseAtLocked(self: *ConnPool, io: std.Io, idx: usize) bool {
            if (!self.slots.items[idx].claimed) {
                // Already idle. A second `release` for the same connection would put its index in
                // `idle` a second time, and the next `claim` would hand one connection to two callers.
                return false;
            }
            const stamp = nowMs(io);
            self.slots.items[idx].claimed = false;
            self.slots.items[idx].idle_since_ms = stamp;
            self.idle.append(self.alloc(), idx) catch {
                // Out of memory for the idle index. Deliberately do NOT `swapRemove` the slot out of `slots`: that would renumber every later
                // index and silently hand the same connection to two callers. Keeping it claimed leaks one connection, the safe direction to fail.
                self.slots.items[idx].claimed = true;
                self.slots.items[idx].idle_since_ms = null;
                std.log.err("postgres: pool lost an idle slot to OOM; leaking one connection", .{});
                return false;
            };
            _ = self.reapIfDueLocked(stamp);
            _ = self.outstanding.fetchSub(1, .monotonic);
            return true;
        }

        /// Close idle connections older than `max_idle_time_ms`, never below the `conns` warm floor and never a claimed one. Public so an
        /// optional daemon tick can call it. ALWAYS RUNS — a rate-limited tick wants `reapIdleThrottled`.
        pub fn reapIdle(self: *ConnPool, io: std.Io) void {
            self.mutex.lock(io) catch return;
            const now = nowMs(io);
            const reaped = self.reapLocked(now);
            self.next_reap_ms = now + self.reapIntervalMs();
            self.mutex.unlock(io);
            // Freeing slots is exactly what a claim parked on `claimOrWait` is waiting for: without
            // this it would sit out its whole budget against a pool that already had room.
            if (reaped > 0) self.wakeWaiters(io);
        }

        /// `reapIdle`, but skipped when a pass ran inside `reap_interval_ms`. This is the tick a long-lived server should call: it can fire on any cadence and the
        /// pool decides whether the work is due. The inline passes are traffic-driven, so a consumer that goes quiet never triggers one and its pool stays fat.
        pub fn reapIdleThrottled(self: *ConnPool, io: std.Io) void {
            self.mutex.lock(io) catch return;
            const now = nowMs(io);
            if (now < self.next_reap_ms) {
                self.mutex.unlock(io);
                return;
            }
            const reaped = self.reapLocked(now);
            self.next_reap_ms = now + self.reapIntervalMs();
            self.mutex.unlock(io);
            if (reaped > 0) self.wakeWaiters(io);
        }

        /// Caller must hold `mutex`. `now` is a parameter (not read inside) so `release` can pass the timestamp it just stamped without
        /// a second clock read. Returns how many connections were closed, so the caller can decide whether a waiter needs waking.
        fn reapLocked(self: *ConnPool, now: i64) usize {
            const floor = self.cfg.conns;
            var reaped: usize = 0;
            var i: usize = 0;
            while (i < self.idle.items.len) {
                if (self.slots.items.len <= floor) break;
                const idx = self.idle.items[i];
                if (idx >= self.slots.items.len) {
                    // Unreachable: every mutation of `slots` fixes up `idle`. Nothing is orphaned by
                    // dropping this entry, since the slot it named is already gone.
                    _ = self.idle.swapRemove(i);
                    continue;
                }
                if (self.slots.items[idx].claimed) {
                    // In use. SKIP, never drop: an entry removed here leaves the slot in NEITHER list, so no claim can reach it
                    // and no reaper will close it — a leaked connection that also counts against the cap. Try again next pass.
                    i += 1;
                    continue;
                }
                const since = self.slots.items[idx].idle_since_ms orelse {
                    // No age stamp, so its age is unknown; reaping it blind could close a connection
                    // someone is using. Skip for the same reason as above.
                    i += 1;
                    continue;
                };
                // A clock that went backwards makes the entry look fresh; treat it as fresh rather than
                // reaping a connection that was just released.
                if (now < since) {
                    i += 1;
                    continue;
                }
                const age = @as(u64, @intCast(now - since));
                if (age < self.cfg.max_idle_time_ms) {
                    i += 1;
                    continue;
                }
                // Reap it: remove its idle entry, close the connection, then close the gap in `slots`. `slots[idx]` is NOT the last element in general, so move the last
                // slot into the gap and rewrite any idle entry that pointed at the last index, or the next claim hands out the wrong connection (or two callers share one).
                _ = self.idle.swapRemove(i);
                const victim = self.slots.items[idx].conn;
                victim.pool_index = null;
                victim.deinit();
                self.alloc().destroy(victim);
                const last = self.slots.items.len - 1;
                if (idx != last) {
                    self.slots.items[idx] = self.slots.items[last];
                    // The moved connection's cached index must move with it, or its next `release`
                    // would name the wrong slot; this is the only place a slot changes index.
                    self.slots.items[idx].conn.pool_index = idx;
                    for (self.idle.items) |*entry| {
                        if (entry.* == last) entry.* = idx;
                    }
                }
                self.slots.items.len -= 1;
                reaped += 1;
                // Do not advance `i`: `swapRemove` moved a new entry here.
            }
            return reaped;
        }

        fn indexOf(self: *ConnPool, slot: *PostgresBackend) ?usize {
            for (self.slots.items, 0..) |s, i| {
                if (s.conn == slot) return i;
            }
            return null;
        }

        fn closeAll(self: *ConnPool, io: std.Io) void {
            self.mutex.lock(io) catch {};
            defer self.mutex.unlock(io);
            for (self.slots.items) |slot| {
                slot.conn.deinit();
                self.alloc().destroy(slot.conn);
            }
            self.slots.deinit(self.alloc());
            self.idle.deinit(self.alloc());
            self.slots = .empty;
            self.idle = .empty;
            if (self.conninfo) |owned_conninfo| self.alloc().free(owned_conninfo);
            self.conninfo = null;
            self.enabled = false;
            // Wake every waiter: a claim blocked in `claimOrWait` must not sit out its whole budget against a pool that no longer
            // exists. `popIdleLocked` finds nothing and `openSlot` reports `DatabaseNotFound`, which the caller turns into a fallback.
            self.wakeWaiters(io);
        }

        pub fn count(self: *ConnPool) usize {
            return self.slots.items.len;
        }

        pub fn outstandingClaims(self: *ConnPool) usize {
            return self.outstanding.load(.monotonic);
        }

        /// How many connections are sitting in the idle list right now. Exposed because "the pool is at its
        /// ceiling" and "every connection is busy" are different facts, and only the second one is backpressure.
        pub fn idleCount(self: *ConnPool) usize {
            self.mutex.lock(self.io) catch return 0;
            defer self.mutex.unlock(self.io);
            return self.idle.items.len;
        }
    };
};
