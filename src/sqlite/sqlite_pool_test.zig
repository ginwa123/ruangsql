//! Tests for READER POOLING, the `Config.read_conns` path: `:memory:` skips pooling entirely, so this file is the only one exercising it.
//! Pins two invariants: a live `Rows` pins its reader's read transaction (later reads on it are stale), and `exec`/`queryRow` must not rebind the statement a live `Rows` is stepping.

const std = @import("std");
const sqlite = @import("Sqlite.zig");

const SqliteBackend = sqlite.SqliteBackend;
const Config = sqlite.Config;
const testing = std.testing;

/// A file-backed backend with pooling ON, plus the runtime and path.
const Pool = struct {
    threaded: std.Io.Threaded,
    db: SqliteBackend,
    tmp: testing.TmpDir,

    fn init(cfg: Config) !Pool {
        const alloc = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
        const joined = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "pool.db" });
        defer alloc.free(joined);
        const path = try alloc.dupeZ(u8, joined);
        defer alloc.free(path);

        var threaded = std.Io.Threaded.init(alloc, .{});
        errdefer threaded.deinit();

        var db: SqliteBackend = .{};
        errdefer db.deinit();
        try db.initWithConfig(threaded.io(), path, cfg);

        try db.exec(alloc, "CREATE TABLE t (id TEXT PRIMARY KEY, v TEXT NOT NULL)", &.{});
        try db.exec(alloc, "INSERT INTO t (id, v) VALUES ('1', 'before')", &.{});

        return .{ .threaded = threaded, .db = db, .tmp = tmp };
    }

    fn deinit(self: *Pool) void {
        self.db.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
    }

    fn io(self: *Pool) std.Io {
        return self.threaded.io();
    }
};

/// Count this process's open file descriptors. 0 where there is no way to
/// ask, so the test that uses it asserts nothing rather than guessing.
fn countOpenFds() usize {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return 0;
    var dir = std.Io.Dir.openDirAbsolute(testing.io, "/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer dir.close(testing.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (it.next(testing.io) catch null) |_| n += 1;
    return n;
}

// THE FD BUG. A pooled reader is not one descriptor: an open WAL connection holds the database file, its `-wal` and its `-shm`, so an
// uncapped elastic pool spends `3 x peak concurrent reads` fds for the life of the process — and the failure reads like a permissions problem.
test "each pooled reader costs FDS_PER_READER descriptors, not one" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1, .max_read_conns = 0 });
    defer p.deinit();

    const before = countOpenFds();
    // Claim more readers at once than the warm floor, so the pool has to OPEN connections rather than reuse idle ones, and run a real read
    // on each: a connection holds only the database fd until it touches the WAL, so counting without a query understates the cost by 2 fds.
    const extra = 6;
    var held: [6]*SqliteBackend = undefined;
    for (0..extra) |i| {
        held[i] = try p.db.pool.claim(testing.io);
        var row = try held[i].queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
        defer row.deinit(alloc);
    }
    const after = countOpenFds();
    for (held) |slot| p.db.pool.release(testing.io, slot);

    // One of the claims reused the pre-warmed reader, so only `extra - 1`
    // new connections were opened.
    const opened = extra - 1;
    try testing.expectEqual(@as(usize, extra), p.db.pool.count());
    try testing.expectEqual(@as(usize, 2), sqlite.FDS_PER_READER);
    // No spare needed: `countOpenFds` opens its directory handle in BOTH
    // samples, so it cancels out of the delta.
    try testing.expectEqual(sqlite.FDS_PER_READER * opened, after -| before);
}

