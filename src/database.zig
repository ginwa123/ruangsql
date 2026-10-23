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

const pg_temp_db = if (build_options.enable_postgres)
    @import("postgres/temp_db.zig")
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

/// Open `db` with an explicit SQLite connection policy. `sqlite_config` is IGNORED on the postgres backend (no pragmas), which is what keeps call sites
/// compiling under both. Prefer `openConfigured` whenever the backend may be postgres: this entry point cannot reach it at all.
pub fn openWithConfig(db: *Db, io: std.Io, cfg: OpenConfig, sqlite_config: SqliteConfig) Error!void {
    return openConfigured(db, io, cfg, .{ .sqlite = sqlite_config });
}

/// The postgres connection policy, re-exported like `SqliteConfig`. A sqlite-only build resolves it
/// to an empty struct: the module that defines the real one is not compiled in.
pub const PostgresConfig = if (backend_is_postgres) postgres_mod.Config else struct {};

/// Both backends' policies at once. The one that does not match the compiled backend is IGNORED, so a
/// call site stays identical whichever `-Ddb_used` list the app was built with.
pub const Config = struct {
    sqlite: SqliteConfig = .{},
    postgres: PostgresConfig = .{},
};

/// Open `db` with both backends' policies — `openWithConfig` generalised.
pub fn openConfigured(db: *Db, io: std.Io, cfg: OpenConfig, config: Config) Error!void {
    if (backend_is_postgres) {
        switch (cfg) {
            .sqlite_path => unreachable, // `-Ddb_used` said postgres; a sqlite path cannot arrive here
            .postgres_conninfo => |c| try db.initWithConfig(io, c, config.postgres),
        }
    } else {
        switch (cfg) {
            .sqlite_path => |p| try db.initWithConfig(io, p, config.sqlite),
            .postgres_conninfo => unreachable,
        }
    }
}

/// A disposable database plus the `std.Io` runtime that serves it. `deinit()` closes
/// the backend and, on postgres, drops the database again; it is safe to call twice.
pub const TempDb = struct {
    db: Db,
    threaded: std.Io.Threaded,
    /// Owned name of the database: `:memory:` on sqlite, `ruangsql_pg_test_<tid>_<n>` on postgres.
    db_name: []u8,
    /// Conninfo of the instance the database lives on; empty on sqlite.
    base_conninfo: []const u8,
    allocator: std.mem.Allocator,
    live: bool = true,

    pub fn deinit(self: *TempDb) void {
        if (!self.live) return;
        self.live = false;

        self.db.deinit();
        self.threaded.deinit();
        dropTempDatabase(self);
        self.allocator.free(self.db_name);
    }
};

const dropTempDatabase = if (backend_is_postgres) dropPostgresTempDatabase else dropNoTempDatabase;

fn dropPostgresTempDatabase(temp: *TempDb) void {
    pg_temp_db.dropDatabase(temp.allocator, temp.base_conninfo, temp.db_name);
}

fn dropNoTempDatabase(temp: *TempDb) void {
    _ = temp;
}

/// Knobs for `createTempDb`. The half that belongs to the backend NOT compiled in is
/// ignored, so the same call site compiles under either `-Ddb_used` list.
pub const TempDbOptions = struct {
    /// Postgres only: the instance to CREATE DATABASE on. null = `POSTGRES_TEST_CONNINFO`, else the built-in local default.
    base_conninfo: ?[:0]const u8 = null,
    config: Config = .{},
};

/// Create a database this caller owns outright, whichever backend was compiled in:
/// sqlite opens a private `:memory:` database, postgres CREATEs a uniquely named one.
pub fn createTempDb(allocator: std.mem.Allocator, options: TempDbOptions) Error!TempDb {
    return createTempDbFor(allocator, options);
}

const createTempDbFor = if (backend_is_postgres) createTempDbPostgres else createTempDbSqlite;

fn createTempDbSqlite(allocator: std.mem.Allocator, options: TempDbOptions) Error!TempDb {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();

    const db_name = try allocator.dupe(u8, ":memory:");
    errdefer allocator.free(db_name);

    var cfg = options.config.sqlite;
    if (cfg.allocator == null) cfg.allocator = allocator;

    var db: Db = .{};
    errdefer db.deinit();
    try db.initWithConfig(threaded.io(), ":memory:", cfg);

    return .{
        .db = db,
        .threaded = threaded,
        .db_name = db_name,
        .base_conninfo = "",
        .allocator = allocator,
    };
}

fn createTempDbPostgres(allocator: std.mem.Allocator, options: TempDbOptions) Error!TempDb {
    var threaded = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();

    const base_conninfo = options.base_conninfo orelse pg_temp_db.resolveBaseConninfo();
    const db_name = try pg_temp_db.uniqueDbName(allocator);
    errdefer allocator.free(db_name);

    try pg_temp_db.createDatabase(allocator, base_conninfo, db_name);
    errdefer pg_temp_db.dropDatabase(allocator, base_conninfo, db_name);

    const db_conninfo = try pg_temp_db.buildDbConninfo(allocator, base_conninfo, db_name);
    defer allocator.free(db_conninfo);

    var cfg = options.config.postgres;
    if (cfg.allocator == null) cfg.allocator = allocator;

    var db: Db = .{};
    errdefer db.deinit();
    try db.initWithConfig(threaded.io(), db_conninfo, cfg);

    return .{
        .db = db,
        .threaded = threaded,
        .db_name = db_name,
        .base_conninfo = base_conninfo,
        .allocator = allocator,
    };
}

/// Whether `createTempDb` can work here: always true on sqlite, one connect attempt
/// on postgres. A test suite calls it to skip itself instead of failing.
pub fn tempDbAvailable() bool {
    return tempDbAvailableFor();
}

const tempDbAvailableFor = if (backend_is_postgres) tempDbAvailablePostgres else tempDbAvailableSqlite;

fn tempDbAvailableSqlite() bool {
    return true;
}

fn tempDbAvailablePostgres() bool {
    return pg_temp_db.probe(pg_temp_db.resolveBaseConninfo());
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
