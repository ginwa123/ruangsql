//! Behavioural tests for the WAL writer-slot contract: one writer per file, so a contended write waits out `busy_timeout`
//! and is then LOST, a DEFERRED read-then-write fails instantly (SQLITE_BUSY_SNAPSHOT, no retry); `:memory:` never contends.

const std = @import("std");
const sqlite = @import("Sqlite.zig");

const SqliteBackend = sqlite.SqliteBackend;
const Config = sqlite.Config;
const testing = std.testing;

/// How long the competing writer holds WAL's single writer slot: comfortably longer than the few-hundred-ms
/// `busy_timeout` under test, so "waited it out" and "gave up" stay unambiguous outcomes.
const HOLD_MS: u64 = 400;

fn sleepMs(io: std.Io, ms: u64) void {
    std.Io.sleep(io, .{ .nanoseconds = @intCast(ms * std.time.ns_per_ms) }, .awake) catch {};
}

/// Two `SqliteBackend` handles on ONE file-backed database, plus the
/// `std.Io.Threaded` runtime both need.
const TwoConns = struct {
    threaded: std.Io.Threaded,
    a: SqliteBackend,
    b: SqliteBackend,
    tmp: testing.TmpDir,
    path: [:0]u8,

    /// `cfg_b` is what connection `b` is opened with. `a` is opened with
    /// `b_cfg_for_a` too when a test needs both sides on the same policy.
    fn init(cfg_b: Config) !TwoConns {
        const alloc = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try tmp.dir.realPath(testing.io, &dir_buf);
        const joined = try std.fs.path.join(alloc, &.{ dir_buf[0..dir_len], "wal_writer.db" });
        defer alloc.free(joined);
        const path = try alloc.dupeZ(u8, joined);
        errdefer alloc.free(path);

        var threaded = std.Io.Threaded.init(alloc, .{});
        errdefer threaded.deinit();

        var a: SqliteBackend = .{};
        errdefer a.deinit();
        try a.initWithConfig(threaded.io(), path, .{ .synchronous = .full });

        var b: SqliteBackend = .{};
        errdefer b.deinit();
        try b.initWithConfig(threaded.io(), path, cfg_b);

        try a.exec(alloc, "CREATE TABLE t (v INTEGER)", &.{});

        const self: TwoConns = .{
            .threaded = threaded,
            .a = a,
            .b = b,
            .tmp = tmp,
            .path = path,
        };
        return self;
    }

    fn deinit(self: *TwoConns) void {
        self.b.deinit();
        self.a.deinit();
        self.threaded.deinit();
        self.tmp.cleanup();
        testing.allocator.free(self.path);
    }
};

/// Opens a transaction, writes, holds WAL's slot for `HOLD_MS`, then commits. `locked` flips only once the write is
/// inside the tx (no start-up race); `done` flips after COMMIT — await it, never `join()` twice (that is `unreachable`).
const HoldWriter = struct {
    db: *SqliteBackend,
    allocator: std.mem.Allocator,
    io: std.Io,
    locked: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),

    fn run(self: *HoldWriter) void {
        defer self.done.store(true, .release);
        self.hold() catch {};
    }

    fn hold(self: *HoldWriter) !void {
        var tx = try self.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(self.allocator, "INSERT INTO t VALUES (1)", &.{});
        self.locked.store(true, .release);
        sleepMs(self.io, HOLD_MS);
        try tx.commit();
    }
};

/// Spin until `flag` flips: 20 s of wall clock, an order of magnitude past anything the holder needs. Timing out means
/// the holder thread died, and since the holder swallows its own error this is the only way the main thread learns it.
fn waitForFlag(flag: *const std.atomic.Value(bool)) !void {
    var spins: usize = 0;
    while (!flag.load(.acquire)) : (spins += 1) {
        if (spins > 20_000) return error.HolderNeverSignalled;
        sleepMs(testing.io, 1);
    }
}

fn scalar(db: *SqliteBackend, sql: []const u8) ![]u8 {
    const alloc = testing.allocator;
    var row = try db.queryRow(alloc, sql, &.{});
    defer row.deinit(alloc);
    return try alloc.dupe(u8, row.values[0]);
}

// =====================================================================
// Connection config

test "initWithConfig: every pragma reads back at the value that was requested" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{
        .busy_timeout_ms = 4321,
        .synchronous = .normal,
        .wal_autocheckpoint_pages = 777,
        .journal_size_limit_bytes = 1_234_567,
    });
    defer conns.deinit();

    const got = try conns.b.readConfig(alloc);

    try testing.expectEqualStrings("wal", got.journalMode());
    try testing.expectEqual(@as(u32, 4321), got.busy_timeout_ms);
    try testing.expectEqual(@as(i64, 1), got.synchronous); // NORMAL
    try testing.expectEqual(@as(u32, 777), got.wal_autocheckpoint_pages);
    try testing.expectEqual(@as(i64, 1_234_567), got.journal_size_limit_bytes);
}