// The hard ceiling that stops it. `max_read_conns = 0` means "no POLICY cap", not "no cap": the pool must still refuse to grow past
// what the process's `RLIMIT_NOFILE` can fund after reserving headroom.
test "an uncapped pool still stops at the fd-derived ceiling" {
    const cap = sqlite.fdDerivedReaderCap();
    try testing.expect(cap >= 1);
    try testing.expect(sqlite.FD_HEADROOM > 0);
    // Headroom is reserved, so the ceiling is well under the raw quota.
    try testing.expect(cap < 1 << 20);

    // Prove the pool obeys the SMALLER of policy and fds.
    var p = try Pool.init(.{ .read_conns = 1, .max_read_conns = 2 });
    defer p.deinit();

    var held: [4]*SqliteBackend = undefined;
    var ok: usize = 0;
    for (0..4) |_| {
        held[ok] = p.db.pool.claim(testing.io) catch break;
        ok += 1;
    }
    for (held[0..ok]) |slot| p.db.pool.release(testing.io, slot);

    try testing.expectEqual(@as(usize, 2), ok);
    try testing.expectEqual(@as(usize, 2), p.db.pool.count());
}

// A read must never FAIL because the pool could not grow: out of capacity — fd quota, memory, anything — it falls back to the primary
// connection, slower (it serializes against every write and holds the writer's mutex) but correct, and only once the wait budget is spent.
test "a read waits for a reader, then falls back to the write connection" {
    const alloc = testing.allocator;
    // Cap of 1 with that one reader already claimed: the pool cannot grow. `reader_wait_ms` is small so the budget is observable without
    // making the suite wait seconds.
    var p = try Pool.init(.{ .read_conns = 1, .max_read_conns = 1, .reader_wait_ms = 25 });
    defer p.deinit();
    const io = p.io();

    const held = try p.db.pool.claim(io);
    defer p.db.pool.release(io, held);

    const start = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const row = try p.db.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    const elapsed = std.Io.Timestamp.now(io, .awake).toMilliseconds() - start;
    defer row.deinit(alloc);

    try testing.expectEqualStrings("before", row.values[0]);
    // Exactly one fallback: this read, and nothing else.
    try testing.expectEqual(@as(u64, 1), p.db.readFallbackCount());
    // It waited for its budget rather than falling through. Loose bound on
    // purpose — the clock is `std.Io`'s, and a slow machine is not a bug.
    try testing.expect(elapsed >= 15);
}

// THE REGRESSION THAT PRODUCED THE WARNING STORM. A burst of reads against a full pool logged "reader pool unavailable (PoolExhausted)"
// once per read and ran every one on the write connection; a reader that frees a few ms later is worth waiting for, so this read blocks.
test "a read that finds the pool full waits for a reader instead of taking the write connection" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1, .max_read_conns = 1, .reader_wait_ms = 5_000 });
    defer p.deinit();
    const io = p.io();

    // The only reader is busy. That is what "the pool is full" means.
    const held = try p.db.pool.claim(io);

    const Releaser = struct {
        db: *SqliteBackend,
        slot: *SqliteBackend,

        fn run(ctx: *@This(), thread_io: std.Io) void {
            // Long enough that the read is certainly already blocked, so the wake-up comes from `release`'s signal and not from the reader
            // having been idle when the read arrived.
            std.Io.sleep(thread_io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch return;
            ctx.db.pool.release(thread_io, ctx.slot);
        }
    };
    var ctx = Releaser{ .db = &p.db, .slot = held };
    const releaser = try std.Thread.spawn(.{}, Releaser.run, .{ &ctx, io });
    defer releaser.join();

    const row = try p.db.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("before", row.values[0]);

    // THE ASSERTION. The value above is worthless as evidence — a read on the write connection returns the same string, which is exactly
    // why the bug shipped. What separates the two paths is whether the pool had to hand this read to the writer.
    try testing.expectEqual(@as(u64, 0), p.db.readFallbackCount());
}

// `read_conns` is the warm floor `init` opens eagerly; `max_read_conns` is the ceiling it refuses to grow past. A cap AT OR BELOW the
// floor starves the pool: it reports itself full while sitting on connections it just opened, so every read falls back to the writer.
test "a policy cap at or below the warm floor cannot starve the pool" {
    var p = try Pool.init(.{ .read_conns = 4, .max_read_conns = 1 });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 4), p.db.pool.count());
    try testing.expectEqual(@as(usize, 4), p.db.pool.idleCount());

    // And every one of them is usable: four claims, no fallback.
    var held: [4]*SqliteBackend = undefined;
    for (0..4) |i| held[i] = try p.db.pool.claim(p.io());
    for (held) |slot| p.db.pool.release(p.io(), slot);
    try testing.expectEqual(@as(usize, 4), p.db.pool.idleCount());
}

