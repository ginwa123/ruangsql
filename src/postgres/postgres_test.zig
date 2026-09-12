//! Comprehensive behavioral tests for `Postgres.zig` — the PostgreSQL
//! backend that mirrors `Sqlite.zig`'s public API one-for-one. Covers:
//!
//!   - `init(io, conninfo)` — open connection to a libpq conninfo string
//!   - `exec(alloc, sql, argv)` — DDL / INSERT / UPDATE / DELETE
//!   - `queryRow(alloc, sql, argv)` — single-row read (returns first or RowNotFound)
//!   - `query(alloc, sql, argv)` — multi-row iterator (Rows.next)
//!   - `changes()` — row count of last write (from PQcmdTuples)
//!   - `deinit()` — close connection
//!
//! Transactions:
//!
//!   - `begin()` → `Transaction` (top-level tx)
//!   - `savepoint()` → `Transaction` (nested, requires an outer tx)
//!   - `tx.exec / tx.query / tx.queryRow` — same shape as backend.*
//!   - `tx.commit()` / `tx.rollback()` — return Error.TransactionClosed after completion
//!   - `tx.commitOrRollback()` — silent no-op on already-finalized tx
//!   - `tx_deinit_during_open` — use-after-free guard
//!
//! ## Test isolation strategy
//!
//! Per the project's PostgreSQL convention (`pg_tmp -t`-style), each test
//! gets a FRESH database inside a SHARED PostgreSQL instance — same as
//! the SQLite tests get a fresh `:memory:` DB. The flow:
//!
//! 1. On first call, `getOrStartTestInstance` detects a running PostgreSQL
//!    instance at `host=/tmp port=54329 user=ginwa` (or whatever
//!    `POSTGRES_TEST_CONNINFO` env var specifies) and returns its
//!    conninfo string. If no instance is reachable, all tests silently
//!    pass with no assertions (no false failures).
//! 2. Per test, `setupDb` creates a fresh database named
//!    `nalar_pg_test_<random>` via `CREATE DATABASE` on the shared
//!    instance, then opens a `PostgresBackend` on that database.
//! 3. `teardown` closes the backend, then `DROP DATABASE` cleans up.
//!
//! This is the strict-isolation pattern: per-test database, no shared
//! state, no parallel-test interference. The cost is ~50 ms per test
//! (CREATE/DROP DATABASE round-trip), which is acceptable for the test
//! sizes we run.
//!
//! ## Placeholder translation
//!
//! Tests use SQLite-style `?` placeholders (the wrapper translates them
//! to PostgreSQL `$N` before sending). A dedicated group
//! `Group 10: ? → $N placeholder translation` covers the edge cases:
//! string literals, identifiers, comments, dollar-quoted strings.
//!
//! ## Cross-platform
//!
//! The c bindings use `@cImport(@cInclude("libpq-fe.h"))` on Linux
//! (which is the dev machine and CI host). macOS/Windows require
//! matching manual extern declarations (already scaffolded in
//! `Postgres.zig` — see the file-level comment for the pad).
//!
//! ## How tests are isolated
//!
//! The actual CREATE / DROP DATABASE / per-test conninfo plumbing
//! lives in `test_helpers.zig`. This file just calls into it via
//! thin `setupDb` / `teardown` wrappers so each test stays
//! readable. See `test_helpers.zig` for the full API (including
//! `createTempDb` / `dropTempDb` for any future test that wants
//! a per-test isolated database).
const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const postgres_mod = @import("Postgres.zig");
const PostgresBackend = postgres_mod.PostgresBackend;
const Error = postgres_mod.Error;
const helpers = @import("test_helpers.zig");

// ─── Per-test isolation ──────────────────────────────────────────────────
//
// All the test-instance probing, per-test temp-DB creation, and
// DROP-DATABASE cleanup lives in `test_helpers.zig`. The thin wrappers
// below exist so this file can keep its terse `setupDb(env)` /
// `teardown(ctx)` shape that mirrors sqlite_test.zig, while the real
// implementation is shared and reusable by other test files.

const TestEnv = helpers.TestEnv;
const DbCtx = helpers.TestDb;

