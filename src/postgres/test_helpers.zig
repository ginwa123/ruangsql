//! Test helpers for the PostgreSQL backend: `createTempDb` / `dropTempDb` for per-test
//! isolation, and a global probe whose `!is_available` makes tests self-skip (not fail) without PG.

const std = @import("std");
const builtin = @import("builtin");
const PostgresBackend = @import("Postgres.zig").PostgresBackend;
const Error = @import("Postgres.zig").Error;

/// Re-export of `Postgres.zig::Error`, so tests can write
/// `helpers.Error.DatabaseNotFound` without importing `Postgres.zig`.
pub const PostgresError = Error;

pub const DEFAULT_TEST_CONNINFO = "host=/tmp port=54329 user=ginwa dbname=postgres";

/// Environment state for one test process, cached globally by
/// `getOrStartTestInstance`: `conninfo` borrows that never-freed cache and stays valid for the process.
pub const TestEnv = struct {
    /// NUL-terminated because libpq takes C strings: both the env-var path and
    /// the default literal satisfy `conninfo[len - 1] == 0`.
    conninfo: [:0]const u8,
    is_available: bool,
};

/// Context returned by `createTempDb` — backend, Io runtime, unique DB name and
/// base conninfo. The caller MUST pass it to `dropTempDb` to clean up.
pub const TestDb = struct {
    db: PostgresBackend,
    threaded: std.Io.Threaded,
    /// Unique database name (e.g. `nalar_pg_test_4f2a_7`). Owned
    /// by this struct — `dropTempDb` frees it.
    db_name: []u8,
    /// Base conninfo for the shared PG instance — borrowed, not owned: the caller
    /// must keep it alive (typically a `TestEnv.conninfo` global).
    base_conninfo: []const u8,
};

// ─── Layer 1: instance probe ─────────────────────────────────────────────

pub var g_test_env: TestEnv = undefined;
pub var g_test_env_initialized: bool = false;

/// One-shot probe of the test PG instance, cached — only the first call hits the
/// network. Tests skip when `is_available` is false; NOT thread-safe, so populate the cache before spawning threads.
pub fn getOrStartTestInstance(allocator: std.mem.Allocator) TestEnv {
    // Nothing is allocated here (the env span points into process environ or a
    // static literal); the discarded parameter stays only so callers don't change.
    _ = allocator;
    if (g_test_env_initialized) return g_test_env;

    // Try POSTGRES_TEST_CONNINFO first. The getenv span points into process environ
    // (stable for the process), so don't dupe it: the cache is never freed, and a dupe would trip testing.allocator.
    if (std.c.getenv("POSTGRES_TEST_CONNINFO")) |raw| {
        const span = std.mem.span(raw);
        g_test_env = .{
            .conninfo = span,
            .is_available = testConnect(span),
        };
    } else {
        g_test_env = .{
            .conninfo = DEFAULT_TEST_CONNINFO,
            .is_available = testConnect(DEFAULT_TEST_CONNINFO),
        };
    }
    g_test_env_initialized = true;
    return g_test_env;
}

/// One-shot connectivity probe. Returns true if the server accepted
/// the connection.
fn testConnect(conninfo: [:0]const u8) bool {
    const conn = PostgresBackend.c.PQconnectdb(conninfo.ptr);
    defer if (conn) |c| PostgresBackend.c.PQfinish(c);
    if (conn == null) return false;
    return PostgresBackend.c.PQstatus(conn) == PostgresBackend.c.CONNECTION_OK;
}

// ─── Layer 2: per-test isolation ─────────────────────────────────────────

/// Atomic, monotonic source of DB-name suffixes: `createTempDb` combines it with
/// the tid, so concurrent invocations in one process never collide. `pub` so tests can share it.
pub var g_db_counter: u64 = 0;
pub fn nextDbCounter() u64 {
    return @atomicRmw(u64, &g_db_counter, .Add, 1, .seq_cst);
}

/// Create a fresh, isolated PG DB on the shared instance and open a backend
/// against it (caller MUST `dropTempDb`); any failure unwinds everything, dropping the DB if CREATE DATABASE already ran.
pub fn createTempDb(allocator: std.mem.Allocator, base_conninfo: []const u8) Error!TestDb {
    // 1. Generate a unique DB name.
    const counter_value = nextDbCounter();
    const pid_bits: u64 = @intCast(std.os.linux.gettid());
    const db_name = try std.fmt.allocPrint(
        allocator,
        "nalar_pg_test_{x}_{x}",
        .{ pid_bits, counter_value },
    );
    errdefer allocator.free(db_name);

    // 2. CREATE DATABASE. Track success so the errdefer below can drop it if a
    //    LATER step fails — otherwise a failed `db.init` leaves a stray DB.
    var db_created = false;
    errdefer if (db_created) dropDatabase(allocator, base_conninfo, db_name);

    try createDatabase(allocator, base_conninfo, db_name);
    db_created = true;

    // 3. Open a PostgresBackend against the new database.
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    const db_conninfo = try buildDbConninfo(allocator, base_conninfo, db_name);
    defer allocator.free(db_conninfo);

    var db: PostgresBackend = .{};
    errdefer db.deinit();
    try db.init(io, db_conninfo);

    return .{
        .db = db,
        .threaded = threaded,
        .db_name = db_name,
        .base_conninfo = base_conninfo,
    };
}