// `release` is reached from `Rows.deinit`, which a caller can reach twice (a `Rows` copied by value, a retry that deinits the error
// path too). Two `idle` entries for one connection make the next two `claim`s hand out the SAME sqlite handle — one read steps another's statement.
test "a repeated release cannot duplicate one connection into the idle list" {
    var p = try Pool.init(.{ .read_conns = 1, .max_read_conns = 1 });
    defer p.deinit();
    const io = p.io();

    const conn = try p.db.pool.claim(io);
    p.db.pool.release(io, conn);
    p.db.pool.release(io, conn);

    try testing.expectEqual(@as(usize, 1), p.db.pool.idleCount());
    try testing.expectEqual(@as(usize, 1), p.db.pool.count());

    // The one idle entry is the connection we released — not a stranger.
    const again = try p.db.pool.claim(io);
    try testing.expect(again == conn);
    p.db.pool.release(io, again);
}

// Positive control: pooling must not break the basic write→read path. `read_conns = 1` keeps it deterministic — the single reader is
// the only place a read can land — so the staleness tests below cannot pass vacuously (e.g. if routing made every read fail).
test "control: a committed write is visible to the next pooled read" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();

    try p.db.exec(alloc, "UPDATE t SET v = 'after' WHERE id = ?", &.{"1"});

    var rows = try p.db.query(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer rows.deinit();
    const row = (try rows.next()) orelse return error.NoRow;
    defer row.deinit(alloc);

    try testing.expectEqualStrings("after", row.values[0]);
}

// THE BUG. A `Rows` still open pins its connection's read transaction, and every LATER read that lands on that connection sees the
// pinned snapshot instead of committed data — not a caller leak: `query` releases the mutex before the caller has finished stepping.
test "a live Rows pins its connection's snapshot; later reads on it are stale" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();

    // Open an iterator and read one row: this takes reader-1's read transaction and leaves it OPEN, because `query` handed the statement
    // back to us and released the mutex.
    var rows = try p.db.query(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer rows.deinit();
    {
        const row = (try rows.next()) orelse return error.NoRow;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("before", row.values[0]);
    }

    // A DIFFERENT request commits a write. In WAL this is durable and
    // every other connection can see it.
    try p.db.exec(alloc, "UPDATE t SET v = 'after' WHERE id = ?", &.{"1"});

    // A DIFFERENT request reads. It round-robins onto reader-1 — the connection the live iterator above still holds open — and is
    // therefore served from the pinned snapshot.
    var rows2 = try p.db.query(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer rows2.deinit();
    const row2 = (try rows2.next()) orelse return error.NoRow;
    defer row2.deinit(alloc);

    try testing.expectEqualStrings("after", row2.values[0]);
}

// rebinds the shared `sqlite3_stmt` a live `Rows` is mid-way through — its remaining rows and its parameters are destroyed. `read_conns = 0`
// forces that one shared primary connection (as `:memory:` and writer-state SQL do), which is exactly where the guard has to hold.
test "queryRow does not steal the statement a live Rows is stepping" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 0 });
    defer p.deinit();
    try p.db.exec(alloc, "INSERT INTO t (id, v) VALUES ('2', 'second')", &.{});

    // Two rows, so "the iterator was disturbed" is distinguishable from
    // "the iterator ran out of rows".
    const sql = "SELECT v FROM t ORDER BY id";

    var rows = try p.db.query(alloc, sql, &.{});
    defer rows.deinit();
    {
        const row = (try rows.next()) orelse return error.NoRow;
        defer row.deinit(alloc);
        try testing.expectEqualStrings("before", row.values[0]);
    }

    // A concurrent single-row read of the SAME SQL text on the same
    // connection.
    const other = try p.db.queryRow(alloc, sql, &.{});
    defer other.deinit(alloc);
    try testing.expectEqualStrings("before", other.values[0]);

    // The live iterator must still be on its own second row.
    const row = (try rows.next()) orelse return error.NoRow;
    defer row.deinit(alloc);
    try testing.expectEqualStrings("second", row.values[0]);
}

