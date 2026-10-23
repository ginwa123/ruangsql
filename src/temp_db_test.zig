//! Behaviour tests for the universal `database.createTempDb`: the same call must yield a
//! working, isolated, disposable database on whatever backend the app compiled in.

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const database = @import("database.zig");

fn firstText(allocator: std.mem.Allocator, db: *database.Db, sql: []const u8) !?[]u8 {
    var rows = try db.query(allocator, sql, &.{});
    defer rows.deinit();
    const row = (try rows.next()) orelse return null;
    defer row.deinit(allocator);
    if (row.values.len == 0) return null;
    return try allocator.dupe(u8, row.values[0]);
}

test "a temp database keeps the rows written to it" {
    const alloc = testing.allocator;
    if (!database.tempDbAvailable()) return;

    var temp = try database.createTempDb(alloc, .{});
    defer temp.deinit();

    try temp.db.exec(alloc, "CREATE TABLE items (id INTEGER, name TEXT)", &.{});
    try temp.db.exec(alloc, "INSERT INTO items (id, name) VALUES (1, 'ada')", &.{});

    const name = try firstText(alloc, &temp.db, "SELECT name FROM items WHERE id = 1") orelse return error.ExpectedRow;
    defer alloc.free(name);
    try testing.expectEqualStrings("ada", name);
}

test "two temp databases share no tables or rows" {
    const alloc = testing.allocator;
    if (!database.tempDbAvailable()) return;

    var first = try database.createTempDb(alloc, .{});
    defer first.deinit();
    var second = try database.createTempDb(alloc, .{});
    defer second.deinit();

    try first.db.exec(alloc, "CREATE TABLE notes (body TEXT)", &.{});
    try first.db.exec(alloc, "INSERT INTO notes (body) VALUES ('from first')", &.{});
    try second.db.exec(alloc, "CREATE TABLE notes (body TEXT)", &.{});
    try second.db.exec(alloc, "INSERT INTO notes (body) VALUES ('from second')", &.{});

    const in_first = try firstText(alloc, &first.db, "SELECT body FROM notes") orelse return error.ExpectedRow;
    defer alloc.free(in_first);
    const in_second = try firstText(alloc, &second.db, "SELECT body FROM notes") orelse return error.ExpectedRow;
    defer alloc.free(in_second);

    try testing.expectEqualStrings("from first", in_first);
    try testing.expectEqualStrings("from second", in_second);
}

test "deinit is idempotent and leaves no allocation behind" {
    const alloc = testing.allocator;
    if (!database.tempDbAvailable()) return;

    var temp = try database.createTempDb(alloc, .{});
    temp.deinit();
    temp.deinit();
}

test "tempDbAvailable agrees with createTempDb succeeding" {
    const alloc = testing.allocator;
    if (!database.tempDbAvailable()) {
        try testing.expectError(database.Error.DatabaseNotFound, database.createTempDb(alloc, .{}));
        return;
    }

    var temp = try database.createTempDb(alloc, .{});
    temp.deinit();
}

test "an unreachable postgres instance is reported, not hidden" {
    const alloc = testing.allocator;
    if (!build_options.enable_postgres) return;

    const result = database.createTempDb(alloc, .{
        .base_conninfo = "host=/tmp port=1 user=ginwa dbname=postgres connect_timeout=1",
    });
    try testing.expectError(database.Error.DatabaseNotFound, result);
}
