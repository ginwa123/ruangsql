//! Unified database interface — import this, not `sqlite` / `postgres`. `Db` is
//! picked at COMPILE time from `-Ddb_used`; both backends share one method set and `Error` set by design, so call sites stay duck-typed.

const std = @import("std");
const build_options = @import("build_options");
const sqlite_mod = @import("sqlite/Sqlite.zig");

// Conditional import: sqlite-only builds (the default) resolve this to `struct {}`,
// so the compiler never opens `postgres/Postgres.zig` — no `libpq-fe.h`, no `PQ*` symbols.
const postgres_mod = if (build_options.enable_postgres)
    @import("postgres/Postgres.zig")
else
    struct {};

/// True when the app listed postgres in `-Ddb_used`.
pub const backend_is_postgres: bool = build_options.enable_postgres;

/// The unified backend type — import this, not `SqliteBackend` / `PostgresBackend`:
/// when sqlite-only, `Db` IS `SqliteBackend`, so `*SqliteBackend` signatures keep compiling.
pub const Db = if (backend_is_postgres)
    postgres_mod.PostgresBackend
else
    sqlite_mod.SqliteBackend;

/// Both backends expose identical `Error` sets; either one works as the
/// unified error type.
pub const Error = sqlite_mod.Error;

/// Explicit backend-or-transaction handle (`.{ .db = db }` / `.{ .tx = &tx }`) for
/// helpers that run both outside and inside a tx: dispatch is an exhaustive switch, so misuse fails to compile.
pub const DbOrTx = union(enum) {
    db: *Db,
    tx: *Db.Transaction,

    pub fn exec(
        self: DbOrTx,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!void {
        switch (self) {
            .db => |d| return d.exec(allocator, sql, argv),
            .tx => |t| return t.exec(allocator, sql, argv),
        }
    }

    pub fn query(
        self: DbOrTx,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Db.Rows {
        switch (self) {
            .db => |d| return d.query(allocator, sql, argv),
            .tx => |t| return t.query(allocator, sql, argv),
        }
    }

    pub fn queryRow(
        self: DbOrTx,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Db.Row {
        switch (self) {
            .db => |d| return d.queryRow(allocator, sql, argv),
            .tx => |t| return t.queryRow(allocator, sql, argv),
        }
    }
};

/// Unified open config — hides the path-vs-conninfo `init` gap: only the variant
/// matching the compiled backend is ever constructed; `open()` dispatches at comptime.
pub const OpenConfig = union(enum) {
    sqlite_path: [:0]const u8,
    postgres_conninfo: [:0]const u8,
};

/// Open `db` with the given config — a thin wrapper over the backend's `init`, which
/// both backends take as `(std.Io, [:0]const u8)`, so this inlines to one call.
pub fn open(db: *Db, io: std.Io, cfg: OpenConfig) Error!void {
    switch (cfg) {
        .sqlite_path => |p| try db.init(io, p),
        .postgres_conninfo => |c| try db.init(io, c),
    }
}

/// The SQLite connection policy `openWithConfig` accepts, re-exported so a consumer
/// can name it without reaching into the `sqlite` namespace.
pub const SqliteConfig = sqlite_mod.Config;

/// Open `db` with an explicit SQLite connection policy. `sqlite_config` is IGNORED
/// on the postgres backend (no pragmas), which is what keeps call sites compiling under both.
pub fn openWithConfig(db: *Db, io: std.Io, cfg: OpenConfig, sqlite_config: SqliteConfig) Error!void {
    if (backend_is_postgres) {
        switch (cfg) {
            .sqlite_path => unreachable, // `-Ddb_used` said postgres; a sqlite path cannot arrive here
            .postgres_conninfo => |c| try db.init(io, c),
        }
    } else {
        switch (cfg) {
            .sqlite_path => |p| try db.initWithConfig(io, p, sqlite_config),
            .postgres_conninfo => unreachable,
        }
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "database.Db resolves to the backend the app selected" {
    const testing = @import("std").testing;
    if (backend_is_postgres) {
        try testing.expect(Db == postgres_mod.PostgresBackend);
    } else {
        // Sqlite-only (default): Db IS SqliteBackend, so every existing
        // `*sqlite.SqliteBackend` signature accepts a `*database.Db` untouched.
        try testing.expect(Db == sqlite_mod.SqliteBackend);
    }
}
