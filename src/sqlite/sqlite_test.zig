//! Behavioral tests for `Sqlite.zig`: in-memory `:memory:` DB per test via `setupDb()`; covers init/exec/query/queryRow/changes/deinit, tx + savepoints, error variants.
//! A tx holds the backend mutex for its whole lifetime — never call `db.exec`/`db.query` inside one (`std.Io.Mutex` is not reentrant), and never issue raw BEGIN/COMMIT: use `db.begin()` / `tx.*`.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const sqlite_mod = @import("Sqlite.zig");
const SqliteBackend = sqlite_mod.SqliteBackend;

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Context returned by `setupDb`, as a named type so every scope sees the same
/// type — two anonymous structs would be distinct types in Zig 0.16.
const DbCtx = struct {
    db: SqliteBackend,
    threaded: std.Io.Threaded,
};

/// Open a fresh in-memory sqlite DB plus the Io runtime that owns its event
/// loop; the caller MUST `teardown()` the returned value.
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

/// Run a single-column SELECT and return a duplicated copy of the first
/// row's first column. Returns null when the query produces no rows.
fn scalarText(alloc: std.mem.Allocator, db: *SqliteBackend, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        if (row.values.len == 0) return null;
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

/// Return every row's first column as owned slices; the caller frees the outer
/// slice and each inner slice via `freeAll`.
fn allScalarText(alloc: std.mem.Allocator, db: *SqliteBackend, sql: []const u8, args: []const []const u8) ![]const []u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    var out: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit(alloc);
    }
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (row.values.len > 0) {
            try out.append(alloc, try alloc.dupe(u8, row.values[0]));
        }
    }
    return out.items;
}

fn freeAll(alloc: std.mem.Allocator, items: []const []u8) void {
    for (items) |s| alloc.free(s);
    alloc.free(items);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 1: Lifecycle

test "init :memory: opens successfully and is queryable" {
    const alloc = testing.allocator;
    var ctx = try setupDb();
    defer teardown(&ctx);

    // PRAGMA confirms the connection is live.
    const mode = (try scalarText(alloc, &ctx.db, "PRAGMA journal_mode", &.{})) orelse unreachable;
    defer alloc.free(mode);
    // In-memory DBs always report "memory" as their journal mode
    // (WAL is ignored for in-memory).
    try testing.expectEqualStrings("memory", mode);
}

test "init on bad path (non-existent dir) returns DatabaseNotFound" {
    if (builtin.os.tag == .windows) {
        // Windows path-mismatch semantics differ — skip.
        return;
    }
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: SqliteBackend = .{};
    defer db.deinit();

    // /nonexistent-root/nope/nope.db: the parent dirs don't exist, so
    // sqlite3_open returns SQLITE_CANTOPEN, which the wrapper maps to DatabaseNotFound.
    const result = db.init(io, "/nonexistent-root-1234567890/nope/nope.db");
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

test "init on a directory path returns an error" {
    if (builtin.os.tag == .windows) {
        return;
    }
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: SqliteBackend = .{};
    defer db.deinit();

    // /tmp is always a directory. Open-as-db returns SQLITE_CANTOPEN
    // (cannot open as database file).
    const result = db.init(io, "/tmp");
    // Both DatabaseNotFound and OpenFailed are valid for "can't open the file as
    // a database" — the contract is only that some error is returned.
    try testing.expect(result == sqlite_mod.Error.DatabaseNotFound or result == sqlite_mod.Error.OpenFailed);
}

test "deinit is idempotent" {
    var ctx = try setupDb();
    // Call deinit twice. Should not crash, should not double-free.
    ctx.db.deinit();
    ctx.db.deinit();
    // threaded still needs to be cleaned up.
    ctx.threaded.deinit();
}

test "deinit without init is a safe no-op" {
    var db: SqliteBackend = .{};
    db.deinit(); // self.db is null — should just return.
}

test "changes() before any write returns 0" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

test "init on file-backed path creates the file" {
    if (builtin.os.tag == .windows) return;
    const alloc = testing.allocator;

    // A static literal is sentinel-terminated, matching `init`'s `[:0]const u8`;
    // `defer deleteFile` keeps later runs starting fresh.
    const path = "/tmp/nalar_sqlite_test_create.db";
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};

    var db: SqliteBackend = .{};
    defer db.deinit();
    try db.init(io, path);

    // File should now exist. Zig 0.16's `Dir.statFile` takes an `io`
    // parameter (the Io-aware API).
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        std.debug.print("expected file at {s} but statFile failed: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    try testing.expect(stat.kind == .file);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 2: exec

test "exec CREATE TABLE works" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT NOT NULL)",
        &.{});

    // Verify via sqlite_master.
    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='foo'",
        &.{})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("foo", name);
}

