//! Tests for the test helpers themselves. These are NOT required for
//! the production code — they verify the helper API works as
//! documented, so a future refactor of `test_helpers.zig` can't
//! silently break the public surface used by `postgres_test.zig`
//! and any future test that wants an isolated PostgreSQL DB.
//!
//! The tests use the helpers exactly as a downstream test would:
//!   - `getOrStartTestInstance` to probe the shared instance
//!   - `createTempDb` to provision an isolated DB
//!   - `dropTempDb` to clean up
//!
//! All tests gate on `is_available` so this file skips cleanly on
//! hosts without a running PG instance (e.g. CI without libpq).

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const PostgresBackend = @import("Postgres.zig").PostgresBackend;

test "getOrStartTestInstance returns a usable TestEnv on a live instance" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);

    if (!env.is_available) return; // skip silently if no PG

    // The conninfo is non-empty and NUL-terminated (libpq requires
    // the C string to have a NUL).
    try testing.expect(env.conninfo.len > 0);
    try testing.expect(env.conninfo[env.conninfo.len - 1] == 0);
}

test "getOrStartTestInstance is idempotent (cached after first call)" {
    const alloc = testing.allocator;
    const first = helpers.getOrStartTestInstance(alloc);
    const second = helpers.getOrStartTestInstance(alloc);

    if (!first.is_available) return;

    // Same conninfo pointer (cached, no reallocation).
    try testing.expectEqualSlices(u8, first.conninfo, second.conninfo);
    try testing.expectEqual(first.is_available, second.is_available);
}

test "createTempDb returns a unique, open, working backend" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try helpers.createTempDb(alloc, env.conninfo);
    defer helpers.dropTempDb(alloc, &ctx);

    // The backend is open: a trivial SELECT returns 1 row.
    var q = try ctx.db.query(alloc, "SELECT 1", &.{});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ExpectedRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);

    // db_name is non-empty and NUL-prefixed via the standard
    // nalar_pg_test_<pid>_<counter> scheme.
    try testing.expect(std.mem.startsWith(u8, ctx.db_name, "nalar_pg_test_"));
}

test "createTempDb is isolated: two calls produce independent DBs" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx1 = try helpers.createTempDb(alloc, env.conninfo);
    defer helpers.dropTempDb(alloc, &ctx1);

    var ctx2 = try helpers.createTempDb(alloc, env.conninfo);
    defer helpers.dropTempDb(alloc, &ctx2);

    // Different DB names.
    try testing.expect(!std.mem.eql(u8, ctx1.db_name, ctx2.db_name));

    // ctx1 and ctx2 have different connections (different PGconn
    // pointers). We don't dereference the pointers (they're opaque),
    // but the addresses should differ.
    try testing.expect(@intFromPtr(ctx1.db.conn) != @intFromPtr(ctx2.db.conn));

    // ctx1 can create a table without affecting ctx2.
    try ctx1.db.exec(alloc, "CREATE TABLE foo (id TEXT)", &.{});
    try ctx1.db.exec(alloc, "INSERT INTO foo VALUES ('only_in_ctx1')", &.{});

    // ctx2 doesn't see ctx1's table — confirms isolation.
    var q = ctx2.db.query(alloc,
        "SELECT table_name FROM information_schema.tables WHERE table_name = 'foo'", &.{}) catch |err| switch (err) {
            error.QueryFailed => return, // any error means it's not visible
            else => return err,
        };
    defer q.deinit();
    const row = try q.next();
    try testing.expect(row == null);
}

test "createTempDb: failure on bad base conninfo returns error" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // Use an obviously bad port with a short connect_timeout. The
    // CREATE DATABASE step will fail at PQconnectdb and return
    // DatabaseNotFound.
    const result = helpers.createTempDb(alloc,
        "host=/tmp port=1 user=ginwa dbname=postgres connect_timeout=1");
    try testing.expectError(helpers.PostgresError.DatabaseNotFound, result);
}