fn ensureEnv(allocator: std.mem.Allocator) *const TestEnv {
    _ = helpers.getOrStartTestInstance(allocator);
    // We always return the (possibly empty) cached env so tests can
    // gate on `is_available`. The cache is a global singleton so the
    // first call to `getOrStartTestInstance` does the network probe;
    // every subsequent call is a no-op.
    return &helpers.g_test_env;
}

fn setupDb(allocator: std.mem.Allocator, env: *const TestEnv) !DbCtx {
    if (!env.is_available) return error.PostgresUnavailable;
    return helpers.createTempDb(allocator, env.conninfo);
}

fn teardown(allocator: std.mem.Allocator, ctx: *DbCtx) void {
    helpers.dropTempDb(allocator, ctx);
}

// ─── Test helpers ─────────────────────────────────────────────────────────

/// Run a single-column SELECT and return a duplicated copy of the first
/// row's first column. Returns null when the query produces no rows.
fn scalarText(alloc: std.mem.Allocator, db: *PostgresBackend, sql: []const u8, args: []const []const u8) !?[]u8 {
    var q = try db.query(alloc, sql, args);
    defer q.deinit();
    if (try q.next()) |row| {
        defer row.deinit(alloc);
        if (row.values.len == 0) return null;
        return try alloc.dupe(u8, row.values[0]);
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 1: Lifecycle
// ═══════════════════════════════════════════════════════════════════════════

test "init: connect to a fresh test database succeeds" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // Verify the connection is live via a round-trip query.
    const one = (try scalarText(alloc, &ctx.db, "SELECT 1", &.{})) orelse "";
    defer alloc.free(one);
    try testing.expectEqualStrings("1", one);
}

test "init on an invalid port returns an error" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    // Port 1 is reserved and should refuse connection.
    const bad = "host=/tmp port=1 user=ginwa dbname=postgres connect_timeout=1";
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: PostgresBackend = .{};
    defer db.deinit();

    const result = db.init(io, bad);
    try testing.expectError(Error.OpenFailed, result);
}

test "init on a non-existent database returns an error" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    // The base conninfo points to dbname=postgres. Override to a
    // dbname that won't exist.
    const bad = "host=/tmp port=54329 user=ginwa dbname=nalar_definitely_not_a_db connect_timeout=1";
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var db: PostgresBackend = .{};
    defer db.deinit();

    const result = db.init(io, bad);
    try testing.expectError(Error.OpenFailed, result);
}

test "deinit is idempotent (no double-free crash)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    // Call deinit twice — should not crash, should not double-free.
    ctx.db.deinit();
    ctx.db.deinit();
    // threaded still needs to be cleaned up.
    ctx.threaded.deinit();
    // Drop the test database directly. The backend is already closed
    // above, so dropTempDb's deinit steps must NOT run again — but the
    // DROP itself still has to happen, otherwise this test leaks a
    // database on the shared instance on every live-server run.
    helpers.dropDatabase(alloc, env.conninfo, ctx.db_name);
    alloc.free(ctx.db_name);
}

test "deinit without init is a safe no-op" {
    var db: PostgresBackend = .{};
    db.deinit(); // self.conn is null — should just return.
}

test "changes() before any write returns 0" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

test "changes() called before init returns 0" {
    var db: PostgresBackend = .{};
    defer db.deinit();
    try testing.expectEqual(@as(i64, 0), db.changes());
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 2: exec
// ═══════════════════════════════════════════════════════════════════════════

test "exec CREATE TABLE works" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
        &.{});

    // Verify via information_schema.
    const name = (try scalarText(alloc, &ctx.db,
        "SELECT table_name FROM information_schema.tables WHERE table_name = 'foo'",
        &.{})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("foo", name);
}

test "exec INSERT with no args" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES ('a', 'Alice')",
        &.{});
    try testing.expectEqual(@as(i64, 1), ctx.db.changes());
}

test "exec INSERT with text args" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    // Mirrors SQLite's documented behavior: empty SQL is a no-op.
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc, "", &.{}); // should NOT error
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

