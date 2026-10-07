//! Tests for the prepared-statement cache that now backs `exec`,
//! `queryRow` and `Transaction.exec`.
//!
//! The whole point of the cache is that it is INVISIBLE: `exec` and
//! `queryRow` keep their signatures, their semantics, and their ownership
//! rules. So these tests assert exactly that — the observable behaviour of
//! the public API is unchanged, including the cases that used to be
//! per-call `prepare`/`finalize` (error paths, empty SQL, NULL binding,
//! repeated statements) — plus the leak-freedom the cache introduces
//! (statement keys are owned; `deinit` must release them).
//!
//! Every backend here is created on the leak-checking test allocator, so a
//! cached statement or its SQL-text key that is never freed fails a test
//! rather than leaking quietly.

const std = @import("std");
const testing = std.testing;

const sqlite_mod = @import("Sqlite.zig");
const SqliteBackend = sqlite_mod.SqliteBackend;
const Error = sqlite_mod.Error;

const DbCtx = struct {
    db: SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupSeeded() !DbCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();

    var db: SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(threaded.io(), ":memory:");

    try db.exec(alloc, "CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, email TEXT NOT NULL)", &.{});
    var i: i64 = 1;
    while (i <= 5) : (i += 1) {
        const u = try std.fmt.allocPrint(alloc, "user_{d}", .{i});
        defer alloc.free(u);
        const e = try std.fmt.allocPrint(alloc, "user_{d}@bench.local", .{i});
        defer alloc.free(e);
        try db.exec(alloc, "INSERT INTO users (username, email) VALUES (?, ?)", &.{ u, e });
    }
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *DbCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

// ─── The cache is invisible: same results, many times over ────────────────

test "repeated exec of the same SQL inserts every row (cache reuse, no lost writes)" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    var n: i64 = 0;
    while (n < 200) : (n += 1) {
        const u = try std.fmt.allocPrint(alloc, "bulk_{d}", .{n});
        defer alloc.free(u);
        try ctx.db.exec(alloc, "INSERT INTO users (username, email) VALUES (?, ?)", &.{ u, "x@y.z" });
    }

    const row = try ctx.db.queryRow(alloc, "SELECT COUNT(*) FROM users", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("205", row.values[0]);
}

test "repeated queryRow of the same SQL returns that row's values each time" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    var id: i64 = 1;
    while (id <= 5) : (id += 1) {
        const id_str = try std.fmt.allocPrint(alloc, "{d}", .{id});
        defer alloc.free(id_str);

        const row = try ctx.db.queryRow(alloc, "SELECT id, username, email FROM users WHERE id = ?", &.{id_str});
        defer row.deinit(alloc);

        try testing.expectEqual(@as(usize, 3), row.values.len);
        const want = try std.fmt.allocPrint(alloc, "user_{d}", .{id});
        defer alloc.free(want);
        try testing.expectEqualStrings(id_str, row.values[0]);
        try testing.expectEqualStrings(want, row.values[1]);
    }
}

test "query (Rows iterator) still gives every row, including with the cache in play" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // Iterate the same SELECT twice in a row: `query` prepares its own
    // statement each time, so a second live iterator must not disturb the
    // first (which is why iterators are not cached).
    var first = try ctx.db.query(alloc, "SELECT username FROM users ORDER BY id", &.{});
    defer first.deinit();
    const r1 = (try first.next()) orelse return error.ExpectedRow;
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("user_1", r1.values[0]);

    var second = try ctx.db.query(alloc, "SELECT username FROM users ORDER BY id", &.{});
    defer second.deinit();
    const r2 = (try second.next()) orelse return error.ExpectedRow;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("user_1", r2.values[0]);

    // The first iterator is still fully usable after the second opened.
    const r1b = (try first.next()) orelse return error.ExpectedRow;
    defer r1b.deinit(alloc);
    try testing.expectEqualStrings("user_2", r1b.values[0]);
}

// ─── Error and edge-case behaviour is unchanged ───────────────────────────

test "exec on malformed SQL still returns PrepareFailed, and stays usable" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try testing.expectError(Error.PrepareFailed, ctx.db.exec(alloc, "NOT VALID SQL AT ALL garbage", &.{}));

    // The failure must not poison the connection.
    const row = try ctx.db.queryRow(alloc, "SELECT COUNT(*) FROM users", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("5", row.values[0]);
}

test "queryRow on malformed SQL still returns PrepareFailed" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    try testing.expectError(Error.PrepareFailed, ctx.db.queryRow(testing.allocator, "INVALID SQL", &.{}));
}