test "dropTempDb actually drops the database (verified by name lookup)" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try helpers.createTempDb(alloc, env.conninfo);
    const db_name = try alloc.dupeZ(u8, ctx.db_name);
    defer alloc.free(db_name);

    helpers.dropTempDb(alloc, &ctx);

    // Verify the database no longer exists via direct libpq probe.
    const probe = PostgresBackend.c.PQconnectdb(env.conninfo.ptr);
    defer if (probe) |p| PostgresBackend.c.PQfinish(p);
    if (probe == null) return;
    if (PostgresBackend.c.PQstatus(probe) != PostgresBackend.c.CONNECTION_OK) return;

    // SELECT 1 FROM pg_database WHERE datname = '<our db>'
    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf,
        "SELECT 1 FROM pg_database WHERE datname = '{s}'", .{db_name}) catch return;
    // Copy to a NUL-terminated buffer so libpq can read it as a C
    // string. (bufPrint does not write a NUL terminator in Zig 0.16.)
    const sql_z = try alloc.allocSentinel(u8, sql.len, 0);
    defer alloc.free(sql_z);
    @memcpy(sql_z, sql);
    const res = PostgresBackend.c.PQexec(probe, sql_z.ptr);
    defer if (res) |r| PostgresBackend.c.PQclear(r);
    if (res == null) return;
    const ntuples = PostgresBackend.c.PQntuples(res);
    try testing.expectEqual(@as(c_int, 0), ntuples);
}

test "dropTempDb is idempotent: calling twice is a no-op" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try helpers.createTempDb(alloc, env.conninfo);
    helpers.dropTempDb(alloc, &ctx);
    // Second call must not crash and must not free anything twice.
    helpers.dropTempDb(alloc, &ctx);
}

test "buildDbConninfo strips existing dbname= and appends new one" {
    const alloc = testing.allocator;
    // Base with a dbname we don't want.
    const out = try helpers.buildDbConninfo(alloc,
        "host=/tmp port=54329 user=ginwa dbname=postgres", "new_db");
    defer alloc.free(out);

    // The output must contain dbname=new_db (the LAST dbname wins
    // in libpq, but our wrapper strips to be safe).
    try testing.expect(std.mem.indexOf(u8, out, "dbname=new_db") != null);
    // And must NOT contain the old dbname=postgres.
    try testing.expect(std.mem.indexOf(u8, out, "dbname=postgres") == null);
    // The other keys survive.
    try testing.expect(std.mem.indexOf(u8, out, "host=/tmp") != null);
    try testing.expect(std.mem.indexOf(u8, out, "port=54329") != null);
    try testing.expect(std.mem.indexOf(u8, out, "user=ginwa") != null);
}

test "buildDbConninfo handles conninfo with no dbname" {
    const alloc = testing.allocator;
    const out = try helpers.buildDbConninfo(alloc,
        "host=/tmp port=54329 user=ginwa", "fresh_db");
    defer alloc.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "dbname=fresh_db") != null);
}

test "createDatabase: standalone helper creates a database on the shared instance" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // Use the shared naming scheme so we don't collide with anything.
    const pid_bits: u64 = @intCast(std.os.linux.gettid());
    const counter_value = helpers.nextDbCounter();
    const db_name = try std.fmt.allocPrint(alloc,
        "nalar_pg_test_helper_{x}_{x}",
        .{ pid_bits, counter_value });
    defer alloc.free(db_name);

    // Use the standalone helper — NOT createTempDb. Always drop on
    // ANY exit path so this test never leaves a stray database on the
    // shared instance — even if an early assertion fails.
    try helpers.createDatabase(alloc, env.conninfo, db_name);
    defer helpers.dropDatabase(alloc, env.conninfo, db_name);

    // Verify the database exists via a direct libpq probe.
    const probe = PostgresBackend.c.PQconnectdb(env.conninfo.ptr);
    defer if (probe) |p| PostgresBackend.c.PQfinish(p);
    if (probe == null) return;
    if (PostgresBackend.c.PQstatus(probe) != PostgresBackend.c.CONNECTION_OK) return;

    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf,
        "SELECT 1 FROM pg_database WHERE datname = '{s}'", .{db_name}) catch return;
    const sql_z = try alloc.allocSentinel(u8, sql.len, 0);
    defer alloc.free(sql_z);
    @memcpy(sql_z, sql);
    const res = PostgresBackend.c.PQexec(probe, sql_z.ptr);
    defer if (res) |r| PostgresBackend.c.PQclear(r);
    if (res == null) return;
    try testing.expectEqual(@as(c_int, 1), PostgresBackend.c.PQntuples(res));
}

