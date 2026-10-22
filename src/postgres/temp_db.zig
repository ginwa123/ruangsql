//! Temp-database primitives for the PostgreSQL backend: which instance to use, how to
//! CREATE / DROP one unique database, and how to point a conninfo at it.

const std = @import("std");
const PostgresBackend = @import("Postgres.zig").PostgresBackend;
const Error = @import("Postgres.zig").Error;

/// Instance used when the caller names none and `POSTGRES_TEST_CONNINFO` is unset.
pub const DEFAULT_CONNINFO = "host=/tmp port=54329 user=ginwa dbname=postgres";

const ENV_CONNINFO = "POSTGRES_TEST_CONNINFO";

/// The instance a temp database is created on: `POSTGRES_TEST_CONNINFO`, else
/// `DEFAULT_CONNINFO`. The span borrows process environ, so nothing is freed.
pub fn resolveBaseConninfo() [:0]const u8 {
    const raw = std.c.getenv(ENV_CONNINFO) orelse return DEFAULT_CONNINFO;
    return std.mem.span(raw);
}

/// One connect attempt against `conninfo`: true when the server accepted it.
pub fn probe(conninfo: [:0]const u8) bool {
    const conn = PostgresBackend.c.PQconnectdb(conninfo.ptr);
    defer if (conn) |c| PostgresBackend.c.PQfinish(c);
    if (conn == null) return false;
    return PostgresBackend.c.PQstatus(conn) == PostgresBackend.c.CONNECTION_OK;
}

var g_db_counter: u64 = 0;

/// Monotonic per-process suffix source; `uniqueDbName` pairs it with the tid so
/// concurrent callers never collide.
pub fn nextDbCounter() u64 {
    return @atomicRmw(u64, &g_db_counter, .Add, 1, .seq_cst);
}

/// A fresh database name this process has not used before.
pub fn uniqueDbName(allocator: std.mem.Allocator) Error![]u8 {
    const tid: u64 = @intCast(std.os.linux.gettid());
    return std.fmt.allocPrint(allocator, "ruangsql_pg_test_{x}_{x}", .{ tid, nextDbCounter() });
}

/// CREATE DATABASE over a throwaway admin connection; on failure nothing was created
/// and the caller still owns `db_name`.
pub fn createDatabase(allocator: std.mem.Allocator, admin_conninfo: []const u8, db_name: []const u8) Error!void {
    const admin_conn = PostgresBackend.c.PQconnectdb(admin_conninfo.ptr);
    defer if (admin_conn) |c| PostgresBackend.c.PQfinish(c);
    if (admin_conn == null) return Error.DatabaseNotFound;
    if (PostgresBackend.c.PQstatus(admin_conn) != PostgresBackend.c.CONNECTION_OK) {
        return Error.DatabaseNotFound;
    }

    const sql = try std.fmt.allocPrint(allocator, "CREATE DATABASE {s}", .{db_name});
    defer allocator.free(sql);
    const sql_z = try allocator.allocSentinel(u8, sql.len, 0);
    defer allocator.free(sql_z);
    @memcpy(sql_z, sql);

    const result = PostgresBackend.c.PQexec(admin_conn, sql_z.ptr);
    defer if (result) |r| PostgresBackend.c.PQclear(r);
    if (result == null) return Error.ExecuteFailed;
    if (PostgresBackend.c.PQresultStatus(result) != PostgresBackend.c.PGRES_COMMAND_OK) {
        std.log.warn("CREATE DATABASE failed: {s}", .{PostgresBackend.c.PQresultErrorMessage(result)});
        return Error.ExecuteFailed;
    }
}

/// `DROP DATABASE IF EXISTS ... WITH (FORCE)`; never fails the caller — connect and
/// drop errors are logged and swallowed, because the test has already finished.
pub fn dropDatabase(allocator: std.mem.Allocator, admin_conninfo: []const u8, db_name: []const u8) void {
    const admin_conn = PostgresBackend.c.PQconnectdb(admin_conninfo.ptr);
    defer if (admin_conn) |c| PostgresBackend.c.PQfinish(c);
    if (admin_conn == null) return;
    if (PostgresBackend.c.PQstatus(admin_conn) != PostgresBackend.c.CONNECTION_OK) return;

    const sql = std.fmt.allocPrint(allocator, "DROP DATABASE IF EXISTS {s} WITH (FORCE)", .{db_name}) catch return;
    defer allocator.free(sql);
    const sql_z = allocator.allocSentinel(u8, sql.len, 0) catch return;
    defer allocator.free(sql_z);
    @memcpy(sql_z, sql);

    const result = PostgresBackend.c.PQexec(admin_conn, sql_z.ptr);
    defer if (result) |r| PostgresBackend.c.PQclear(r);
    if (result) |r| {
        if (PostgresBackend.c.PQresultStatus(r) != PostgresBackend.c.PGRES_COMMAND_OK) {
            std.log.warn("DROP DATABASE WITH (FORCE) failed: {s}", .{PostgresBackend.c.PQresultErrorMessage(r)});
        }
    }
}

/// Strip any `dbname=` from `base` and append `dbname=<wanted>`, NUL-terminated for libpq.
pub fn buildDbConninfo(allocator: std.mem.Allocator, base: []const u8, wanted: []const u8) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < base.len) {
        var end = i;
        while (end < base.len and base[end] != ' ') end += 1;
        const token = base[i..end];
        // libpq lets the last `dbname=` win, so dropping the old one is only about readability.
        if (!std.mem.startsWith(u8, token, "dbname=")) {
            if (out.items.len > 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, token);
        }
        i = end;
        while (i < base.len and base[i] == ' ') i += 1;
    }

    if (out.items.len > 0) try out.append(allocator, ' ');
    try out.appendSlice(allocator, "dbname=");
    try out.appendSlice(allocator, wanted);
    try out.append(allocator, 0);
    return out.toOwnedSliceSentinel(allocator, 0);
}