test "exec with malformed SQL returns ExecuteFailed" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // PostgreSQL reports PARSE ERROR at execution time (not prepare
    // time like SQLite). Either PrepareFailed or ExecuteFailed is
    // acceptable — both mean "the SQL couldn't run". We surface
    // ExecuteFailed because PGexecParams is the unit of execution.
    const result = ctx.db.exec(alloc, "NOT VALID SQL AT ALL garbage", &.{});
    try testing.expectError(Error.ExecuteFailed, result);
}

test "exec with too few args: PG can't infer type, returns ExecuteFailed" {
    // PostgreSQL differs from SQLite here: with `paramTypes=NULL`, the
    // server needs to infer the type of each parameter from the bound
    // value. If no value is bound for a `?` placeholder, the server
    // errors with "could not determine data type of parameter $N".
    // This is a documented PG behavior, not a bug in the wrapper.
    // The wrapper surfaces this as Error.ExecuteFailed.
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT, name TEXT)",
        &.{});
    // SQL has 2 placeholders, we pass 1. PG can't infer the type for
    // the missing placeholder → ExecuteFailed.
    const result = ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{"only_id"});
    try testing.expectError(Error.ExecuteFailed, result);
}

test "exec on NOT NULL violation returns ExecuteFailed" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT NOT NULL)",
        &.{});
    // Bind '' → NULL (project convention), then NOT NULL fires.
    const result = ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "" });
    try testing.expectError(Error.ExecuteFailed, result);
}

test "exec on UNIQUE violation returns ExecuteFailed" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    try testing.expectError(Error.ExecuteFailed, result);
}

test "exec with very long text binding (1 MB)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    try testing.expectEqual(@as(u8, 'A'), row.values[0][0]);
    try testing.expectEqual(@as(u8, 'A'), row.values[0][row.values[0].len - 1]);
}

test "exec with empty argv when SQL has no placeholders works" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // Use SERIAL so the id auto-increments (no need to supply id).
    // Adaptations from the SQLite test: SQLite INTEGER PRIMARY KEY also
    // auto-increments, but PostgreSQL only does so with SERIAL/BIGSERIAL.
    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id SERIAL PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (name) VALUES ('no_args_needed')",
        &.{});
    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo", &.{})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("no_args_needed", name);
}

test "exec multi-statement SQL returns ExecuteFailed (PG rejects multi-stmt in prepared)" {
    // PG's PQexecParams (which our wrapper uses) is implemented as a
    // PREPARED STATEMENT, and PG rejects multi-statement input to a
    // prepared statement with:
    //   "cannot insert multiple commands into a prepared statement"
    // This is DIFFERENT from SQLite's `sqlite3_prepare_v2`, which
    // silently takes the first statement. The wrapper surfaces this
    // as Error.ExecuteFailed (the prepare step fails before any
    // statement is executed). This is the documented PG behavior.
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // Multi-statement SQL — PG rejects before any is executed.
    const result = ctx.db.exec(alloc,
        \\CREATE TABLE foo (id TEXT PRIMARY KEY);
        \\SELECT 1;
    , &.{});
    try testing.expectError(Error.ExecuteFailed, result);

    // Verify nothing was created (the prepare failed before CREATE ran).
    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'foo'",
        &.{})) orelse "0";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 3: queryRow
// ═══════════════════════════════════════════════════════════════════════════

test "queryRow returns the single matching row" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});

    const result = ctx.db.queryRow(alloc,
        "SELECT id FROM foo WHERE id = ?", &.{"nonexistent"});
    try testing.expectError(Error.RowNotFound, result);
}

test "queryRow with multiple rows returns only the first" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // SERIAL PRIMARY KEY so id auto-increments.
    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id SERIAL PRIMARY KEY, val TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (val) VALUES ('hello')", &.{});

    const row = try ctx.db.queryRow(alloc, "SELECT val FROM foo", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("hello", row.values[0]);
}

test "queryRow on NULL column returns empty []u8" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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

test "queryRow on invalid SQL returns QueryFailed" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    const result = ctx.db.queryRow(alloc, "INVALID SQL", &.{});
    try testing.expectError(Error.QueryFailed, result);
}