/// Standalone helper: CREATE DATABASE on the shared instance over a temporary admin
/// connection. On failure it returns an error having created nothing; the caller owns `db_name`.
pub fn createDatabase(allocator: std.mem.Allocator, admin_conninfo: []const u8, db_name: []const u8) Error!void {
    const admin_conn = PostgresBackend.c.PQconnectdb(admin_conninfo.ptr);
    defer if (admin_conn) |c| PostgresBackend.c.PQfinish(c);
    if (admin_conn == null) return Error.DatabaseNotFound;
    if (PostgresBackend.c.PQstatus(admin_conn) != PostgresBackend.c.CONNECTION_OK) {
        return Error.DatabaseNotFound;
    }

    const create_sql = try std.fmt.allocPrint(allocator, "CREATE DATABASE {s}", .{db_name});
    defer allocator.free(create_sql);
    const create_sql_z = try allocator.allocSentinel(u8, create_sql.len, 0);
    defer allocator.free(create_sql_z);
    @memcpy(create_sql_z, create_sql);

    const result = PostgresBackend.c.PQexec(admin_conn, create_sql_z.ptr);
    defer if (result) |r| PostgresBackend.c.PQclear(r);
    if (result == null) return Error.ExecuteFailed;
    const status = PostgresBackend.c.PQresultStatus(result);
    if (status != PostgresBackend.c.PGRES_COMMAND_OK) {
        const err_msg = PostgresBackend.c.PQresultErrorMessage(result);
        std.log.warn("CREATE DATABASE failed: {s}", .{err_msg});
        return Error.ExecuteFailed;
    }
}

/// Drop a `createTempDb` database and free the `TestDb` — idempotent (a second call
/// is a no-op). Uses `DROP DATABASE ... WITH (FORCE)` to kill lingering connections.
pub fn dropTempDb(allocator: std.mem.Allocator, ctx: *TestDb) void {
    // Idempotent: after the first call the ctx is reset (empty db_name, null conn,
    // undefined threaded) — deinit-ing `threaded` twice would hang on that garbage.
    if (ctx.db_name.len == 0) return;

    // 1. Close the per-test backend. Sets ctx.db.conn to null.
    ctx.db.deinit();
    ctx.threaded.deinit();

    // 2. Drop the test DB. Failure here is non-fatal (the test already passed, the
    //    DB just lingers); `dropDatabase` logs it.
    dropDatabase(allocator, ctx.base_conninfo, ctx.db_name);

    allocator.free(ctx.db_name);
    ctx.* = .{
        .db = .{ .conn = null },
        .threaded = undefined,
        .db_name = &[_]u8{},
        .base_conninfo = "",
    };
}

/// Standalone helper: `DROP DATABASE IF EXISTS ... WITH (FORCE)` over a temporary
/// admin connection. It never fails the caller — connect/drop errors are logged and swallowed.
pub fn dropDatabase(allocator: std.mem.Allocator, admin_conninfo: []const u8, db_name: []const u8) void {
    const admin_conn = PostgresBackend.c.PQconnectdb(admin_conninfo.ptr);
    defer if (admin_conn) |c| PostgresBackend.c.PQfinish(c);
    if (admin_conn == null) return;
    if (PostgresBackend.c.PQstatus(admin_conn) != PostgresBackend.c.CONNECTION_OK) return;

    const drop_sql = std.fmt.allocPrint(
        allocator,
        "DROP DATABASE IF EXISTS {s} WITH (FORCE)",
        .{db_name},
    ) catch return;
    defer allocator.free(drop_sql);
    const drop_sql_z = allocator.allocSentinel(u8, drop_sql.len, 0) catch return;
    defer allocator.free(drop_sql_z);
    @memcpy(drop_sql_z, drop_sql);

    const result = PostgresBackend.c.PQexec(admin_conn, drop_sql_z.ptr);
    defer if (result) |r| PostgresBackend.c.PQclear(r);
    if (result) |r| {
        if (PostgresBackend.c.PQresultStatus(r) != PostgresBackend.c.PGRES_COMMAND_OK) {
            const err_msg = PostgresBackend.c.PQresultErrorMessage(r);
            std.log.warn("DROP DATABASE WITH (FORCE) failed: {s}", .{err_msg});
        }
    }
}

/// Strip any `dbname=` from `base` and append `dbname=<wanted>`. Internal to
/// `createTempDb`; exposed for the rare test that builds a conninfo by hand.
pub fn buildDbConninfo(allocator: std.mem.Allocator, base: []const u8, wanted: []const u8) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < base.len) {
        // Find the next space (key/value separators in libpq conninfo).
        var end = i;
        while (end < base.len and base[end] != ' ') end += 1;
        const token = base[i..end];

        // Skip any existing `dbname=` clause. libpq's last-occurrence-wins means
        // appending would also work, but skipping avoids a confusing duplicate.
        if (!std.mem.startsWith(u8, token, "dbname=")) {
            if (out.items.len > 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, token);
        }
        i = end;
        while (i < base.len and base[i] == ' ') i += 1;
    }

    // Append the wanted dbname.
    if (out.items.len > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, "dbname=");
    try out.appendSlice(allocator, wanted);

    // NUL-terminate.
    try out.append(allocator, 0);
    return out.toOwnedSliceSentinel(allocator, 0);
}