// Two iterators live at the same time, each with DIFFERENT bind values for the same SQL text, must each see its own row: the pool
// gives each read its own connection, so neither can reset the other's statement.
test "two live iterators of the same SQL do not interfere" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();
    try p.db.exec(alloc, "INSERT INTO t (id, v) VALUES ('2', 'second')", &.{});

    const sql = "SELECT v FROM t WHERE id = ?";

    var rows1 = try p.db.query(alloc, sql, &.{"1"});
    defer rows1.deinit();
    var rows2 = try p.db.query(alloc, sql, &.{"2"});
    defer rows2.deinit();

    const a = (try rows1.next()) orelse return error.NoRow;
    defer a.deinit(alloc);
    try testing.expectEqualStrings("before", a.values[0]);

    const b = (try rows2.next()) orelse return error.NoRow;
    defer b.deinit(alloc);
    try testing.expectEqualStrings("second", b.values[0]);

    // Each iterator is drained, and each still owns its own connection.
    try testing.expect((try rows1.next()) == null);
    try testing.expect((try rows2.next()) == null);
}

// The reader returned to the pool must start a FRESH read — the whole reason `Rows.deinit` resets before releasing — so sequential
// reads on the same reused reader each see the latest committed data.
test "a reused reader starts a fresh read, not the previous snapshot" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();

    const sql = "SELECT v FROM t WHERE id = ?";
    // One buffer for the expected value, rewritten each round: it must outlive the comparison, which a per-round allocation freed by a
    // `defer` would not.
    var want_buf: [16]u8 = @splat(0);
    var want: []const u8 = "before";
    var round: usize = 0;
    while (round < 25) : (round += 1) {
        {
            var rows = try p.db.query(alloc, sql, &.{"1"});
            defer rows.deinit();
            const row = (try rows.next()) orelse return error.NoRow;
            defer row.deinit(alloc);
            try testing.expectEqualStrings(want, row.values[0]);
        }

        want = try std.fmt.bufPrint(&want_buf, "v{d}", .{round});
        try p.db.exec(alloc, "UPDATE t SET v = ? WHERE id = ?", &.{ want, "1" });

        // Read AFTER the write, on whatever reader the pool hands back: a reader reused while its predecessor's transaction was still open
        // would report the PREVIOUS value.
        var rows2 = try p.db.query(alloc, sql, &.{"1"});
        defer rows2.deinit();
        const row2 = (try rows2.next()) orelse return error.NoRow;
        defer row2.deinit(alloc);
        try testing.expectEqualStrings(want, row2.values[0]);
    }
}

// The pool must actually be opened, otherwise every staleness test above
// passes vacuously by running single-connection.
test "pooling is really on: reads land on connections other than the writer" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 3 });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 3), p.db.pool.count());

    // `last_insert_rowid()` is connection state, so it must be answered by the connection that inserted; a read mis-routed onto a reader
    // would lose the writer's rowid. It is the implicit ROWID, not the TEXT `id` — '1' then '9' were inserted, so this is 2.
    try p.db.exec(alloc, "INSERT INTO t (id, v) VALUES ('9', 'nine')", &.{});
    var id_row = try p.db.queryRow(alloc, "SELECT last_insert_rowid()", &.{});
    defer id_row.deinit(alloc);
    try testing.expectEqualStrings("2", id_row.values[0]);
}