test "exec INSERT with no args" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES ('a', 'Alice')",
        &.{});
    try testing.expectEqual(@as(i64, 1), ctx.db.changes());
}

test "exec INSERT with text args" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "user_1", "Alice" });

    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo WHERE id = ?", &.{"user_1"})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("Alice", name);
}

test "exec INSERT with empty arg binds as NULL (project convention)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    // Empty string "" → NULL (this is the documented convention).
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "" });

    // Verify: IS NULL should match.
    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo WHERE name IS NULL", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "exec INSERT with unicode (UTF-8) text" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "héllo 世界 🌍" });

    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo WHERE id = ?", &.{"u1"})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("héllo 世界 🌍", name);
}

test "exec INSERT with single quotes in arg is escaped safely (no SQL injection)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    // Attacker-controlled string with quotes, semicolons, and DROP.
    const evil = "evil'; DROP TABLE foo; --";
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", evil });

    // The literal string is stored verbatim (NOT executed as SQL).
    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo WHERE id = ?", &.{"u1"})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings(evil, name);

    // And the table still exists (not dropped).
    const count = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(count);
    try testing.expectEqualStrings("1", count);
}

test "exec with empty SQL is a successful no-op" {
    // An empty SQL string is a successful no-op, not a syntax error — SQLite's
    // documented behavior, preserved by the wrapper (prepare_v2 returns OK).
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc, "", &.{}); // should NOT error
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

test "exec with malformed SQL returns PrepareFailed" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const result = ctx.db.exec(alloc, "NOT VALID SQL AT ALL garbage", &.{});
    try testing.expectError(sqlite_mod.Error.PrepareFailed, result);
}

test "exec with too few args binds NULL for missing placeholders" {
    // A `?` with no bound parameter defaults to NULL at step() time, so "too few
    // args" succeeds on a nullable column; BindFailed needs too MANY args.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT, name TEXT)",
        &.{});
    // SQL has 2 placeholders, we pass 1. The missing one binds NULL.
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{"only_id"});

    // Verify name was inserted as NULL.
    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo WHERE name IS NULL", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "exec with too many args returns BindFailed" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT, name TEXT)",
        &.{});
    // SQL needs 1 arg, we pass 3.
    const result = ctx.db.exec(alloc,
        "INSERT INTO foo (id) VALUES (?)",
        &.{ "x", "y", "z" });
    try testing.expectError(sqlite_mod.Error.BindFailed, result);
}

test "exec on NOT NULL violation returns ExecuteFailed" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
        &.{});
    // Bind '' → NULL (project convention), then NOT NULL fires.
    const result = ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "" });
    try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
}

test "exec on UNIQUE violation returns ExecuteFailed" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "first" });
    // Second insert with same PRIMARY KEY — UNIQUE violation.
    const result = ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "second" });
    try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
}

test "exec on duplicate CREATE TABLE returns PrepareFailed" {
    // A duplicate CREATE TABLE fails at prepare_v2 time because the table already
    // exists, so it surfaces as PrepareFailed, not ExecuteFailed (a step() error).
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT)",
        &.{});
    // Re-creating without IF NOT EXISTS should fail at prepare.
    const result = ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT)",
        &.{});
    try testing.expectError(sqlite_mod.Error.PrepareFailed, result);
}