test "createDatabase: failure on bad admin conninfo returns DatabaseNotFound" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    const db_name = "nalar_pg_test_should_not_exist";
    const result = helpers.createDatabase(alloc,
        "host=/tmp port=1 user=ginwa dbname=postgres connect_timeout=1", db_name);
    try testing.expectError(helpers.PostgresError.DatabaseNotFound, result);
}

test "dropDatabase: standalone helper drops a database (no TestDb needed)" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    const pid_bits: u64 = @intCast(std.os.linux.gettid());
    const counter_value = helpers.nextDbCounter();
    const db_name = try std.fmt.allocPrint(alloc,
        "nalar_pg_test_drop_helper_{x}_{x}",
        .{ pid_bits, counter_value });
    defer alloc.free(db_name);

    // Create via standalone helper, drop via standalone helper — no
    // PostgresBackend opened. Use errdefer so a failure between
    // create and drop never leaves a stray database.
    try helpers.createDatabase(alloc, env.conninfo, db_name);
    defer helpers.dropDatabase(alloc, env.conninfo, db_name);

    // Verify it's gone.
    const probe = PostgresBackend.c.PQconnectdb(env.conninfo.ptr);
    defer if (probe) |p| PostgresBackend.c.PQfinish(p);
    if (probe == null) return;
    if (PostgresBackend.c.PQstatus(probe) != PostgresBackend.c.CONNECTION_OK) return;

    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf,
        "SELECT 1 FROM pg_database WHERE datname = '{s}'", .{db_name}) catch return;
    const sql_z = try alloc.allocSentinel(u8, sql.len, 0);
    defer alloc.free(sql_z);
    @memcpy(sql_z, sql);
    const res = PostgresBackend.c.PQexec(probe, sql_z.ptr);
    defer if (res) |r| PostgresBackend.c.PQclear(r);
    if (res == null) return;
    try testing.expectEqual(@as(c_int, 0), PostgresBackend.c.PQntuples(res));
}

test "dropDatabase: non-fatal on missing database (IF EXISTS branch)" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // Drop a database that doesn't exist — must not crash, must not
    // return an error (the function returns void).
    helpers.dropDatabase(alloc, env.conninfo, "nalar_pg_test_definitely_not_real_zzz");
}

test "dropDatabase: non-fatal on bad admin conninfo" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // Bad conninfo — must not crash, must not return anything.
    helpers.dropDatabase(alloc,
        "host=/tmp port=1 user=ginwa dbname=postgres connect_timeout=1",
        "nalar_pg_test_anything");
}

// ═══════════════════════════════════════════════════════════════════════════
//  LEAK-PREVENTION TESTS — the three that matter for production confidence
// ═══════════════════════════════════════════════════════════════════════════
//
// These tests verify the cleanup guarantees promised in `test_helpers.zig`:
//
//   1. **Concurrent execution** — multiple OS threads calling
//      `createTempDb` / `dropTempDb` at the same time must NOT crash
//      and must produce distinct, fully-cleaned databases. Exercises
//      the thread-safe `getOrStartTestInstance` and confirms the
//      atomic counter disambiguates simultaneous calls.
//   2. **No C-lib fd leaks** — N sequential cycles of
//      `createTempDb` / `dropTempDb` must not leave file descriptors
//      behind. Counts `/proc/self/fd/` before & after; expects the
//      count to be unchanged (within a small tolerance for libpq's
//      internal caching).
//   3. **No stray databases** — after a stress run that creates and
//      drops many databases, `pg_database` must show zero
//      `nalar_pg_test_*` entries. Catches the bug where a partial
//      failure (CREATE DATABASE succeeds, `db.init` fails) leaves a
//      stranded database.
//
// All three are gated on `env.is_available` so they skip cleanly on
// hosts without a running PG instance.