// THE SHRINK. `claim` opens readers under burst load and `release` only requeues them, so without this a burst of 75 concurrent reads
// leaves 75 readers (150 fds) open for the life of the process. Idle readers past `max_idle_time_ms` must close to the `read_conns` floor.
test "pool shrinks to floor after idle timeout" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1, .max_idle_time_ms = 50 });
    defer p.deinit();

    // Burst: 4 concurrent claims force the pool from 1 warm reader to 4.
    var held: [4]*SqliteBackend = undefined;
    for (0..4) |i| held[i] = try p.db.pool.claim(testing.io);
    try testing.expectEqual(@as(usize, 4), p.db.pool.count());
    for (held) |slot| p.db.pool.release(testing.io, slot);

    // Freshly released: nothing is old enough to reap yet.
    p.db.pool.reapIdle(testing.io);
    try testing.expectEqual(@as(usize, 4), p.db.pool.count());

    // Past the timeout, one daemon tick reaps everything above the floor. This also exercises the swapRemove index fixup: reaping a
    // non-last slot moves the last slot into the gap and rewrites idle entries.
    std.Io.sleep(testing.io, .{ .nanoseconds = 150 * std.time.ns_per_ms }, .awake) catch {};
    p.db.pool.reapIdle(testing.io);
    try testing.expectEqual(@as(usize, 1), p.db.pool.count());

    // The floor reader still serves reads.
    const row = try p.db.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("before", row.values[0]);
}

// THE INTERVAL. `reapIdleThrottled` is the daemon tick a long-lived server calls on a cadence of its own, and the pool decides
// whether the work is due. The burst's own `release` calls already run an inline pass, so a tick right after a burst must be throttled.
test "reapIdleThrottled skips the pass when one ran inside reap_interval_ms" {
    var p = try Pool.init(.{ .read_conns = 1, .max_idle_time_ms = 20, .reap_interval_ms = 10_000 });
    defer p.deinit();

    // Burst to 4 and release. The releases run an inline pass, which both
    // reaps (nothing is old enough yet) and schedules the next one 10 s out.
    var held: [4]*SqliteBackend = undefined;
    for (0..4) |i| held[i] = try p.db.pool.claim(testing.io);
    for (held) |slot| p.db.pool.release(testing.io, slot);
    try testing.expectEqual(@as(usize, 4), p.db.pool.count());

    // Outlive the idle age: the readers are now old enough to reap, but the last pass was moments ago and the interval is 10 s, so the
    // tick must be a no-op. Without the throttle the pool would shrink on every tick.
    std.Io.sleep(testing.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};
    p.db.pool.reapIdleThrottled(testing.io);
    try testing.expectEqual(@as(usize, 4), p.db.pool.count());

    // reapIdle always runs, so the pool still converges on demand.
    p.db.pool.reapIdle(testing.io);
    try testing.expectEqual(@as(usize, 1), p.db.pool.count());
}

// 0 means "derive it from max_idle_time_ms", which is what every consumer got before the knob existed: the derived interval is
// max(20/4, 1000) = 1 s, so a consumer that never sets it sees no behaviour change.
test "reap_interval_ms 0 derives the interval from max_idle_time_ms" {
    var p = try Pool.init(.{ .read_conns = 1, .max_idle_time_ms = 20, .reap_interval_ms = 0 });
    defer p.deinit();

    var held: [4]*SqliteBackend = undefined;
    for (0..4) |i| held[i] = try p.db.pool.claim(testing.io);
    for (held) |slot| p.db.pool.release(testing.io, slot);

    // The derived interval is 1 s and only microseconds have passed, so the
    // tick is throttled — the inline pass on release already did the work.
    p.db.pool.reapIdleThrottled(testing.io);
    try testing.expectEqual(@as(usize, 4), p.db.pool.count());

    // Past the idle age, reapIdle ignores the throttle and reaps.
    std.Io.sleep(testing.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};
    p.db.pool.reapIdle(testing.io);
    try testing.expectEqual(@as(usize, 1), p.db.pool.count());
}