test "exec with very long text binding (1 MB)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, payload TEXT)",
        &.{});

    // 1 MB of 'A's
    const big = try alloc.alloc(u8, 1024 * 1024);
    defer alloc.free(big);
    @memset(big, 'A');

    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, payload) VALUES (?, ?)",
        &.{ "big", big });

    // Round-trip — verify length preserved.
    var q = try ctx.db.query(alloc, "SELECT payload FROM foo WHERE id = ?", &.{"big"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ExpectedRowMissing;
    defer row.deinit(alloc);
    try testing.expectEqual(@as(usize, 1024 * 1024), row.values[0].len);
    // Spot-check content.
    try testing.expectEqual(@as(u8, 'A'), row.values[0][0]);
    try testing.expectEqual(@as(u8, 'A'), row.values[0][row.values[0].len - 1]);
}

test "exec with empty argv when SQL has no placeholders works" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id INTEGER PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (name) VALUES ('no_args_needed')",
        &.{});
    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo", &.{})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("no_args_needed", name);
}

test "exec of multi-statement SQL only runs the first (sqlite3_prepare_v2 semantics)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    // Only the first statement of multi-statement SQL is prepared and executed;
    // the rest are silently ignored (sqlite3_prepare_v2 semantics).
    try ctx.db.exec(alloc,
        \\CREATE TABLE foo (id INTEGER PRIMARY KEY);
        \\SELECT 1;
    , &.{});
    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='foo'", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 3: queryRow

test "queryRow returns the single matching row" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "Alice" });

    const row = try ctx.db.queryRow(alloc,
        "SELECT id, name FROM foo WHERE id = ?", &.{"u1"});
    defer row.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), row.values.len);
    try testing.expectEqualStrings("u1", row.values[0]);
    try testing.expectEqualStrings("Alice", row.values[1]);
}

test "queryRow with no match returns RowNotFound" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});

    const result = ctx.db.queryRow(alloc,
        "SELECT id FROM foo WHERE id = ?", &.{"nonexistent"});
    try testing.expectError(sqlite_mod.Error.RowNotFound, result);
}

test "queryRow with multiple rows returns only the first" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, n) VALUES ('a', 1), ('b', 2), ('c', 3)",
        &.{});

    const row = try ctx.db.queryRow(alloc,
        "SELECT id FROM foo ORDER BY n", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("a", row.values[0]);
}

test "queryRow with no args when SQL has no placeholders" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id INTEGER PRIMARY KEY, val TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (val) VALUES ('hello')", &.{});

    const row = try ctx.db.queryRow(alloc,
        "SELECT val FROM foo", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("hello", row.values[0]);
}

test "queryRow on NULL column returns empty []u8" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES ('u1', NULL)", &.{});

    const row = try ctx.db.queryRow(alloc,
        "SELECT name FROM foo WHERE id = ?", &.{"u1"});
    defer row.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), row.values.len);
    try testing.expectEqual(@as(usize, 0), row.values[0].len);
}

test "queryRow on invalid SQL returns PrepareFailed" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    const result = ctx.db.queryRow(alloc, "INVALID SQL", &.{});
    try testing.expectError(sqlite_mod.Error.PrepareFailed, result);
}

test "queryRow on closed/uninitialized db returns DatabaseNotFound" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    // Never called init — self.db is null.
    const alloc = testing.allocator;
    const result = db.queryRow(alloc, "SELECT 1", &.{});
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 4: query (multi-row iterator)

test "query with no rows returns iterator that yields null" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var q = try ctx.db.query(alloc, "SELECT id FROM foo", &.{});
    defer q.deinit();

    const next = try q.next();
    try testing.expect(next == null);
}

test "query iterates all rows" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, n) VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});

    // Iterate inline (no allScalarText helper) — keeps the test
    // hermetic and easy to debug if it leaks.
    var q = try ctx.db.query(alloc, "SELECT id FROM foo ORDER BY n", &.{});
    defer q.deinit();

    var collected: [3][]u8 = undefined;
    var idx: usize = 0;
    while (try q.next()) |row| {
        defer row.deinit(alloc);
        if (idx >= collected.len) return error.TooManyRows;
        collected[idx] = try alloc.dupe(u8, row.values[0]);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx);
    defer for (collected) |s| alloc.free(s);
    try testing.expectEqualStrings("a", collected[0]);
    try testing.expectEqualStrings("b", collected[1]);
    try testing.expectEqualStrings("c", collected[2]);
}

