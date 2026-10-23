//! Tests for the CONNECTION POOL, the `Config.conns` path: statements stop queueing behind one mutex, a
//! `Rows` outlives the connection that produced it, and nothing is lent without being handed back.

const std = @import("std");
const postgres = @import("Postgres.zig");
const helpers = @import("test_helpers.zig");

const PostgresBackend = postgres.PostgresBackend;
const Config = postgres.Config;
const testing = std.testing;

/// How long a claim or a holder waits before the test gives up on it, so a broken pool FAILS rather
/// than hanging the suite.
const CLAIM_DEADLINE_MS: i64 = 10_000;

fn nowMs(io: std.Io) i64 {
    return std.Io.Timestamp.now(io, .awake).toMilliseconds();
}

/// An isolated database opened with `cfg`, plus the name to drop it again. `io` is passed in rather than created here
/// on purpose: a `std.Io.Threaded` must not be MOVED, because the `std.Io` handle it hands out points back at it.
const Ctx = struct {
    db: PostgresBackend,
    db_name: []u8,

    fn deinit(self: *Ctx, alloc: std.mem.Allocator, base_conninfo: []const u8) void {
        self.db.deinit();
        helpers.dropDatabase(alloc, base_conninfo, self.db_name);
        alloc.free(self.db_name);
    }
};

fn setupDb(alloc: std.mem.Allocator, io: std.Io, base_conninfo: []const u8, cfg: Config) !Ctx {
    const db_name = try std.fmt.allocPrint(alloc, "ruangsql_pg_pool_{x}", .{helpers.nextDbCounter()});
    errdefer alloc.free(db_name);

    var created = false;
    errdefer if (created) helpers.dropDatabase(alloc, base_conninfo, db_name);
    try helpers.createDatabase(alloc, base_conninfo, db_name);
    created = true;

    const conninfo = try helpers.buildDbConninfo(alloc, base_conninfo, db_name);
    defer alloc.free(conninfo);

    var db: PostgresBackend = .{};
    errdefer db.deinit();
    try db.initWithConfig(io, conninfo, cfg);

    return .{ .db = db, .db_name = db_name };
}

/// `SELECT pg_backend_pid()`: the server's own session id, which is what tells one connection from
/// another. Two statements reporting the same pid ran on the SAME connection.
fn backendPid(alloc: std.mem.Allocator, db: *PostgresBackend) !i64 {
    return scalarInt(alloc, db, "SELECT pg_backend_pid()");
}

fn scalarInt(alloc: std.mem.Allocator, db: *PostgresBackend, sql: []const u8) !i64 {
    var row = try db.queryRow(alloc, sql, &.{});
    defer row.deinit(alloc);
    return std.fmt.parseInt(i64, row.values[0], 10);
}

// THE HEADLINE. A `pool.claim` holds one connection for the whole test, so whatever `queryRow` reports
// must be a DIFFERENT server session.
test "a statement runs on a pooled connection, not on the one already in use" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{});
    defer ctx.deinit(alloc, env.conninfo);

    const held = try ctx.db.pool.claim(io);
    defer ctx.db.pool.release(io, held);

    const held_pid = try backendPid(alloc, held);
    try testing.expect(held_pid != try backendPid(alloc, &ctx.db));
    try testing.expectEqual(@as(u64, 0), ctx.db.readFallbackCount());
}

// Elastic growth, and exclusivity with it: eight connections are held AT ONCE, so a pool that handed one
// connection to two holders, or serialised them, cannot satisfy this test.
test "eight connections claimed at once are eight distinct server sessions" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    const n = 8;
    var ctx = try setupDb(alloc, io, env.conninfo, .{ .conns = 2, .max_conns = n });
    defer ctx.deinit(alloc, env.conninfo);

    const Holder = struct {
        db: *PostgresBackend,
        alloc: std.mem.Allocator,
        index: usize,
        claimed: *std.atomic.Value(usize),
        release: *std.atomic.Value(bool),
        failed: *std.atomic.Value(bool),
        deadline_ms: i64,
        pids: [*]i64,

        fn run(self: *@This(), thread_io: std.Io) void {
            const slot = self.db.pool.claimOrWait(thread_io, @intCast(CLAIM_DEADLINE_MS)) catch {
                self.failed.store(true, .release);
                return;
            };
            defer self.db.pool.release(thread_io, slot);

            self.pids[self.index] = backendPid(self.alloc, slot) catch -1;
            _ = self.claimed.fetchAdd(1, .release);

            // Hold the connection until every other holder has one. If the pool serialised claims, the
            // waiters never register and the caller's deadline fails the test instead of hanging it.
            while (!self.release.load(.acquire)) {
                if (nowMs(thread_io) > self.deadline_ms) {
                    self.failed.store(true, .release);
                    return;
                }
                std.Io.sleep(thread_io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
            }
        }
    };

    var pids: [n]i64 = @splat(-1);
    var claimed = std.atomic.Value(usize).init(0);
    var release = std.atomic.Value(bool).init(false);
    var failed = std.atomic.Value(bool).init(false);
    var holders: [n]Holder = undefined;
    var threads: [n]std.Thread = undefined;
    var spawned: usize = 0;
    const deadline_ms = nowMs(io) + CLAIM_DEADLINE_MS;
    // Any failure below still has to join the threads, or the suite hangs on a live holder.
    errdefer {
        release.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
    }

    for (0..n) |i| {
        holders[i] = .{
            .db = &ctx.db,
            .alloc = alloc,
            .index = i,
            .claimed = &claimed,
            .release = &release,
            .failed = &failed,
            .deadline_ms = deadline_ms,
            .pids = &pids,
        };
        threads[i] = try std.Thread.spawn(.{}, Holder.run, .{ &holders[i], io });
        spawned += 1;
    }

    while (claimed.load(.acquire) < n) {
        if (nowMs(io) > deadline_ms) break;
        std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }
    release.store(true, .release);
    for (threads[0..spawned]) |t| t.join();

    try testing.expectEqual(false, failed.load(.acquire));
    try testing.expectEqual(@as(usize, n), claimed.load(.acquire));
    for (0..n) |i| {
        for (i + 1..n) |j| try testing.expect(pids[i] != pids[j]);
    }
    try testing.expectEqual(@as(usize, 0), ctx.db.pool.outstandingClaims());
    try testing.expectEqual(@as(usize, n), ctx.db.pool.count());
}

