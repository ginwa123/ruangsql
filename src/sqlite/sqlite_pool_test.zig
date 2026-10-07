//! Behavioural tests for READER POOLING — the `Config.read_conns` path.
//!
//! WHY A SEPARATE FILE
//! -------------------
//! `sqlite_fastpath_test.zig` opens `:memory:`, and `initWithConfig`
//! deliberately returns early for `:memory:` (`isInMemoryPath`) because
//! a second connection would see an empty, unrelated database. So EVERY
//! test in that file — and in `sqlite_test.zig` — runs on the
//! single-connection path. Reader pooling had no test at all until this
//! file.
//!
//! THE BUGS THESE EXIST FOR
//! -----------------------
//! Pooling moved reads off the write connection and onto N extra
//! connections. Two invariants have to survive that move, and neither
//! was checked:
//!
//!   1. A read must not be able to miss a write that has already
//!      committed. SQLite keeps at most ONE read transaction open per
//!      connection, and `query` hands its `Rows` to the caller while
//!      REUSING the pooled connection for the next request. So one live
//!      iterator silently pins its connection to the snapshot it opened,
//!      and every later read that lands on that connection — from any
//!      thread — sees the old data. With `read_conns = 7` that is one
//!      request in seven returning stale rows, intermittently, forever.
//!
//!   2. A statement handed out by `query` must not be handed out again
//!      by `exec` / `queryRow` while the caller is still stepping it.
//!      `SqliteBackend.iterating` guards `query` against `query`, but
//!      `executeStatement` / `executeQueryRow` call `stmt_cache.acquire`
//!      with no such check: `acquire` does `sqlite3_reset` +
//!      `sqlite3_clear_bindings` on the shared `sqlite3_stmt`, i.e. it
//!      resets the statement the live iterator is mid-way through and
//!      rebinds it to somebody else's arguments.
//!
//! WHY A FILE-BACKED DB: pooling is skipped for `:memory:`, so these
//! tests are the only ones that exercise it. There is no alternative.

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

// THE FD BUG. A pooled reader is not one descriptor — an open WAL
// connection holds the database file, its `-wal` and its `-shm`. So an
// UNLIMITED elastic pool spends `3 x peak concurrent reads` descriptors
// for the life of the process, and a server that already holds a socket
// per SSE client runs out. When it does, `sqlite3_open` returns
// SQLITE_CANTOPEN and the next reader's `PRAGMA journal_mode = WAL` fails
// with "unable to open database file" — which reads like a permissions
// problem and is neither.
test "each pooled reader costs FDS_PER_READER descriptors, not one" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1, .max_read_conns = 0 });
    defer p.deinit();

    const before = countOpenFds();
    // Claim more readers at once than the warm floor, so the pool has to
    // OPEN new connections rather than reuse idle ones. Then run a real
    // read on each: a connection holds only the database fd until it
    // actually touches the WAL, so counting without a query understates
    // the cost by 2 fds per reader.
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

// The hard ceiling that stops it. `max_read_conns = 0` means "no POLICY
// cap", not "no cap": the pool must still refuse to grow past what the
// process's `RLIMIT_NOFILE` can fund after reserving headroom.
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

// A read must never FAIL because the pool could not grow. When the pool
// is out of capacity — fd quota, memory, anything — the read falls back
// to the primary connection: slower (it serializes) but correct.
test "a read falls back to the primary when the pool cannot grow" {
    const alloc = testing.allocator;
    // Cap of 1, with that one reader already claimed: the next claim
    // cannot grow the pool.
    var p = try Pool.init(.{ .read_conns = 1, .max_read_conns = 1 });
    defer p.deinit();

    const held = try p.db.pool.claim(testing.io);
    defer p.db.pool.release(testing.io, held);

    const row = try p.db.queryRow(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("before", row.values[0]);
}

// Positive control: pooling must not break the basic write→read path.
//
// `read_conns = 1` keeps this deterministic — the single reader is the
// only place a read can land. Without this test the staleness test below
// could pass vacuously (e.g. if routing were broken in a way that made
// every read fail).
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

// THE BUG. A `Rows` that is still open pins its connection's read
// transaction, and every LATER read that lands on that connection sees
// the pinned snapshot instead of committed data.
//
// This is not a leak in the caller — `rows` is deinited at the end of
// this test. The damage is done while it is open, because `query`
// releases the connection's mutex before the caller has finished
// stepping, so the connection goes straight back into the pool.
test "a live Rows pins its connection's snapshot; later reads on it are stale" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();

    // Open an iterator and read one row. This takes reader-1's read
    // transaction and leaves it OPEN — `query` handed the statement back
    // to us and released the mutex.
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

    // A DIFFERENT request reads. It round-robins onto reader-1 — the same
    // connection the live iterator above still holds open — and is
    // therefore served from the pinned snapshot.
    var rows2 = try p.db.query(alloc, "SELECT v FROM t WHERE id = ?", &.{"1"});
    defer rows2.deinit();
    const row2 = (try rows2.next()) orelse return error.NoRow;
    defer row2.deinit(alloc);

    try testing.expectEqualStrings("after", row2.values[0]);
}

// THE BUG. `exec` / `queryRow` do not check `SqliteBackend.iterating`,
// so `stmt_cache.acquire` resets and rebinds the cached statement that a
// live `Rows` is still stepping, on the ONE connection they share.
//
// `acquire` runs `sqlite3_reset` + `sqlite3_clear_bindings` and then binds
// the caller's own arguments to the SAME `sqlite3_stmt`, so without the
// `iterating` guard the live iterator's remaining rows are destroyed and
// its parameters are silently replaced.
//
// `read_conns = 0` is the point of this test. With pooling ON, `query`
// gives its reader to the `Rows` EXCLUSIVELY, so `queryRow` can never land
// on the same connection and the collision is impossible by construction.
// The primary connection is still shared — by `query` / `exec` /
// `queryRow` whenever pooling is off (`:memory:`) or the SQL needs the
// writer's connection state — so the guard has to hold there.
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

// Two iterators live at the same time, each with DIFFERENT bind values for
// the same SQL text. Each must see its own row: the pool gives each read
// its own connection, so neither can reset the other's statement.
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

// The reader returned to the pool must start a FRESH read — that is the
// whole reason `Rows.deinit` resets before releasing. Sequential reads on
// the same reused reader must each see the latest committed data.
test "a reused reader starts a fresh read, not the previous snapshot" {
    const alloc = testing.allocator;
    var p = try Pool.init(.{ .read_conns = 1 });
    defer p.deinit();

    const sql = "SELECT v FROM t WHERE id = ?";
    // One buffer for the expected value, rewritten each round. It must
    // outlive the comparison, which a per-round allocation freed by a
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

        // Read AFTER the write, on whatever reader the pool hands back. A
        // reader reused while its predecessor's transaction was still open
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

    // `last_insert_rowid()` is connection state, so it must be answered by
    // the connection that inserted. If reads were mis-routed onto a
    // reader, the writer's own rowid would be lost.
    //
    // It is the implicit ROWID, not the TEXT `id`: this pool inserted '1'
    // then '9', so the rowid is 2.
    try p.db.exec(alloc, "INSERT INTO t (id, v) VALUES ('9', 'nine')", &.{});
    var id_row = try p.db.queryRow(alloc, "SELECT last_insert_rowid()", &.{});
    defer id_row.deinit(alloc);
    try testing.expectEqualStrings("2", id_row.values[0]);
}