test "query with NULL column returns empty []u8" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES ('u1', NULL), ('u2', 'set'), ('u3', NULL)",
        &.{});

    var q = try ctx.db.query(alloc, "SELECT name FROM foo ORDER BY id", &.{});
    defer q.deinit();

    const r1 = (try q.next()) orelse return error.ExpectedRow;
    defer r1.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), r1.values[0].len); // NULL → empty

    const r2 = (try q.next()) orelse return error.ExpectedRow;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("set", r2.values[0]);

    const r3 = (try q.next()) orelse return error.ExpectedRow;
    defer r3.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), r3.values[0].len); // NULL → empty

    try testing.expect((try q.next()) == null);
}

test "query with many columns (5+) reads all of them" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        \\CREATE TABLE foo (
        \\    c1 TEXT, c2 TEXT, c3 TEXT, c4 TEXT, c5 TEXT, c6 TEXT
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 'b', 'c', 'd', 'e', 'f')", &.{});

    const row = try ctx.db.queryRow(alloc,
        "SELECT c1, c2, c3, c4, c5, c6 FROM foo", &.{});
    defer row.deinit(alloc);

    try testing.expectEqual(@as(usize, 6), row.values.len);
    try testing.expectEqualStrings("a", row.values[0]);
    try testing.expectEqualStrings("f", row.values[5]);
}

test "Rows.next() after DONE returns null (defensive against SQLITE_MISUSE)" {
    // step() on a statement that already returned DONE triggers SQLITE_MISUSE;
    // the wrapper treats that as DONE and returns null, so over-stepping is safe.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});

    var q = try ctx.db.query(alloc, "SELECT id FROM foo", &.{});
    defer q.deinit();

    const r1 = (try q.next()) orelse return error.ExpectedRow;
    r1.deinit(alloc);
    try testing.expect((try q.next()) == null);
    // Second call after exhaustion: still null (not QueryFailed).
    try testing.expect((try q.next()) == null);
}

test "Rows.deinit is safe to call after partial iteration" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});

    {
        var q = try ctx.db.query(alloc, "SELECT id FROM foo", &.{});
        // Only consume 1 row, then drop without further next().
        const r = (try q.next()) orelse return error.ExpectedRow;
        r.deinit(alloc);
        q.deinit();
    }

    // Should be able to query again — statement was finalized properly.
    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("3", cnt);
}

test "Row.deinit is safe with zero columns (0-column row)" {
    // SQLite's `SELECT 1 WHERE 0` yields 1 column and 0 rows; this test is the
    // inverse — several columns, all NULL, so each value has length 0.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, a TEXT, b TEXT, c TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, a, b, c) VALUES ('u1', NULL, NULL, NULL)", &.{});

    const row = try ctx.db.queryRow(alloc,
        "SELECT a, b, c FROM foo WHERE id = ?", &.{"u1"});
    defer row.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), row.values.len);
    for (row.values) |v| try testing.expectEqual(@as(usize, 0), v.len);
}

test "query iterates many rows (100) without leaks" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (n INTEGER PRIMARY KEY, s TEXT)", &.{});
    // Insert 100 rows. We free each formatted id immediately after
    // the INSERT (the database copies the bytes via SQLITE_TRANSIENT).
    var i: i64 = 0;
    while (i < 100) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(id);
        try ctx.db.exec(alloc,
            "INSERT INTO foo (n, s) VALUES (?, ?)",
            &.{ id, "row" });
    }

    var q = try ctx.db.query(alloc, "SELECT n FROM foo", &.{});
    defer q.deinit();

    var count: usize = 0;
    while (try q.next()) |row| {
        row.deinit(alloc);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 100), count);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 5: changes()

