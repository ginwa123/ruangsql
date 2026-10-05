//! Behavioural tests for the WAL writer-slot contract.
//!
//! THE BUG THESE EXIST FOR
//! -----------------------
//! `init` used to set only `journal_mode=WAL` + `busy_timeout=5000`, and
//! `begin()` used to emit a plain (DEFERRED) `BEGIN`. WAL gives a database
//! file exactly ONE writer slot, so:
//!
//!   * an autocommit write that cannot take the slot blocks for
//!     `busy_timeout` and then FAILS — the write is lost, not delayed;
//!   * a DEFERRED transaction that reads, has another connection commit,
//!     and then writes fails INSTANTLY with SQLITE_BUSY_SNAPSHOT, which
//!     the busy handler is deliberately not consulted for (the reads
//!     cannot be replayed, so there is no safe retry).
//!
//! Both surface as `Error.ExecuteFailed` / "database is locked", which is
//! what a consuming app logged as:
//!
//! ```text
//! warning: sqlite3 step failed: database is locked (sql: INSERT INTO logs …)
//! ```
//!
//! WHY A FILE-BACKED DB: `:memory:` gives every connection a private
//! database, so two `SqliteBackend` handles on `:memory:` never contend
//! and the whole point of these tests is the contention.

const std = @import("std");
const sqlite = @import("Sqlite.zig");

const SqliteBackend = sqlite.SqliteBackend;
const Config = sqlite.Config;
const testing = std.testing;

/// How long the competing writer holds WAL's writer slot. Comfortably
/// longer than a `busy_timeout` of a few hundred ms so "waited it out"
/// and "gave up" are unambiguous outcomes.
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

/// One connection opens a transaction, writes, holds WAL's single writer
/// slot for `HOLD_MS`, then commits. `locked` flips the instant the write
/// is inside the transaction, so the main thread never races thread
/// start-up — a plain sleep there would make the whole test vacuous.
const HoldWriter = struct {
    db: *SqliteBackend,
    allocator: std.mem.Allocator,
    io: std.Io,
    locked: *std.atomic.Value(bool),

    fn run(self: *HoldWriter) !void {
        var tx = try self.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(self.allocator, "INSERT INTO t VALUES (1)", &.{});
        self.locked.store(true, .release);
        sleepMs(self.io, HOLD_MS);
        try tx.commit();
    }
};

fn waitForFlag(locked: *const std.atomic.Value(bool)) !void {
    var spins: usize = 0;
    while (!locked.load(.acquire)) : (spins += 1) {
        if (spins > 5_000) return error.HolderNeverTookTheWriteLock;
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
// =====================================================================

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
    // `busy_timeout_ms` was 5_000 and is now 15_000: 5 seconds is not
    // enough on a machine where a second process shares the file, and the
    // wait costs nothing when nobody else is writing.
    const defaults: Config = .{};
    try testing.expectEqual(@as(u32, 15_000), defaults.busy_timeout_ms);
    // `synchronous` stays at SQLite's own default so this package does not
    // silently change any consumer's durability. An app that prefers WAL's
    // documented `.normal` opts in explicitly.
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

// Positive control for the two tests above: `readConfig` observes a
// PER-CONNECTION value, not something global. If it were reading a
// process-wide setting, applying a config to `b` would have changed what
// `a` reports too — and this is the assertion that would catch it.
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
// =====================================================================

// The core of the fix: a contended write WAITS instead of being lost.
test "a write waits out a competing writer instead of failing" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 5_000 });
    defer conns.deinit();

    var locked = std.atomic.Value(bool).init(false);
    var hold = HoldWriter{
        .db = &conns.a,
        .allocator = alloc,
        .io = conns.threaded.io(),
        .locked = &locked,
    };
    const thread = try std.Thread.spawn(.{}, HoldWriter.run, .{&hold});
    defer thread.join();

    try waitForFlag(&locked);

    // No retry here: the assertion is that SQLite's own busy handler,
    // armed by the config, covers the holder's HOLD_MS hold.
    try conns.b.exec(alloc, "INSERT INTO t VALUES (2)", &.{});

    thread.join();

    const count = try scalar(&conns.b, "SELECT COUNT(*) FROM t");
    defer alloc.free(count);
    try testing.expectEqualStrings("2", count);
}

// The negative control for the test above. WITHOUT this, "waits it out"
// could pass for reasons that have nothing to do with `busy_timeout` — a
// slow disk, a scheduler pause, the holder finishing early. Here the same
// race is run against a connection whose timeout is too short, and the
// write is LOST — the exact failure the bug report is made of.
test "without a long enough busy_timeout the same race loses the write" {
    const alloc = testing.allocator;
    var conns = try TwoConns.init(.{ .busy_timeout_ms = 1 });
    defer conns.deinit();

    var locked = std.atomic.Value(bool).init(false);
    var hold = HoldWriter{
        .db = &conns.a,
        .allocator = alloc,
        .io = conns.threaded.io(),
        .locked = &locked,
    };
    const thread = try std.Thread.spawn(.{}, HoldWriter.run, .{&hold});
    defer thread.join();

    try waitForFlag(&locked);

    try testing.expectError(
        error.ExecuteFailed,
        conns.b.exec(alloc, "INSERT INTO t VALUES (2)", &.{}),
    );
}

// `begin()` emits BEGIN IMMEDIATE, so a read-then-write transaction
// takes the writer slot up front — where `busy_timeout` applies —
// instead of discovering at write time that its snapshot is stale.
//
// The DEFERRED failure is reproduced here first, so the contrast is on
// the record rather than asserted from a comment.
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
    // The write lock is taken at `begin()`, so `a` waits rather than
    // committing into the middle of `b`'s transaction, and `b` lands.
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