// The floor is the invariant that survives every other change: a pool may shrink, but never below `read_conns`, or the next burst
// pays to reopen connections the boot already paid for.
test "a throttled reap still stops at the warm floor" {
    var p = try Pool.init(.{ .read_conns = 2, .max_idle_time_ms = 20, .reap_interval_ms = 0 });
    defer p.deinit();

    var held: [6]*SqliteBackend = undefined;
    for (0..6) |i| held[i] = try p.db.pool.claim(testing.io);
    for (held) |slot| p.db.pool.release(testing.io, slot);
    std.Io.sleep(testing.io, .{ .nanoseconds = 60 * std.time.ns_per_ms }, .awake) catch {};

    p.db.pool.reapIdle(testing.io);
    try testing.expectEqual(@as(usize, 2), p.db.pool.count());

    // The floor readers still serve reads.
    const row = try p.db.queryRow(testing.allocator, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(testing.allocator);
    try testing.expectEqualStrings("before", row.values[0]);
}

// A CLAIMED reader is never reaped, however idle the rest of the pool is: reaping only scans the idle list, so the live connection
// must survive and stay usable, and the pool must still converge to the floor afterwards.
test "claimed slots never reaped" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1, .max_idle_time_ms = 0 });
    defer p.deinit();

    const a = try p.db.pool.claim(testing.io);
    const b = try p.db.pool.claim(testing.io);
    const c = try p.db.pool.claim(testing.io);
    try testing.expectEqual(@as(usize, 3), p.db.pool.count());

    // `max_idle_time_ms = 0` reaps on every release pass, but only idle
    // entries: the two released readers are closed while `a` is held.
    p.db.pool.release(testing.io, b);
    p.db.pool.release(testing.io, c);
    p.db.pool.reapIdle(testing.io);
    try testing.expectEqual(@as(usize, 1), p.db.pool.count());

    // The survivor is `a`: still open, still answering reads.
    var row = try a.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("before", row.values[0]);

    p.db.pool.release(testing.io, a);
    p.db.pool.reapIdle(testing.io);
    try testing.expectEqual(@as(usize, 1), p.db.pool.count());
}

// THE LEAK CANARY. A `Rows` owns its pooled reader until `deinit`, and draining it with `next()` does NOT return it; nothing else
// notices a forgotten one, because the row bytes belong to the caller's allocator while the connection belongs to the pool.
test "a deinited Rows returns its reader; a drained one does not" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.db.outstandingClaims());

    // Drained to completion and deinit'd: the reader comes back.
    {
        var rows = try p.db.query(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
        try testing.expectEqual(@as(usize, 1), p.db.outstandingClaims());
        while (try rows.next()) |row| row.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), p.db.outstandingClaims());
        rows.deinit();
        try testing.expectEqual(@as(usize, 0), p.db.outstandingClaims());
    }

    // queryRow completes inside the call, so it never leaves one outstanding.
    {
        var row = try p.db.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
        defer row.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), p.db.outstandingClaims());
    }

    // The bug this exists for, stated as a fact rather than as a claim: a
    // cursor that is drained and never deinit'd holds its reader.
    var leaked = try p.db.query(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    while (try leaked.next()) |row| row.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), p.db.outstandingClaims());
    leaked.deinit();
    try testing.expectEqual(@as(usize, 0), p.db.outstandingClaims());
}

// A reaping pass must never orphan a slot: a slot that leaves `slots` is a connection nothing can reach or ever close, and it still
// counts against the cap. Every reader ends up back in the idle list.
test "reaping leaves no slot unreachable" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 2, .max_idle_time_ms = 0 });
    defer p.deinit();
    const io = p.io();

    var held: [6]*SqliteBackend = undefined;
    for (0..6) |i| held[i] = try p.db.pool.claim(io);
    try testing.expectEqual(@as(usize, 6), p.db.outstandingClaims());
    for (held) |slot| p.db.pool.release(io, slot);
    try testing.expectEqual(@as(usize, 0), p.db.outstandingClaims());

    // `max_idle_time_ms = 0` reaps on every pass, down to the warm floor.
    for (0..4) |_| p.db.pool.reapIdle(io);

    // Every slot is either idle or claimed — there is no third state. A reaping pass that dropped an entry without closing its slot
    // would leave the counts short, and the difference would be leaked connections.
    try testing.expectEqual(
        p.db.pool.count(),
        p.db.pool.idleCount() + p.db.outstandingClaims(),
    );

    // And the survivors still work.
    var row = try p.db.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("before", row.values[0]);
    try testing.expectEqual(@as(usize, 0), p.db.outstandingClaims());
}

/// Allocator that records whether it was asked for anything, and can be told to fail: the only way to observe WHERE a backend
/// allocates, since reading a knob like `Config.allocator` back proves nothing — a field can be honoured by nothing.
const Spy = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    frees: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(buf, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.allocs += 1;
        return self.child.rawRemap(buf, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.child.rawFree(buf, alignment, ra);
    }
};