test "changes() reflects INSERT (1)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "Alice" });
    try testing.expectEqual(@as(i64, 1), ctx.db.changes());
}

test "changes() reflects INSERT with multiple VALUES (3)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});
    try testing.expectEqual(@as(i64, 3), ctx.db.changes());
}

test "changes() reflects UPDATE matching N rows" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});
    // Update all rows.
    try ctx.db.exec(alloc,
        "UPDATE foo SET n = n + 10", &.{});
    try testing.expectEqual(@as(i64, 3), ctx.db.changes());

    // UPDATE matching 0 rows → 0 changes.
    try ctx.db.exec(alloc,
        "UPDATE foo SET n = 0 WHERE id = ?", &.{"nonexistent"});
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

test "changes() reflects DELETE" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});

    try ctx.db.exec(alloc, "DELETE FROM foo WHERE n < 3", &.{});
    try testing.expectEqual(@as(i64, 2), ctx.db.changes());
}

test "changes() returns 0 for non-data-write statements (CREATE TABLE)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT)", &.{});
    // CREATE TABLE doesn't change row counts.
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

test "changes() called before init returns 0 (not a crash)" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    try testing.expectEqual(@as(i64, 0), db.changes());
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 6: Error variant contract

test "exec before init returns DatabaseNotFound" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    const alloc = testing.allocator;
    const result = db.exec(alloc, "SELECT 1", &.{});
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

test "query before init returns DatabaseNotFound" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    const alloc = testing.allocator;
    const result = db.query(alloc, "SELECT 1", &.{});
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 7: Transaction (tx commit/rollback via API — never raw BEGIN/COMMIT)

test "tx commit commits inserts" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    defer tx.commitOrRollback() catch {};
    try tx.exec(alloc,
        "INSERT INTO foo VALUES ('a'), ('b')", &.{});
    try tx.commit();

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}

test "tx rollback undoes inserts" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    defer tx.commitOrRollback() catch {};
    try tx.exec(alloc,
        "INSERT INTO foo VALUES ('a'), ('b')", &.{});
    try tx.rollback();

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 8: SQLite-specific features

test "PRAGMA user_version round-trips through exec/queryRow" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc, "PRAGMA user_version = 42", &.{});
    const v = try ctx.db.queryRow(alloc, "PRAGMA user_version", &.{});
    defer v.deinit(alloc);
    try testing.expectEqualStrings("42", v.values[0]);
}

test "AUTOINCREMENT PRIMARY KEY produces sequential IDs" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id INTEGER PRIMARY KEY AUTOINCREMENT, s TEXT)",
        &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo (s) VALUES ('x')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo (s) VALUES ('y')", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo (s) VALUES ('z')", &.{});

    var q = try ctx.db.query(alloc, "SELECT id FROM foo ORDER BY id", &.{});
    defer q.deinit();
    const r1 = (try q.next()) orelse return error.ExpectedRow;
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("1", r1.values[0]);
    const r2 = (try q.next()) orelse return error.ExpectedRow;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("2", r2.values[0]);
    const r3 = (try q.next()) orelse return error.ExpectedRow;
    defer r3.deinit(alloc);
    try testing.expectEqualStrings("3", r3.values[0]);
}

test "exec with the same prepared statement pattern across calls works" {
    // Tests the prepare/finalize cycle across multiple exec calls.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const id = try std.fmt.allocPrint(alloc, "u{d}", .{i});
        defer alloc.free(id);
        try ctx.db.exec(alloc,
            "INSERT INTO foo (id, n) VALUES (?, ?)",
            &.{ id, "v" });
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("50", cnt);
}

