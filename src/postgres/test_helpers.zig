//! PostgreSQL test helpers: the shared, probed test instance plus the `createTempDb` /
//! `dropTempDb` names the backend's tests use — both now thin shims over `database.TempDb`.

const std = @import("std");
const database = @import("../database.zig");
const pg_temp_db = @import("temp_db.zig");
const Error = @import("Postgres.zig").Error;

/// Re-export of `Postgres.zig::Error`, so tests can write
/// `helpers.Error.DatabaseNotFound` without importing `Postgres.zig`.
pub const PostgresError = Error;

pub const DEFAULT_TEST_CONNINFO = pg_temp_db.DEFAULT_CONNINFO;

/// Environment state for one test process, cached globally by
/// `getOrStartTestInstance`: `conninfo` borrows that never-freed cache and stays valid for the process.
pub const TestEnv = struct {
    conninfo: [:0]const u8,
    is_available: bool,
};

/// A temp database on the shared instance — the universal type, so field names and
/// cleanup are the same whichever backend an app compiled in.
pub const TestDb = database.TempDb;

pub var g_test_env: TestEnv = undefined;
pub var g_test_env_initialized: bool = false;

/// One-shot probe of the test PG instance, cached — only the first call hits the
/// network. Tests skip when `is_available` is false; NOT thread-safe, so populate the cache before spawning threads.
pub fn getOrStartTestInstance(allocator: std.mem.Allocator) TestEnv {
    _ = allocator;
    if (g_test_env_initialized) return g_test_env;

    const conninfo = pg_temp_db.resolveBaseConninfo();
    g_test_env = .{
        .conninfo = conninfo,
        .is_available = pg_temp_db.probe(conninfo),
    };
    g_test_env_initialized = true;
    return g_test_env;
}

pub const nextDbCounter = pg_temp_db.nextDbCounter;
pub const createDatabase = pg_temp_db.createDatabase;
pub const dropDatabase = pg_temp_db.dropDatabase;
pub const buildDbConninfo = pg_temp_db.buildDbConninfo;

/// Create a fresh, isolated PG DB on the shared instance and open a backend
/// against it; the caller MUST `dropTempDb`.
pub fn createTempDb(allocator: std.mem.Allocator, base_conninfo: [:0]const u8) Error!TestDb {
    return database.createTempDb(allocator, .{ .base_conninfo = base_conninfo });
}

/// Close the backend and drop the database. Idempotent, and `allocator` is ignored:
/// the `TestDb` carries the one it was created with.
pub fn dropTempDb(allocator: std.mem.Allocator, ctx: *TestDb) void {
    _ = allocator;
    ctx.deinit();
}