// `changes()` reads the PARENT backend, and the statement ran on a pooled connection: the count has to
// be carried back, or every `exec` that used the pool would answer 0.
test "changes() reports a write that ran on a pooled connection" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{});
    defer ctx.deinit(alloc, env.conninfo);

    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('a'), ('b'), ('c')", &.{});

    // Seven warm connections, seven still idle: both statements were served by the pool, and neither
    // had to fall back to the primary.
    try testing.expectEqual(@as(usize, 7), ctx.db.pool.idleCount());
    try testing.expectEqual(@as(u64, 0), ctx.db.readFallbackCount());
    try testing.expectEqual(@as(i64, 3), ctx.db.changes());

    try ctx.db.exec(alloc, "UPDATE foo SET id = 'x' WHERE id = ?", &.{"nonexistent"});
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

// A statement must never FAIL because the pool could not supply a connection. Out of capacity it waits for its
// budget, then runs on the primary — slower, since that connection is shared with every transaction, but correct.
test "a statement waits for a connection, then falls back to the primary" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    // A ceiling of 1 with that one connection already claimed: the pool cannot grow past it.
    var ctx = try setupDb(alloc, io, env.conninfo, .{ .conns = 1, .max_conns = 1, .conn_wait_ms = 25 });
    defer ctx.deinit(alloc, env.conninfo);

    const held = try ctx.db.pool.claim(io);
    defer ctx.db.pool.release(io, held);

    const start = nowMs(io);
    var row = try ctx.db.queryRow(alloc, "SELECT 1", &.{});
    const elapsed = nowMs(io) - start;
    defer row.deinit(alloc);

    try testing.expectEqualStrings("1", row.values[0]);
    try testing.expectEqual(@as(u64, 1), ctx.db.readFallbackCount());
    // It spent its budget first. Loose on purpose — the clock belongs to `std.Io`, and a slow machine
    // is not a bug.
    try testing.expect(elapsed >= 15);
}

// Growing is elastic; shrinking is not. An idle connection ABOVE the warm floor is closed by the next reaping pass, and the
// floor itself is never closed — `max_idle_time_ms = 0` makes that pass due now, so no test has to sleep through an idle timeout.
test "the pool shrinks back to its warm floor on release, and never below" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{ .conns = 2, .max_idle_time_ms = 0 });
    defer ctx.deinit(alloc, env.conninfo);

    const a = try ctx.db.pool.claim(io);
    const b = try ctx.db.pool.claim(io);
    const c = try ctx.db.pool.claim(io); // no idle connection left, so the pool grows to three
    try testing.expectEqual(@as(usize, 3), ctx.db.pool.count());

    ctx.db.pool.release(io, a);
    ctx.db.pool.release(io, b);
    ctx.db.pool.release(io, c);

    try testing.expectEqual(@as(usize, 2), ctx.db.pool.count());
    try testing.expectEqual(@as(usize, 2), ctx.db.pool.idleCount());
    try testing.expectEqual(@as(usize, 0), ctx.db.pool.outstandingClaims());
}