test "exec with binary-safe binding (no NUL terminator in arg)" {
    // `bind_text` takes an explicit length and needs no NUL terminator: the bound
    // bytes are copied verbatim, NUL-free.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, payload BLOB)", &.{});

    // 100 bytes of 'X' — no NUL anywhere.
    const buf = try alloc.alloc(u8, 100);
    defer alloc.free(buf);
    @memset(buf, 'X');

    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, payload) VALUES (?, ?)",
        &.{ "bin", buf });

    var q = try ctx.db.query(alloc,
        "SELECT payload FROM foo WHERE id = ?", &.{"bin"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ExpectedRow;
    defer row.deinit(alloc);
    try testing.expectEqual(@as(usize, 100), row.values[0].len);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 9: Transaction struct (begin / tx.exec / commit / rollback)

test "begin returns a Transaction and commit persists writes" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // no-op after successful commit
        try tx.exec(alloc,
            "INSERT INTO foo VALUES ('a'), ('b')", &.{});
        try tx.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}

test "rollback after commit returns TransactionClosed (single-use enforcement)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    // After commit the tx is single-use: rollback returns TransactionClosed rather
    // than a silent no-op, because commit released the mutex that rollback needs.
    const result = tx.rollback();
    try testing.expectError(sqlite_mod.Error.TransactionClosed, result);

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "defer rollback after error discards all writes (atomic)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // fires if commit() not reached
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        // Force a failure mid-tx by trying to violate the PK constraint.
        const result = tx.exec(alloc,
            "INSERT INTO foo VALUES ('a')", &.{});
        try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
        // No commit() reached — defer fires, ROLLBACK issued, 'a' is gone.
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "explicit rollback discards writes" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a'), ('b')", &.{});
        try tx.rollback();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "begin before init returns DatabaseNotFound" {
    var db: SqliteBackend = .{};
    defer db.deinit();
    const result = db.begin();
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

test "tx.queryRow sees uncommitted writes inside the same tx" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        try tx.exec(alloc, "INSERT INTO kv VALUES ('a', 'one')", &.{});

        // Read it back inside the same tx — must see 'one', not NULL.
        const row = try tx.queryRow(alloc,
            "SELECT v FROM kv WHERE k = 'a'", &.{});
        defer row.deinit(alloc);
        try testing.expectEqualStrings("one", row.values[0]);

        try tx.commit();
    }
}

test "read-modify-write pattern is atomic across tx" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        \\CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER NOT NULL)
    , &.{});
    try ctx.db.exec(alloc, "INSERT INTO counter VALUES (1, 0)", &.{});

    // Read-modify-write: inside a tx the read and the write are atomic with respect
    // to other writers.
    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        const row = try tx.queryRow(alloc,
            "SELECT n FROM counter WHERE id = 1", &.{});
        defer row.deinit(alloc);
        const n = try std.fmt.parseInt(i32, row.values[0], 10);
        try testing.expectEqual(@as(i32, 0), n);

        try tx.exec(alloc,
            "UPDATE counter SET n = ? WHERE id = 1",
            &.{ "1" });
        try tx.commit();
    }

    // Verify the write persisted.
    const row = try ctx.db.queryRow(alloc,
        "SELECT n FROM counter WHERE id = 1", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "tx.query returns Rows iterator (same shape as backend.query)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE items (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        try tx.exec(alloc, "INSERT INTO items VALUES ('a'), ('b'), ('c')", &.{});

        var q = try tx.query(alloc,
            "SELECT id FROM items ORDER BY id", &.{});
        defer q.deinit();

        const r1 = (try q.next()) orelse return error.ExpectedRow;
        defer r1.deinit(alloc);
        try testing.expectEqualStrings("a", r1.values[0]);

        const r2 = (try q.next()) orelse return error.ExpectedRow;
        defer r2.deinit(alloc);
        try testing.expectEqualStrings("b", r2.values[0]);

        const r3 = (try q.next()) orelse return error.ExpectedRow;
        defer r3.deinit(alloc);
        try testing.expectEqualStrings("c", r3.values[0]);

        try testing.expect((try q.next()) == null);
        try tx.commit();
    }
}

