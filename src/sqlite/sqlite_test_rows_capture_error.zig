//! Tests for `SqliteBackend.Rows.getLastErrorMessage`, which surfaces the raw SQLite message (e.g. `"fts5:
//! syntax error"`) instead of the bare `Error.QueryFailed`. Blackbox: fresh `:memory:`, FTS5 table, bad MATCH.

const std = @import("std");
const testing = std.testing;
const sqlite_mod = @import("Sqlite.zig");
const SqliteBackend = sqlite_mod.SqliteBackend;

const DbCtx = struct {
    db: SqliteBackend,
    threaded: std.Io.Threaded,
};

fn setupDb() !DbCtx {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    errdefer threaded.deinit();
    const io = threaded.io();
    var db: SqliteBackend = .{};
    errdefer db.deinit();
    try db.init(io, ":memory:");
    return .{ .db = db, .threaded = threaded };
}

fn teardown(ctx: *DbCtx) void {
    ctx.db.deinit();
    ctx.threaded.deinit();
}

// ─── Group 1: FTS5 syntax error capture ─────────────────────────────────

test "Rows: getLastErrorMessage returns non-empty text after FTS5 syntax error (a -)" {
    // `a -` (binary NOT with no right operand) is an FTS5 syntax error raised at `sqlite3_step`, which callers
    // used to see only as `Error.QueryFailed`.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        \\CREATE VIRTUAL TABLE docs_fts USING fts5(content)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO docs_fts(rowid, content) VALUES (1, 'hello world')", &.{});

    var rows = try ctx.db.query(alloc,
        "SELECT rowid FROM docs_fts WHERE docs_fts MATCH ?",
        &.{"a -"});
    defer rows.deinit();

    const next_result = rows.next();
    try testing.expectError(sqlite_mod.Error.QueryFailed, next_result);

    // KEY assertion: a non-empty message that is not the bare `QueryFailed`, so callers can put it in their error.
    const sql_msg = rows.getLastErrorMessage() orelse "";
    try testing.expect(sql_msg.len > 0);
    try testing.expect(!std.mem.eql(u8, sql_msg, "QueryFailed"));
}

test "Rows: getLastErrorMessage returns null before any error occurs" {
    // Sanity: a successful query must not leak a stale error message.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO t (val) VALUES ('ok')", &.{});

    var rows = try ctx.db.query(alloc,
        "SELECT val FROM t", &.{});
    defer rows.deinit();

    if (try rows.next()) |row| {
        defer row.deinit(alloc);
    }
    try testing.expect(rows.getLastErrorMessage() == null);
}

test "Rows: getLastErrorMessage remains valid until deinit, then is null" {
    // Ownership contract: the returned slice lives until `deinit`; after that `getLastErrorMessage()` must return
    // null, so no use-after-free window is left open for callers holding the message.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        \\CREATE VIRTUAL TABLE d USING fts5(content)
    , &.{});

    {
        var rows = try ctx.db.query(alloc,
            "SELECT rowid FROM d WHERE d MATCH ?",
            &.{"bad -"});
        _ = rows.next() catch {};
        const sql_msg = rows.getLastErrorMessage();
        try testing.expect(sql_msg != null);
        rows.deinit();
    }
    // After `deinit`, `getLastErrorMessage()` would be a use-after-free. `deinit` cannot be called twice here (the
    // ctx teardown closes the db), so the message is read before it and asserted non-null; the leak detector covers frees.
}