// The asymmetry with SQLite: `PQexecParams` buffers the WHOLE result set into the `PGresult`, so the connection goes back to the pool before the caller
// iterates. With a pool of exactly one, a second statement can only run by reusing that connection — which is what proves the iterator no longer pins it.
test "a live Rows survives its connection being reused by another statement" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{ .conns = 1, .max_conns = 1, .conn_wait_ms = 0 });
    defer ctx.deinit(alloc, env.conninfo);

    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('a'), ('b'), ('c')", &.{});

    var rows = try ctx.db.query(alloc, "SELECT id FROM foo ORDER BY id", &.{});
    defer rows.deinit();

    // Needs the one pooled connection, which the query has already handed back.
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('d')", &.{});
    try testing.expectEqual(@as(u64, 0), ctx.db.readFallbackCount());

    var seen: usize = 0;
    while (try rows.next()) |row| {
        row.deinit(alloc);
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

// A transaction owns the primary connection for its whole life, so its uncommitted work is invisible to
// the pooled connections serving everything else — and visible to the transaction itself.
test "a transaction keeps its own view while pooled statements see the committed state" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{});
    defer ctx.deinit(alloc, env.conninfo);

    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    defer tx.commitOrRollback() catch {};
    try tx.exec(alloc, "INSERT INTO foo VALUES ('uncommitted')", &.{});

    var inside = try tx.queryRow(alloc, "SELECT COUNT(*) FROM foo", &.{});
    defer inside.deinit(alloc);
    try testing.expectEqualStrings("1", inside.values[0]);

    try testing.expectEqual(@as(i64, 0), try scalarInt(alloc, &ctx.db, "SELECT COUNT(*) FROM foo"));

    try tx.commit();
    try testing.expectEqual(@as(i64, 1), try scalarInt(alloc, &ctx.db, "SELECT COUNT(*) FROM foo"));
}

// `conns = 0` is the single-connection backend: nothing is pooled, and every statement still lands on
// the primary connection and works.
test "conns = 0 keeps every statement on the primary connection" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{ .conns = 0 });
    defer ctx.deinit(alloc, env.conninfo);

    try testing.expectEqual(@as(usize, 0), ctx.db.pool.count());

    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try testing.expectEqual(@as(i64, 1), ctx.db.changes());
    // Not a fallback: with pooling off there is no pool to fall back FROM.
    try testing.expectEqual(@as(u64, 0), ctx.db.readFallbackCount());

    var row = try ctx.db.queryRow(alloc, "SELECT id FROM foo", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("a", row.values[0]);
}

// PostgreSQL re-parses and re-plans every `PQexecParams` call, so a repeated statement paid for its plan each time. A connection now
// prepares a statement on first use and re-executes it by name — per connection, so `conns = 0` is what makes the count observable.
test "one connection prepares a repeated statement once" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{ .conns = 0 });
    defer ctx.deinit(alloc, env.conninfo);

    try testing.expectEqual(@as(usize, 0), ctx.db.preparedStatements());

    for (0..3) |_| {
        var row = try ctx.db.queryRow(alloc, "SELECT 1", &.{});
        row.deinit(alloc);
    }
    try testing.expectEqual(@as(usize, 1), ctx.db.preparedStatements());

    var second = try ctx.db.queryRow(alloc, "SELECT 2", &.{});
    second.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), ctx.db.preparedStatements());

    // A multi-statement string cannot be prepared (the wire protocol's Parse rejects it), so it runs through `PQexecParams` as
    // before — and the refusal is REMEMBERED, so a repeated failing call does not pay a second failed `PQprepare` either.
    try testing.expectError(postgres.Error.ExecuteFailed, ctx.db.exec(alloc, "SELECT 1; SELECT 2", &.{}));
    try testing.expectError(postgres.Error.ExecuteFailed, ctx.db.exec(alloc, "SELECT 1; SELECT 2", &.{}));
    try testing.expectEqual(@as(usize, 2), ctx.db.preparedStatements());

    // DDL is preparable on the wire protocol, so it is cached like anything else — the statement
    // count is the observable proof that it went through the prepared path.
    try ctx.db.exec(alloc, "DROP TABLE IF EXISTS foo", &.{});
    try testing.expectEqual(@as(usize, 3), ctx.db.preparedStatements());
}

// The prepared path has to bind EACH call's arguments, and with the pool two calls of the same SQL text
// may run on two connections — each with its own prepared statement.
test "a prepared statement binds each call's own arguments" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{});
    defer ctx.deinit(alloc, env.conninfo);

    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES (?)", &.{"a"});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES (?)", &.{"b"});

    var count = try ctx.db.queryRow(alloc, "SELECT COUNT(*) FROM foo", &.{});
    defer count.deinit(alloc);
    try testing.expectEqualStrings("2", count.values[0]);

    var one = try ctx.db.queryRow(alloc, "SELECT id FROM foo WHERE id = ?", &.{"b"});
    defer one.deinit(alloc);
    try testing.expectEqualStrings("b", one.values[0]);
}

// `testing.allocator` is the pool's OWN allocator here, so a connection, an index list or the copied
// conninfo that `deinit` forgets fails this test: the pool holds memory the per-call allocator never sees.
test "deinit frees the pool's own allocations" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env = helpers.getOrStartTestInstance(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, io, env.conninfo, .{ .conns = 4, .allocator = alloc });
    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES (?)", &.{"a"});
    // A prepared statement caches a copy of its SQL, allocated with the pool's own allocator.
    var row = try ctx.db.queryRow(alloc, "SELECT id FROM foo WHERE id = ?", &.{"a"});
    row.deinit(alloc);
    try testing.expectEqual(@as(usize, 4), ctx.db.pool.idleCount());
    ctx.deinit(alloc, env.conninfo);
    // Nothing to assert: the allocator is the assertion.
}