test "savepoint commit persists inner writes, outer commits too" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    {
        var outer = try ctx.db.begin();
        defer outer.rollback() catch {};

        try outer.exec(alloc, "INSERT INTO log VALUES ('1', 'outer')", &.{});

        {
            var inner = try ctx.db.savepoint();
            defer inner.rollback() catch {};
            try inner.exec(alloc, "INSERT INTO log VALUES ('2', 'inner')", &.{});
            try inner.commit();
        }

        try outer.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM log", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}

test "savepoint rollback undoes only inner writes, outer still alive" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    {
        var outer = try ctx.db.begin();
        defer outer.rollback() catch {};

        try outer.exec(alloc, "INSERT INTO log VALUES ('1', 'outer')", &.{});

        {
            var inner = try ctx.db.savepoint();
            defer inner.rollback() catch {};
            try inner.exec(alloc, "INSERT INTO log VALUES ('2', 'inner')", &.{});
            try inner.rollback();
            // 'inner' row gone, but the outer tx + 'outer' row still in flight.
        }

        try outer.exec(alloc, "INSERT INTO log VALUES ('3', 'outer2')", &.{});
        try outer.commit();
    }

    // Expect only '1' (outer) and '3' (outer2) — '2' (inner) was rolled back.
    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM log", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);

    const msg1 = (try scalarText(alloc, &ctx.db,
        "SELECT msg FROM log WHERE id = '2'", &.{})) orelse "";
    defer if (msg1.len > 0) alloc.free(msg1);
    try testing.expectEqualStrings("", msg1);
}

test "savepoint without outer tx returns ExecuteFailed" {
    var ctx = try setupDb();
    defer teardown(&ctx);

    // No begin() before savepoint() — should fail.
    const result = ctx.db.savepoint();
    try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
}

test "nested savepoints (depth 2 -> 3) commit and rollback correctly" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    {
        var outer = try ctx.db.begin();
        defer outer.rollback() catch {};

        try outer.exec(alloc, "INSERT INTO log VALUES ('a', 'outer')", &.{});

        {
            var mid = try ctx.db.savepoint();
            defer mid.rollback() catch {};
            try mid.exec(alloc, "INSERT INTO log VALUES ('b', 'mid')", &.{});

            {
                var deep = try ctx.db.savepoint();
                defer deep.rollback() catch {};
                try deep.exec(alloc, "INSERT INTO log VALUES ('c', 'deep')", &.{});
                try deep.commit(); // commit deep
            }

            // Roll back mid — this should undo 'b' and 'c'.
            try mid.rollback();
        }

        try outer.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM log", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt); // only 'a'
}

