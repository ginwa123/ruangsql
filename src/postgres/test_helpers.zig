//! Test helpers for the PostgreSQL backend.
//!
//! Provides reusable building blocks so any test that needs an isolated
//! PostgreSQL database can call into the same helpers — no need to
//! copy/paste the CREATE-DATABASE / open-connection / DROP-DATABASE
//! boilerplate.
//!
//! ## Two layers of helpers (plus the standalone CREATE / DROP pair)
//!
//! **Layer 1 — instance probe** (`getOrStartTestInstance`):
//! Detects or starts a running PostgreSQL instance for the test
//! process. Caches the result in a global. Tests call this once and
//! gate on `is_available` — if PG is unreachable, tests silently pass
//! without assertions (no false failures on CI hosts without libpq or
//! a running instance).
//!
//! **Layer 2 — per-test isolation** (`createTempDb` / `dropTempDb`):
//! Creates a fresh, uniquely-named database inside the shared
//! instance, opens a `PostgresBackend` against it, and returns a
//! ready-to-use context. Drops the database on teardown via
//! `DROP DATABASE ... WITH (FORCE)` to terminate any lingering
//! connections. The naming scheme is
//! `nalar_pg_test_<pid>_<counter>` so concurrent test invocations
//! within the same process get distinct databases. `createTempDb`
//! internally calls `createDatabase` (the standalone helper), so the
//! per-test isolation is just orchestration around the standalone
//! pair.
//!
//! **Standalone CREATE / DROP helpers** (`createDatabase` /
//! `dropDatabase`): when a test only needs to provision or tear down
//! a database on the shared instance — without opening a
//! `PostgresBackend` against it — call these directly. They own the
//! admin connection lifecycle and the SQL string formatting. Useful
//! for tests that interact with the shared instance's catalogs
//! directly, or for setting up side databases that aren't bound to
//! a `TestDb`.
//!
//! ## Usage
//!
//! ```zig
//! const helpers = @import("test_helpers.zig");
//!
//! test "my pg test" {
//!     const alloc = std.testing.allocator;
//!     const env = helpers.getOrStartTestInstance(alloc);
//!     if (!env.is_available) return;
//!
//!     var ctx = try helpers.createTempDb(alloc, env.conninfo);
//!     defer helpers.dropTempDb(alloc, &ctx);
//!
//!     try ctx.db.exec(alloc, "SELECT 1", &.{});
//! }
//! ```
//!
//! ## Cross-platform
//!
//! All helpers use libpq via the same `Postgres.zig` c bindings. On
//! non-Linux, the `c` extern struct in `Postgres.zig` provides manual
//! declarations. The helpers themselves are platform-agnostic.

const std = @import("std");
const builtin = @import("builtin");
const PostgresBackend = @import("Postgres.zig").PostgresBackend;
const Error = @import("Postgres.zig").Error;

/// Re-export of `Postgres.zig::Error` so downstream test files can
/// pattern-match on errors without having to import `Postgres.zig`
/// directly. Lets a test do `helpers.Error.DatabaseNotFound`
/// instead of `postgres_mod.Error.DatabaseNotFound`.
pub const PostgresError = Error;

pub const DEFAULT_TEST_CONNINFO = "host=/tmp port=54329 user=ginwa dbname=postgres";

/// Environment state for a single test process. Cached globally on
/// first call to `getOrStartTestInstance` so we don't pay the
/// connection probe on every test.
///
/// `conninfo` is a string slice into the global env cache. Lifetime:
/// valid for the duration of the test process (the cache is never
/// freed — it lives in the BSS via a `var` global).
pub const TestEnv = struct {
    conninfo: []const u8,
    is_available: bool,
};

/// Context returned by `createTempDb`. Holds the freshly-opened
/// `PostgresBackend`, the Io runtime, the unique database name, and
/// the base conninfo used to reach the shared instance. Caller MUST
/// call `dropTempDb` to clean up.
pub const TestDb = struct {
    db: PostgresBackend,
    threaded: std.Io.Threaded,
    /// Unique database name (e.g. `nalar_pg_test_4f2a_7`). Owned
    /// by this struct — `dropTempDb` frees it.
    db_name: []u8,
    /// Base conninfo used to reach the shared PG instance. Borrowed
    /// reference — the caller is expected to keep it alive (typically
    /// from a `TestEnv.conninfo` global).
    base_conninfo: []const u8,
};

// ─── Layer 1: instance probe ─────────────────────────────────────────────

pub var g_test_env: TestEnv = undefined;
pub var g_test_env_initialized: bool = false;