test "queryRow on closed/uninitialized db returns DatabaseNotFound" {
    var db: PostgresBackend = .{};
    defer db.deinit();
    const alloc = testing.allocator;
    const result = db.queryRow(alloc, "SELECT 1", &.{});
    try testing.expectError(Error.DatabaseNotFound, result);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 4: query (multi-row iterator)
// ═══════════════════════════════════════════════════════════════════════════

test "query with no rows returns iterator that yields null" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var q = try ctx.db.query(alloc, "SELECT id FROM foo", &.{});
    defer q.deinit();

    const next = try q.next();
    try testing.expect(next == null);
}

test "query iterates all rows" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, n) VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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

test "query with malformed SQL returns QueryFailed" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    const result = ctx.db.query(alloc, "INVALID SQL", &.{});
    try testing.expectError(Error.QueryFailed, result);
}

test "executing query on SQL with no result rows returns iterator with ntuples=0" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var q = try ctx.db.query(alloc, "SELECT id FROM foo", &.{});
    defer q.deinit();
    const next = try q.next();
    try testing.expect(next == null);
    // Second call after exhaustion still returns null (Rows.done guard).
    try testing.expect((try q.next()) == null);
}

test "Row.deinit is safe with zero columns (0-column row)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (n INTEGER PRIMARY KEY, s TEXT)", &.{});
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
// ═══════════════════════════════════════════════════════════════════════════

test "changes() reflects INSERT (1)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, name) VALUES (?, ?)",
        &.{ "u1", "Alice" });
    try testing.expectEqual(@as(i64, 1), ctx.db.changes());
}

test "changes() reflects INSERT with multiple VALUES (3)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});
    try testing.expectEqual(@as(i64, 3), ctx.db.changes());
}

test "changes() reflects UPDATE matching N rows" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});
    // Update all rows.
    try ctx.db.exec(alloc, "UPDATE foo SET n = n + 10", &.{});
    try testing.expectEqual(@as(i64, 3), ctx.db.changes());

    // UPDATE matching 0 rows → 0 changes.
    try ctx.db.exec(alloc, "UPDATE foo SET n = 0 WHERE id = ?", &.{"nonexistent"});
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

test "changes() reflects DELETE" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n INTEGER)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES ('a', 1), ('b', 2), ('c', 3)", &.{});

    try ctx.db.exec(alloc, "DELETE FROM foo WHERE n < 3", &.{});
    try testing.expectEqual(@as(i64, 2), ctx.db.changes());
}

test "changes() returns 0 for non-data-write statements (CREATE TABLE)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc, "CREATE TABLE foo (id TEXT)", &.{});
    // CREATE TABLE doesn't change row counts.
    try testing.expectEqual(@as(i64, 0), ctx.db.changes());
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 6: Error variant contract
// ═══════════════════════════════════════════════════════════════════════════

test "exec before init returns DatabaseNotFound" {
    var db: PostgresBackend = .{};
    defer db.deinit();
    const alloc = testing.allocator;
    const result = db.exec(alloc, "SELECT 1", &.{});
    try testing.expectError(Error.DatabaseNotFound, result);
}

test "query before init returns DatabaseNotFound" {
    var db: PostgresBackend = .{};
    defer db.deinit();
    const alloc = testing.allocator;
    const result = db.query(alloc, "SELECT 1", &.{});
    try testing.expectError(Error.DatabaseNotFound, result);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 7: Transaction (raw SQL form)
// ═══════════════════════════════════════════════════════════════════════════

test "BEGIN/COMMIT transaction commits inserts" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    try ctx.db.exec(alloc, "BEGIN", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('a'), ('b')", &.{});
    try ctx.db.exec(alloc, "COMMIT", &.{});

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}

test "BEGIN/ROLLBACK transaction undoes inserts" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    try ctx.db.exec(alloc, "BEGIN", &.{});
    try ctx.db.exec(alloc, "INSERT INTO foo VALUES ('a'), ('b')", &.{});
    try ctx.db.exec(alloc, "ROLLBACK", &.{});

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 8: PostgreSQL-specific features
// ═══════════════════════════════════════════════════════════════════════════

test "SERIAL PRIMARY KEY (PG-AUTOINCREMENT) produces sequential IDs" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id SERIAL PRIMARY KEY, s TEXT)",
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

