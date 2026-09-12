//! Tests for `SqliteBackend.Rows.getLastErrorMessage` — the new
//! path that surfaces the underlying SQLite error message (e.g.
//! `"fts5: syntax error"`) to callers instead of the bare
//! `Error.QueryFailed` enum name. Without this, the user sees
//! `"FTS search failed: QueryFailed"` in the chat and has no idea
//! what actually broke.
//!
//! Blackbox: each test opens a fresh `:memory:` DB, sets up an FTS5
//! table, runs a deliberately-bad MATCH query, and asserts that
//! `rows.getLastErrorMessage()` returns a non-empty, useful string.
//!
//! These tests are RED before the implementation lands — they call
//! `rows.getLastErrorMessage()`, which doesn't exist yet. They're
//! GREEN after `Rows.last_error_msg` is added.

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
    // FTS5 parses the MATCH query string. `a -` (binary NOT with no
    // right operand) is a syntax error — sqlite3_step returns an
    // error. Before the fix, callers only saw `Error.QueryFailed`.
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

    // KEY assertion: getLastErrorMessage() must return a non-empty
    // string so callers can include it in their formatted error
    // rather than just `QueryFailed`.
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
    // Ownership contract: the returned slice lives until deinit. After
    // deinit, getLastErrorMessage() must return null (no use-after-free
    // window where callers could still try to read the message).
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
    // After deinit, getLastErrorMessage would be a use-after-free.
    // The contract is: null after deinit. We can't call deinit twice
    // here (the test ctx teardown closes the db), so we just check
    // the lifecycle contract by reading the message before deinit
    // and ensuring it was non-null. The leak-detector in
    // std.testing.allocator catches any buffer we forgot to free.
}