test "Config defaults: WAL, a 15s writer wait, a bounded WAL file, synchronous FULL" {
    // 15 s of `busy_timeout_ms` because 5 s is not enough when a second process shares the file; the wait costs
    // nothing when nobody else is writing.
    const defaults: Config = .{};
    try testing.expectEqual(@as(u32, 15_000), defaults.busy_timeout_ms);
    // `synchronous` stays at SQLite's own default so this package never silently changes a consumer's durability;
    // an app that wants WAL's documented `.normal` opts in explicitly.
    try testing.expectEqual(sqlite.Synchronous.full, defaults.synchronous);
    try testing.expectEqual(@as(i64, 64 * 1024 * 1024), defaults.journal_size_limit_bytes);
    try testing.expectEqual(@as(u32, 1_000), defaults.wal_autocheckpoint_pages);

    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{});
    defer conns.deinit();

    const got = try conns.b.readConfig(alloc);
    try testing.expectEqualStrings("wal", got.journalMode());
    try testing.expectEqual(@as(u32, 15_000), got.busy_timeout_ms);
    try testing.expectEqual(@as(i64, 2), got.synchronous); // FULL
    try testing.expectEqual(@as(i64, 64 * 1024 * 1024), got.journal_size_limit_bytes);
}

// Positive control for the two tests above: `readConfig` reports a PER-CONNECTION value, so a config applied to `b`
// must not change what `a` reads back — that is the assertion catching a process-wide setting.
test "readConfig: each connection reports its own settings" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 7_777, .synchronous = .normal });
    defer conns.deinit();

    const b_cfg = try conns.b.readConfig(alloc);
    try testing.expectEqual(@as(u32, 7_777), b_cfg.busy_timeout_ms);
    try testing.expectEqual(@as(i64, 1), b_cfg.synchronous);

    const a_cfg = try conns.a.readConfig(alloc);
    try testing.expectEqual(@as(u32, 15_000), a_cfg.busy_timeout_ms);
    try testing.expectEqual(@as(i64, 2), a_cfg.synchronous);
}

// =====================================================================
// Writer-slot contention

// The core of the fix: a contended write WAITS instead of being lost.
test "a write waits out a competing writer instead of failing" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 5_000 });
    defer conns.deinit();

    var locked = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var hold = HoldWriter{
        .db = &conns.a,
        .allocator = alloc,
        .io = conns.threaded.io(),
        .locked = &locked,
        .done = &done,
    };
    const thread = try std.Thread.spawn(.{}, HoldWriter.run, .{&hold});
    defer thread.join();

    try waitForFlag(&locked);

    // No retry here: the assertion is that SQLite's own busy handler,
    // armed by the config, covers the holder's HOLD_MS hold.
    try conns.b.exec(alloc, "INSERT INTO t VALUES (2)", &.{});

    try waitForFlag(&done);

    const count = try scalar(&conns.b, "SELECT COUNT(*) FROM t");
    defer alloc.free(count);
    try testing.expectEqualStrings("2", count);
}

// The negative control for the test above: without it, "waits it out" could pass for unrelated reasons (slow disk,
// scheduler pause, holder finishing early). Same race, 1 ms timeout, and the write is LOST — the bug report's failure.
test "without a long enough busy_timeout the same race loses the write" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 1 });
    defer conns.deinit();

    var locked = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var hold = HoldWriter{
        .db = &conns.a,
        .allocator = alloc,
        .io = conns.threaded.io(),
        .locked = &locked,
        .done = &done,
    };
    const thread = try std.Thread.spawn(.{}, HoldWriter.run, .{&hold});
    defer thread.join();

    try waitForFlag(&locked);

    try testing.expectError(
        error.ExecuteFailed,
        conns.b.exec(alloc, "INSERT INTO t VALUES (2)", &.{}),
    );
}

// `begin()` emits BEGIN IMMEDIATE, so a read-then-write transaction takes the writer slot up front — where
// `busy_timeout` applies — instead of finding at write time that its snapshot is stale. The DEFERRED failure runs first.
test "begin: read-then-write survives another connection committing mid-transaction" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 5_000 });
    defer conns.deinit();

    // --- the failure a DEFERRED transaction produces -------------------
    // `b` takes a read snapshot, `a` commits, then `b` writes.
    {
        var tx = try conns.b.beginDeferred();
        {
            var probe = try tx.queryRow(alloc, "SELECT COUNT(*) FROM t", &.{});
            probe.deinit(alloc);
        }
        try conns.a.exec(alloc, "INSERT INTO t VALUES (10)", &.{});
        const res = tx.exec(alloc, "INSERT INTO t VALUES (11)", &.{});
        tx.rollback() catch {};
        try testing.expectError(error.ExecuteFailed, res);
    }

    // --- the same sequence under `begin()` ----------------------------
    // The write lock is taken at `begin()`, so `a` waits rather than committing into the middle of `b`'s tx; `b` lands.
    var tx = try conns.b.begin();
    {
        var probe = try tx.queryRow(alloc, "SELECT COUNT(*) FROM t", &.{});
        probe.deinit(alloc);
    }
    try tx.exec(alloc, "INSERT INTO t VALUES (12)", &.{});
    try tx.commit();

    const twelve = try scalar(&conns.b, "SELECT COUNT(*) FROM t WHERE v = 12");
    defer alloc.free(twelve);
    try testing.expectEqualStrings("1", twelve);
}
