//! Unified database interface — import this, not `sqlite` / `postgres`.
//!
//!   const database = @import("databases").database;
//!   var db: database.Db = .{};
//!   try database.open(&db, io, .{ .sqlite_path = db_path });
//!
//! The concrete type behind `Db` is chosen at COMPILE time by the app's
//! root `build.zig` (`-Ddb_used`, default `"sqlite"`). The
//! unchosen backend is never `@import`ed, so its `@cImport` headers and
//! link libs are never needed even though the source stays on disk:
//!
//!   - `-Ddb_used=sqlite` (default): `Db == SqliteBackend`, no libpq.
//!   - `-Ddb_used=sqlite,postgres`:  `Db == PostgresBackend`, needs libpq.
//!
//! Both backends share the same method set (`exec` / `query` / `queryRow`
//! / `changes` / `begin` / `savepoint` / `deinit`) and the same `Error`
//! variants by design (see `postgres/Postgres.zig` header), so call sites
//! stay duck-typed. Only `init` differs (file path vs conninfo) — the
//! `open()` helper below hides that gap behind `OpenConfig`.

const std = @import("std");
const build_options = @import("build_options");
const sqlite_mod = @import("sqlite/Sqlite.zig");

// Conditional import: when the app builds sqlite-only (the default),
// this resolves to `struct {}` and the compiler never opens
// `postgres/Postgres.zig` — no `libpq-fe.h` needed, no `PQ*` symbols.
const postgres_mod = if (build_options.enable_postgres)
    @import("postgres/Postgres.zig")
else
    struct {};

/// True when the app listed postgres in `-Ddb_used`.
pub const backend_is_postgres: bool = build_options.enable_postgres;

/// The unified backend type. Import this, not `SqliteBackend` /
/// `PostgresBackend` directly. When sqlite-only, `Db` IS
/// `SqliteBackend` (same type — existing `*SqliteBackend` signatures
/// keep compiling untouched during migration).
pub const Db = if (backend_is_postgres)
    postgres_mod.PostgresBackend
else
    sqlite_mod.SqliteBackend;

/// Both backends expose identical `Error` sets; either one works as the
/// unified error type.
pub const Error = sqlite_mod.Error;

/// Unified open config — hides the path-vs-conninfo `init` gap.
/// Only the variant matching the compiled backend is ever constructed
/// in practice; `open()` dispatches at comptime to the single `init`
/// signature that exists.
pub const OpenConfig = union(enum) {
    sqlite_path: [:0]const u8,
    postgres_conninfo: [:0]const u8,
};

/// Open `db` with the given config. Thin wrapper over the backend's
/// `init(io, path_or_conninfo)` — both backends take
/// `(std.Io, [:0]const u8)`, so this inlines to a single call.
pub fn open(db: *Db, io: std.Io, cfg: OpenConfig) Error!void {
    switch (cfg) {
        .sqlite_path => |p| try db.init(io, p),
        .postgres_conninfo => |c| try db.init(io, c),
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
        // `*sqlite.SqliteBackend` signature accepts a `*database.Db`
        // untouched during migration.
        try testing.expect(Db == sqlite_mod.SqliteBackend);
    }
}