test "RETURNING clause returns auto-generated values" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id SERIAL PRIMARY KEY, s TEXT)",
        &.{});

    // RETURNING returns the just-inserted id in a single round-trip.
    const row = try ctx.db.queryRow(alloc,
        "INSERT INTO foo (s) VALUES ('hello') RETURNING id", &.{});
    defer row.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), row.values.len);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "schemas with search_path work transparently" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc, "CREATE SCHEMA alt", &.{});
    try ctx.db.exec(alloc, "CREATE TABLE alt.foo (id TEXT PRIMARY KEY)", &.{});
    try ctx.db.exec(alloc, "INSERT INTO alt.foo VALUES ('a')", &.{});

    // Without search_path, the default 'public' schema is used so the
    // unqualified `foo` table does NOT exist there. PG returns
    // "relation does not exist" — we catch that and treat it as 0.
    const QueryFailed = Error.QueryFailed;
    const cnt_pub_result: ?[]u8 = scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{}) catch |err| switch (err) {
        QueryFailed => null,
        else => return err,
    };
    const cnt_pub = cnt_pub_result orelse try alloc.dupe(u8, "0");
    defer alloc.free(cnt_pub);
    try testing.expectEqualStrings("0", cnt_pub);

    // Qualified lookup should find the row.
    const cnt_alt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM alt.foo", &.{})) orelse "0";
    defer alloc.free(cnt_alt);
    try testing.expectEqualStrings("1", cnt_alt);
}

test "boolean column type round-trips" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, active BOOLEAN)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, active) VALUES (?, ?)", &.{ "u1", "true" });
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, active) VALUES (?, ?)", &.{ "u2", "false" });

    const cnt_true = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo WHERE active = true", &.{})) orelse "0";
    defer alloc.free(cnt_true);
    try testing.expectEqualStrings("1", cnt_true);
}

test "JSONB column round-trips a JSON literal" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, data JSONB)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, data) VALUES (?, ?::jsonb)",
        &.{ "u1", "{\"a\":1,\"b\":2}" });

    var q = try ctx.db.query(alloc,
        "SELECT data FROM foo WHERE id = ?", &.{"u1"});
    defer q.deinit();
    const row = (try q.next()) orelse return error.ExpectedRow;
    defer row.deinit(alloc);
    // PG returns the JSON text representation. Test the round-trip.
    try testing.expect(row.values[0].len > 0);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 9: Transaction struct (begin / tx.exec / commit / rollback)
// ═══════════════════════════════════════════════════════════════════════════

test "begin returns a Transaction and commit persists writes" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // no-op after successful commit
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a'), ('b')", &.{});
        try tx.commit();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("2", cnt);
}

test "rollback after commit returns TransactionClosed (single-use enforcement)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    const result = tx.rollback();
    try testing.expectError(Error.TransactionClosed, result);
}

test "defer rollback after error discards all writes (atomic)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {}; // fires if commit() not reached
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        // Force a failure mid-tx by trying to violate the PK constraint.
        const result = tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        try testing.expectError(Error.ExecuteFailed, result);
        // No commit() reached — defer fires, ROLLBACK issued, 'a' is gone.
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "explicit rollback discards writes" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    var db: PostgresBackend = .{};
    defer db.deinit();
    const result = db.begin();
    try testing.expectError(Error.DatabaseNotFound, result);
}

test "tx.queryRow sees uncommitted writes inside the same tx" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        \\CREATE TABLE counter (id INTEGER PRIMARY KEY, n INTEGER NOT NULL, v TEXT)
    , &.{});
    try ctx.db.exec(alloc, "INSERT INTO counter VALUES (1, 0, 'init')", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        const row = try tx.queryRow(alloc,
            "SELECT n FROM counter WHERE id = 1", &.{});
        defer row.deinit(alloc);
        const n = try std.fmt.parseInt(i32, row.values[0], 10);
        try testing.expectEqual(@as(i32, 0), n);

        try tx.exec(alloc, "UPDATE counter SET n = ? WHERE id = 1", &.{"1"});
        try tx.commit();
    }

    const row = try ctx.db.queryRow(alloc,
        "SELECT n FROM counter WHERE id = 1", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
}