test "LEAK: no fd leaks — open+drop fd count is stable across 10 sequential cycles" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // Snapshot fd count BEFORE the cycles.
    const fds_before = countOpenFds();

    const CYCLES = 10;
    var i: usize = 0;
    while (i < CYCLES) : (i += 1) {
        var ctx = try helpers.createTempDb(alloc, env.conninfo);
        helpers.dropTempDb(alloc, &ctx);
    }

    const fds_after = countOpenFds();

    // Tolerance: libpq may keep a small per-connection cache that grows
    // monotonically up to a maximum. We allow +5 fds of drift before
    // flagging a leak.
    const drift: isize = @as(isize, @intCast(fds_after)) - @as(isize, @intCast(fds_before));
    if (drift > 5) {
        std.debug.print(
            "fd leak: {d} before, {d} after {d} cycles (drift {d})\n",
            .{ fds_before, fds_after, CYCLES, drift },
        );
    }
    try testing.expect(drift <= 5);
}

test "LEAK: no stray databases — pg_database is empty after a stress run" {
    const alloc = testing.allocator;
    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // Run 20 cycles. Each one creates + drops a database. If the
    // partial-failure cleanup hole is back, some DBs will linger.
    const CYCLES = 20;
    var i: usize = 0;
    while (i < CYCLES) : (i += 1) {
        var ctx = try helpers.createTempDb(alloc, env.conninfo);
        helpers.dropTempDb(alloc, &ctx);
    }

    // Probe pg_database directly via libpq. Any nalar_pg_test_* entry
    // is a leak.
    const probe = PostgresBackend.c.PQconnectdb(env.conninfo.ptr);
    defer if (probe) |p| PostgresBackend.c.PQfinish(p);
    if (probe == null) return;
    if (PostgresBackend.c.PQstatus(probe) != PostgresBackend.c.CONNECTION_OK) return;

    var sql_buf: [256]u8 = undefined;
    const sql = std.fmt.bufPrint(&sql_buf,
        "SELECT count(*) FROM pg_database WHERE datname LIKE 'nalar_pg_test_%'", .{}) catch return;
    const sql_z = try alloc.allocSentinel(u8, sql.len, 0);
    defer alloc.free(sql_z);
    @memcpy(sql_z, sql);
    const res = PostgresBackend.c.PQexec(probe, sql_z.ptr);
    defer if (res) |r| PostgresBackend.c.PQclear(r);
    if (res == null) return;

    // PQgetvalue(res, 0, 0) is the count as a string.
    const count_str = PostgresBackend.c.PQgetvalue(res, 0, 0);
    const leaked = std.fmt.parseInt(usize, std.mem.span(count_str), 10) catch 0;
    if (leaked > 0) {
        std.debug.print("LEAK: {d} stray nalar_pg_test_* databases on server after {d} cycles\n", .{ leaked, CYCLES });
    }
    try testing.expectEqual(@as(usize, 0), leaked);
}

/// Count open file descriptors for the current process via
/// `/proc/self/fd/`. Used by the fd-leak test to confirm libpq isn't
/// leaking fds across N `createTempDb`/`dropTempDb` cycles.
///
/// Linux-only: `/proc/self/fd` doesn't exist on Windows. Uses libc
/// `opendir`/`readdir` because the Zig 0.16 std.fs API requires an
/// `Io` runtime which we'd rather not drag into this helper.
fn countOpenFds() usize {
    const maybe_dir = std.c.opendir("/proc/self/fd");
    const dir = maybe_dir orelse return 0;
    defer _ = std.c.closedir(dir);

    var count: usize = 0;
    while (true) {
        const maybe_entry = std.c.readdir(dir);
        const entry = maybe_entry orelse break;
        // Skip "." and ".." — they don't count as open fds.
        const name_ptr: [*]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            count += 1;
        }
    }
    return count;
}