test "backend.deinit() while tx is open: tx.commit returns DatabaseNotFound" {
    // Use-after-free guard: `deinit()` nulls `self.db`, so committing a tx whose
    // backend was closed mid-flight returns DatabaseNotFound instead of dereferencing it.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});

    // Close the backend while tx is still in flight. The mutex is
    // held by the tx; commit() must release it AND return DatabaseNotFound.
    ctx.db.deinit();
    const result = tx.commit();
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

test "backend.deinit() while tx is open: tx.rollback returns DatabaseNotFound" {
    // Mirror of the commit test, for the rollback path.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});

    ctx.db.deinit();
    const result = tx.rollback();
    try testing.expectError(sqlite_mod.Error.DatabaseNotFound, result);
}

test "tx.commit after commit returns TransactionClosed (single-use enforcement)" {
    // After a successful commit the tx is single-use and any further call returns
    // TransactionClosed — the mutex is gone, so a tx.* call would race writers.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    // Second commit → TransactionClosed.
    try testing.expectError(sqlite_mod.Error.TransactionClosed, tx.commit());
    // exec after commit → TransactionClosed.
    try testing.expectError(sqlite_mod.Error.TransactionClosed, tx.exec(alloc, "INSERT INTO foo VALUES ('b')", &.{}));
    // rollback after commit → TransactionClosed (use the switch idiom).
    tx.rollback() catch |err| switch (err) {
        error.TransactionClosed => {},
        else => return err,
    };
}

test "defer tx.rollback() catch |err| switch (TransactionClosed => {}) is the safe idiom" {
    // The point of defer-rollback: if commit() already ran, the deferred rollback
    // returns TransactionClosed and is swallowed; otherwise it does the rollback.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        // Zig 0.16 forbids `return` from a `defer`, so this deferred rollback must
        // swallow every error; the only one possible here is TransactionClosed.
        defer tx.rollback() catch {};
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        try tx.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}
test "integration: atomic INSERT-then-UPDATE (mirrors insert_llm_histories pattern)" {
    // The canonical tx use case: INSERT a row referencing a parent, then UPDATE the
    // parent in the same tx — a crash between them would leave its metadata stale.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        \\CREATE TABLE sessions (
        \\    id TEXT PRIMARY KEY,
        \\    cwd TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        \\CREATE TABLE llm_history (
        \\    id TEXT PRIMARY KEY,
        \\    session_id TEXT NOT NULL,
        \\    response_content TEXT NOT NULL DEFAULT ''
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO sessions VALUES ('s1', '/old/path')", &.{});

    // Atomic INSERT into llm_history + UPDATE sessions.cwd.
    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // safety net
        try tx.exec(alloc,
            "INSERT INTO llm_history VALUES ('m1', 's1', 'hello world')",
            &.{});
        try tx.exec(alloc,
            "UPDATE sessions SET cwd = '/new/path' WHERE id = 's1'",
            &.{});
        try tx.commit();
    }

    // Both writes persisted.
    const cwd = (try scalarText(alloc, &ctx.db,
        "SELECT cwd FROM sessions WHERE id = 's1'", &.{})) orelse "";
    defer alloc.free(cwd);
    try testing.expectEqualStrings("/new/path", cwd);

    const msg = (try scalarText(alloc, &ctx.db,
        "SELECT response_content FROM llm_history WHERE id = 'm1'", &.{})) orelse "";
    defer alloc.free(msg);
    try testing.expectEqualStrings("hello world", msg);
}

test "integration: rollback of partial multi-statement leaves DB unchanged" {
    // Force a failure mid-tx by violating a UNIQUE constraint. Verify
    // the preceding INSERT was rolled back too — not just the failing one.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE items (id TEXT PRIMARY KEY, label TEXT NOT NULL)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(alloc, "INSERT INTO items VALUES ('a', 'first')", &.{});
        try tx.exec(alloc, "INSERT INTO items VALUES ('b', 'second')", &.{});
        // Force a failure: duplicate primary key.
        const result = tx.exec(alloc,
            "INSERT INTO items VALUES ('a', 'duplicate')", &.{});
        try testing.expectError(sqlite_mod.Error.ExecuteFailed, result);
        // Defer fires → ROLLBACK → 'a' and 'b' both gone.
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM items", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "commitOrRollback commits an unfinalized tx" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        // No explicit commit() — rely on defer commitOrRollback.
        try tx.commitOrRollback();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "commitOrRollback after explicit commit is a silent no-op (not TransactionClosed)" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    // commitOrRollback on an already-committed tx must succeed silently, NOT return
    // TransactionClosed — returning it would defeat the whole defer idiom.
    try tx.commitOrRollback();

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "commitOrRollback after explicit rollback is a silent no-op" {
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.rollback();

    // Same intent: commitOrRollback on an already-rolled-back tx
    // must succeed silently.
    try tx.commitOrRollback();

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "commitOrRollback inside a savepoint commits the savepoint (not the outer tx)" {
    // In a savepoint, commitOrRollback issues RELEASE sp_<n> (the savepoint's commit),
    // not COMMIT — and the outer tx is still alive afterwards.
    var ctx = try setupDb();
    defer teardown(&ctx);
    const alloc = testing.allocator;

    try ctx.db.exec(alloc,
        "CREATE TABLE log (id TEXT PRIMARY KEY, msg TEXT NOT NULL)", &.{});

    {
        var outer = try ctx.db.begin();
        defer outer.rollback() catch {};
        try outer.exec(alloc, "INSERT INTO log VALUES ('1', 'outer')", &.{});

        {
            var inner = try ctx.db.savepoint();
            try inner.exec(alloc, "INSERT INTO log VALUES ('2', 'inner')", &.{});
            try inner.commitOrRollback(); // commits the savepoint, not outer
        }

        try outer.commitOrRollback(); // commits the outer tx
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM log", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}