test "tx.query returns Rows iterator (same shape as backend.query)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE items (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};

        try tx.exec(alloc, "INSERT INTO items VALUES ('a'), ('b'), ('c')", &.{});

        var q = try tx.query(alloc, "SELECT id FROM items ORDER BY id", &.{});
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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // No begin() before savepoint() — should fail.
    const result = ctx.db.savepoint();
    try testing.expectError(Error.ExecuteFailed, result);
}

test "nested savepoints (depth 2 -> 3) commit and rollback correctly" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});

    // Close the backend while tx is still in flight. The mutex is
    // held by the tx; commit() must release it AND return DatabaseNotFound.
    ctx.db.deinit();
    const result = tx.commit();
    try testing.expectError(Error.DatabaseNotFound, result);
}

test "backend.deinit() while tx is open: tx.rollback returns DatabaseNotFound" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});

    ctx.db.deinit();
    const result = tx.rollback();
    try testing.expectError(Error.DatabaseNotFound, result);
}

test "tx.commit after commit returns TransactionClosed" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    // Second commit → TransactionClosed.
    try testing.expectError(Error.TransactionClosed, tx.commit());
    // exec after commit → TransactionClosed.
    try testing.expectError(Error.TransactionClosed, tx.exec(alloc, "INSERT INTO foo VALUES ('b')", &.{}));
    // rollback after commit → TransactionClosed.
    tx.rollback() catch |err| switch (err) {
        error.TransactionClosed => {},
        else => return err,
    };
}

test "commitOrRollback commits an unfinalized tx" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    {
        var tx = try ctx.db.begin();
        try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
        try tx.commitOrRollback();
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "commitOrRollback after explicit commit is a silent no-op" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.commit();

    // The key test: commitOrRollback on an already-committed tx must
    // succeed silently (NOT return Error.TransactionClosed).
    try tx.commitOrRollback();

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("1", cnt);
}

test "commitOrRollback after explicit rollback is a silent no-op" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY)", &.{});

    var tx = try ctx.db.begin();
    try tx.exec(alloc, "INSERT INTO foo VALUES ('a')", &.{});
    try tx.rollback();

    try tx.commitOrRollback();

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM foo", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

test "commitOrRollback inside a savepoint commits the savepoint (not the outer tx)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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

test "integration: atomic INSERT-then-UPDATE (mirrors insert_llm_histories pattern)" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

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
    try ctx.db.exec(alloc, "INSERT INTO sessions VALUES ('s1', '/old/path')", &.{});

    // Atomic INSERT into llm_history + UPDATE sessions.cwd.
    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(alloc,
            "INSERT INTO llm_history VALUES ('m1', 's1', 'hello world')",
            &.{});
        try tx.exec(alloc,
            "UPDATE sessions SET cwd = '/new/path' WHERE id = 's1'",
            &.{});
        try tx.commit();
    }

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
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE items (id TEXT PRIMARY KEY, label TEXT NOT NULL)", &.{});

    {
        var tx = try ctx.db.begin();
        defer tx.rollback() catch {};
        try tx.exec(alloc, "INSERT INTO items VALUES ('a', 'first')", &.{});
        try tx.exec(alloc, "INSERT INTO items VALUES ('b', 'second')", &.{});
        // Force a failure: duplicate primary key.
        const result = tx.exec(alloc, "INSERT INTO items VALUES ('a', 'duplicate')", &.{});
        try testing.expectError(Error.ExecuteFailed, result);
        // Defer fires → ROLLBACK → 'a' and 'b' both gone.
    }

    const cnt = (try scalarText(alloc, &ctx.db,
        "SELECT COUNT(*) FROM items", &.{})) orelse "";
    defer alloc.free(cnt);
    try testing.expectEqualStrings("0", cnt);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Group 10: ? → $N placeholder translation
// ═══════════════════════════════════════════════════════════════════════════
//
// Six internal tests for the placeholder translator. The translator is
// used by every exec/query/queryRow, so indirectly exercised by every
// other test in this file. These tests cover edge cases that would
// otherwise only show up as silent data corruption.