// `Config.allocator` exists because the pool's memory was invisible to the caller. This asserts the invisibility is gone: the pool's
// connections, its index lists and each connection's statement cache are allocated through the supplied allocator, not `smp_allocator`.
test "the pool allocates through the configured allocator" {
    const alloc = testing.allocator;
    var spy: Spy = .{ .child = alloc };

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
    const joined = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "spy.db" });
    defer alloc.free(joined);
    const path = try alloc.dupeZ(u8, joined);
    defer alloc.free(path);

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var db: SqliteBackend = .{};
    defer db.deinit();
    try db.initWithConfig(io, path, .{ .read_conns = 2, .allocator = spy.allocator() });

    // The warm floor alone is enough to prove the plumbing: opening two readers allocates two connections plus the pool's two index
    // lists, and none of that may come from the global.
    try testing.expectEqual(@as(usize, 2), db.pool.count());
    try testing.expect(spy.allocs >= 4);
    try testing.expectEqual(@as(usize, 0), spy.frees);

    // A read caches its statement — the OTHER allocation a pooled connection makes, and the one a partial fix is likeliest to miss —
    // asserted on the ALLOCATOR rather than `stmt_cache.count()`, since that cache belongs to the pooled reader, not to the primary.
    const before_read = spy.allocs;
    var row = try db.queryRow(alloc, "SELECT 1", &.{});
    defer row.deinit(alloc);
    try testing.expect(spy.allocs > before_read);

    // Closing returns everything it took.
    db.deinit();
    try testing.expectEqual(spy.allocs, spy.frees);
}

// The default must stay the global, so existing call sites keep their behaviour: `null` is not an error and not a silent switch to
// the caller's per-query allocator, which is row-lifetime while the pool is not.
test "no configured allocator still works, on the global" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();

    const row = try p.db.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("before", row.values[0]);
    try testing.expectEqual(@as(usize, 0), p.db.outstandingClaims());
}

// The RULE behind `fdDerivedReaderCap`, asserted for budgets THIS process does not have — a pure function of the budget, because no CI
// runner can hand the test a 256 soft limit. macOS ships 256, which IS `FD_HEADROOM`: un-scaled, the cap floored at 1 and no second reader opened.
test "reader cap: macOS's 256-descriptor budget still funds a reader pool" {
    // The regression, tied to the number macOS actually ships.
    try testing.expectEqual(@as(usize, 64), sqlite.readerCapForSoftLimit(256));
    // Not a special case for 256: no cliff anywhere below the full reserve.
    var prev: usize = 1;
    var soft: usize = 1;
    while (soft <= 2 * sqlite.FD_HEADROOM) : (soft += 1) {
        const cap = sqlite.readerCapForSoftLimit(soft);
        try testing.expect(cap >= 1); // never zero, never an underflow
        try testing.expect(cap >= prev); // monotone: a bigger budget never funds fewer
        prev = cap;
    }
    // Any budget that can fund two readers must be allowed two.
    try testing.expect(sqlite.readerCapForSoftLimit(8) >= 2);
}

test "reader cap: the scaled reserve never spends what the process does not have" {
    // Below the full reserve the pool may spend at most HALF the budget — the other half is what is left for sockets, SSE clients and
    // subprocess pipes, which is the whole reason `FD_HEADROOM` exists.
    var soft: usize = 4;
    while (soft <= sqlite.FD_HEADROOM) : (soft += 1) {
        const cap = sqlite.readerCapForSoftLimit(soft);
        try testing.expect(cap * sqlite.FDS_PER_READER <= soft - soft / 2);
    }
    // Above it, the reserve is affordable in full and the rule is UNCHANGED,
    // so no process that was never constrained sees a different ceiling.
    try testing.expectEqual(@as(usize, 128), sqlite.readerCapForSoftLimit(2 * sqlite.FD_HEADROOM));
    try testing.expectEqual(@as(usize, 384), sqlite.readerCapForSoftLimit(1024));
    try testing.expectEqual(@as(usize, 262_016), sqlite.readerCapForSoftLimit(524_288));
}