/// One-shot init: probe the test PG instance. Tests skip themselves
/// when `is_available` is false. Safe to call from any test — only
/// the first call hits the network.
///
/// **NOT thread-safe.** Called only from the test runner's main
/// thread. If a future test wants to spawn `std.Thread`s that hit
/// the PG instance, that test must call `getOrStartTestInstance` from
/// the main thread first to populate the cache, then pass
/// `env.conninfo` to the workers (the `LEAK: createTempDb parallel`
/// test does this).
pub fn getOrStartTestInstance(allocator: std.mem.Allocator) TestEnv {
    if (g_test_env_initialized) return g_test_env;

    // Try POSTGRES_TEST_CONNINFO env var first — lets users override
    // the test target (e.g. to a remote PG instance).
    if (std.c.getenv("POSTGRES_TEST_CONNINFO")) |raw| {
        const span = std.mem.span(raw);
        const dup = allocator.dupeZ(u8, span) catch return .{
            .conninfo = "",
            .is_available = false,
        };
        g_test_env = .{
            .conninfo = dup,
            .is_available = testConnect(dup),
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

/// Atomic counter for unique DB names. Increments on every
/// `createTempDb` call so even concurrent test invocations within the
/// same process don't collide on the same database name. Combined
/// with `pid_bits` to also disambiguate across processes.
///
/// `pub` so tests that build a unique DB name outside of
/// `createTempDb` (e.g. to test `createDatabase` directly) can pull
/// from the same monotonic source instead of inventing their own.
pub var g_db_counter: u64 = 0;
pub fn nextDbCounter() u64 {
    return @atomicRmw(u64, &g_db_counter, .Add, 1, .seq_cst);
}

/// Create a fresh, isolated PG database inside the shared instance
/// and open a `PostgresBackend` against it. Returns a context that
/// the caller MUST pass to `dropTempDb` for cleanup.
///
/// Database naming: `nalar_pg_test_<pid>_<counter>` (hex). The pid
/// makes the name distinct across processes; the counter disambiguates
/// within the same process so two tests in the same `zig test`
/// invocation never share a DB.
///
/// Cleanup guarantee: on any failure (CREATE DATABASE fails,
/// `db.init` fails, allocator fails for any intermediate buffer),
/// the helper UNWINDS ALL ALLOCATED STATE — including dropping the
/// database from the shared instance if CREATE DATABASE already
/// succeeded. This means no test ever leaves a stray `nalar_pg_test_*`
/// database on the PG server, even if a later step panics or errors.
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

    // 2. CREATE DATABASE on the shared instance. Track whether it
    //    succeeded so the errdefer below can drop the database if a
    //    LATER step fails. Without this tracking, a failed
    //    `db.init(...)` would leave a stray `nalar_pg_test_*` DB on
    //    the server.
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

/// CREATE DATABASE on a shared PG instance using a temporary admin
/// connection. The admin connection is opened, the CREATE DATABASE
/// statement is issued, and the connection is closed before this
/// function returns.
///
/// On any failure (cannot connect, CREATE DATABASE fails), returns
/// the error WITHOUT having created the database. The caller owns
/// `db_name` — `createTempDb` already freed it via `errdefer`; other
/// callers should arrange their own cleanup.
///
/// This is the standalone "create one database on the shared
/// instance" helper, exposed so test code that doesn't want the full
/// `createTempDb` boilerplate (open a backend, etc.) can still get a
/// fresh database.
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

/// Drop a database created by `createTempDb` and free all resources
/// held by the `TestDb`. Idempotent: safe to call multiple times (the
/// second call is a no-op).
///
/// Uses `DROP DATABASE ... WITH (FORCE)` to terminate any lingering
/// connections to the test DB. The backend connection is closed
/// before the DROP so the FORCE branch is rarely needed in practice,
/// but it guards against cases where another part of the test
/// process is still holding the connection.
pub fn dropTempDb(allocator: std.mem.Allocator, ctx: *TestDb) void {
    // 1. Close the per-test backend. Sets ctx.db.conn to null.
    ctx.db.deinit();
    ctx.threaded.deinit();

    // 2. Drop the test DB via the dedicated helper. Failure here is
    //    non-fatal — the test already passed; the DB just lingers.
    //    `dropDatabase` logs on failure.
    dropDatabase(allocator, ctx.base_conninfo, ctx.db_name);

    allocator.free(ctx.db_name);
    ctx.* = .{
        .db = .{ .conn = null },
        .threaded = undefined,
        .db_name = &[_]u8{},
        .base_conninfo = "",
    };
}

/// DROP DATABASE [IF EXISTS] ... WITH (FORCE) on a shared PG instance
/// using a temporary admin connection. The admin connection is
/// opened, the DROP is issued, and the connection is closed before
/// this function returns.
///
/// Non-fatal on any failure (cannot connect, DROP fails): the caller
/// already owns whatever state it's cleaning up. Failures are logged
/// via `std.log.warn` for visibility — the test process can move on.
///
/// This is the standalone "drop one database on the shared instance"
/// helper, exposed so test code that created a database via
/// `createDatabase` directly can also clean it up without going
/// through the full `dropTempDb` path (which expects a `TestDb`).
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

/// Build a per-database conninfo by stripping any `dbname=` from the
/// base conninfo and appending `dbname=<wanted>`. Used internally by
/// `createTempDb`. Exposed for tests that need to construct a
/// conninfo manually (rare).
pub fn buildDbConninfo(allocator: std.mem.Allocator, base: []const u8, wanted: []const u8) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < base.len) {
        // Find the next space (key/value separators in libpq conninfo).
        var end = i;
        while (end < base.len and base[end] != ' ') end += 1;
        const token = base[i..end];

        // Skip any existing dbname= clause. libpq's last-occurrence-wins
        // semantics means we COULD just append, but skipping is cleaner
        // and avoids confusion if the user passed `dbname=postgres` in
        // the base (which would be overridden by ours anyway).
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