test "exec of empty SQL is still a successful no-op" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    // No error, and no statement run: `changes()` still reports whatever
    // the last real write did (the seed INSERTs), not a new write.
    try ctx.db.exec(testing.allocator, "", &.{});
    try testing.expectEqual(@as(i64, 1), ctx.db.changes());
}

test "empty argv element still binds SQL NULL" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc, "CREATE TABLE nullable (id TEXT, v TEXT)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO nullable VALUES (?, ?)", &.{ "a", "" });

    const row = try ctx.db.queryRow(alloc, "SELECT COUNT(*) FROM nullable WHERE v IS NULL", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "a constraint violation is still ExecuteFailed, and the statement is reusable" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // id 1 exists → UNIQUE violation.
    try testing.expectError(Error.ExecuteFailed, ctx.db.exec(
        alloc,
        "INSERT INTO users (id, username, email) VALUES (?, ?, ?)",
        &.{ "1", "dup", "dup@x" },
    ));

    // Cached statement, after a failed step, must still work.
    try ctx.db.exec(alloc, "INSERT INTO users (id, username, email) VALUES (?, ?, ?)", &.{ "99", "ok", "ok@x" });
    const row = try ctx.db.queryRow(alloc, "SELECT username FROM users WHERE id = ?", &.{"99"});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("ok", row.values[0]);
}

test "too many args still returns BindFailed" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    try testing.expectError(Error.BindFailed, ctx.db.exec(
        testing.allocator,
        "INSERT INTO users (id) VALUES (?)",
        &.{ "x", "y", "z" },
    ));
}

test "queryRow with no match still returns RowNotFound" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    try testing.expectError(Error.RowNotFound, ctx.db.queryRow(
        testing.allocator,
        "SELECT id FROM users WHERE id = ?",
        &.{"424242"},
    ));
}

test "exec before init still returns DatabaseNotFound" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    try testing.expectError(Error.DatabaseNotFound, db.exec(testing.allocator, "SELECT 1", &.{}));
}

test "queryRow before init still returns DatabaseNotFound" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    try testing.expectError(Error.DatabaseNotFound, db.queryRow(testing.allocator, "SELECT 1", &.{}));
}

// ─── Transactions reuse the same cached statements ────────────────────────

test "transactions reuse cached statements and still commit atomically" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc, "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var tx = try ctx.db.begin();
        defer tx.commitOrRollback() catch {};

        const a = try std.fmt.allocPrint(alloc, "a{d}", .{round});
        defer alloc.free(a);
        try tx.exec(alloc, "INSERT INTO log (id, msg) VALUES (?, ?)", &.{ a, "first" });
        try tx.exec(alloc, "UPDATE log SET msg = ? WHERE id = ?", &.{ "updated", a });
        try tx.commit();
    }

    const total = try ctx.db.queryRow(alloc, "SELECT COUNT(*) FROM log", &.{});
    defer total.deinit(alloc);
    try testing.expectEqualStrings("20", total.values[0]);

    const updated = try ctx.db.queryRow(alloc, "SELECT COUNT(*) FROM log WHERE msg = 'updated'", &.{});
    defer updated.deinit(alloc);
    try testing.expectEqualStrings("20", updated.values[0]);
}

test "a rolled-back transaction still discards its writes with the cache in play" {
    var ctx = try setupSeeded();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc, "CREATE TABLE tmp (id INTEGER PRIMARY KEY)", &.{});
    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(alloc, "INSERT INTO tmp (id) VALUES (?)", &.{"1"});
        try tx.exec(alloc, "INSERT INTO tmp (id) VALUES (?)", &.{"2"});
        try tx.rollback();
    }

    const row = try ctx.db.queryRow(alloc, "SELECT COUNT(*) FROM tmp", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("0", row.values[0]);
}

test "deinit finalizes cached statements without leaking (leak-checked allocator)" {
    // The statement cache owns SQL-text keys. `deinit` must release them —
    // `std.testing.allocator` turns a missed free into a failure here.
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();

    var db: SqliteBackend = .{};
    defer db.deinit();
    try db.init(threaded.io(), ":memory:");

    // Several distinct SQL texts (DDL + DML + SELECT), each run more than
    // once, so both the cached and the uncached paths are exercised and
    // everything must still be released by `deinit`.
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        const id = try std.fmt.allocPrint(alloc, "{d}", .{round + 1});
        defer alloc.free(id);
        try db.exec(alloc, "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY)", &.{});
        try db.exec(alloc, "INSERT INTO t (id) VALUES (?)", &.{id});
        try db.exec(alloc, "UPDATE t SET id = id WHERE id = ?", &.{id});
        const row = try db.queryRow(alloc, "SELECT COUNT(*) FROM t", &.{});
        defer row.deinit(alloc);
    }
}