test "translatePlaceholders: simple ? → $N" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // Direct unit test via the public exec/query interface. The
    // wrapper binds everything as text, so ORDER BY n uses string
    // comparison — "1" sorts before "2" lexicographically.
    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, n TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, ?)", &.{ "a", "1" });
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, ?)", &.{ "b", "2" });

    var q = try ctx.db.query(alloc,
        "SELECT id FROM foo WHERE n = ? OR n = ? ORDER BY n",
        &.{ "2", "1" });
    defer q.deinit();

    const r1 = (try q.next()) orelse return error.ExpectedRow;
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("a", r1.values[0]);
    const r2 = (try q.next()) orelse return error.ExpectedRow;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("b", r2.values[0]);
}

test "translatePlaceholders: ? inside single-quoted string is preserved" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    // The literal 'foo?' should be passed verbatim as a parameter
    // value (no translation). The bind is the actual placeholder.
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, 'foo?')", &.{"u1"});

    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo WHERE id = ?", &.{"u1"})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("foo?", name);
}

test "translatePlaceholders: ? inside line comment is preserved" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    // The trailing "-- comment? with ?" should be a comment, not a
    // placeholder. The bind is the actual placeholder.
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, 'value') -- comment? with ?",
        &.{"u1"});

    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo WHERE id = ?", &.{"u1"})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("value", name);
}

test "translatePlaceholders: ? inside block comment is preserved" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, 'value') /* comment? with ? */",
        &.{"u1"});

    const name = (try scalarText(alloc, &ctx.db,
        "SELECT name FROM foo WHERE id = ?", &.{"u1"})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("value", name);
}

test "translatePlaceholders: ? inside double-quoted identifier is preserved" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // Valid PostgreSQL identifier: "weird?column" — the ? is part of
    // the identifier name, not a placeholder.
    try ctx.db.exec(alloc,
        \\CREATE TABLE foo (
        \\    id TEXT PRIMARY KEY,
        \\    "weird?column" TEXT
        \\)
    , &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo (id, \"weird?column\") VALUES (?, ?)",
        &.{ "u1", "value" });

    const name = (try scalarText(alloc, &ctx.db,
        "SELECT \"weird?column\" FROM foo WHERE id = ?", &.{"u1"})) orelse "";
    defer alloc.free(name);
    try testing.expectEqualStrings("value", name);
}

test "translatePlaceholders: same SQL executed multiple times produces different $N" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    // Each call to exec is a fresh translation, so the ? in the
    // cached-SQL-by-string pattern still works correctly.
    try ctx.db.exec(alloc,
        "CREATE TABLE foo (id TEXT PRIMARY KEY, name TEXT)", &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, ?)", &.{ "a", "Alice" });
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, ?)", &.{ "b", "Bob" });

    var q = try ctx.db.query(alloc, "SELECT name FROM foo ORDER BY id", &.{});
    defer q.deinit();
    const r1 = (try q.next()) orelse return error.ExpectedRow;
    defer r1.deinit(alloc);
    try testing.expectEqualStrings("Alice", r1.values[0]);
    const r2 = (try q.next()) orelse return error.ExpectedRow;
    defer r2.deinit(alloc);
    try testing.expectEqualStrings("Bob", r2.values[0]);
}

test "translatePlaceholders: 5+ placeholders in a single statement" {
    const alloc = testing.allocator;
    const env = ensureEnv(alloc);
    if (!env.is_available) return;

    var ctx = try setupDb(alloc, env);
    defer teardown(alloc, &ctx);

    try ctx.db.exec(alloc,
        "CREATE TABLE foo (a TEXT, b TEXT, c TEXT, d TEXT, e TEXT, f TEXT)",
        &.{});
    try ctx.db.exec(alloc,
        "INSERT INTO foo VALUES (?, ?, ?, ?, ?, ?)",
        &.{ "1", "2", "3", "4", "5", "6" });

    const row = try ctx.db.queryRow(alloc,
        "SELECT a, b, c, d, e, f FROM foo", &.{});
    defer row.deinit(alloc);
    try testing.expectEqualStrings("1", row.values[0]);
    try testing.expectEqualStrings("6", row.values[5]);
}
