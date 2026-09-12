//! `databases` package — public API root.
//!
//! Consumers import as `@import("databases")` (the module name declared
//! in build.zig) and access nested namespaces:
//!
//!   const database = @import("databases").database; // <-- prefer this
//!   var db: database.Db = .{};
//!
//!   const sqlite = @import("databases").sqlite;     // legacy, keep while migrating
//!   const postgres = @import("databases").postgres; // only when listed in -Ddb_used
//!
//! `databases` is a self-contained Zig package — its own build.zig
//! wires sqlite3 / openssl / libpq + vendored sqlite3 amalgamation
//! based on the target the consumer passes via `b.dependency()`.
//! Consumers should NOT re-link these themselves; importing this module
//! pulls in the right deps for the target.
//!
//! Backend choice is app-controlled: the app's root build.zig passes
//! `-Ddb_used` through as `enable-postgres`. The unchosen
//! backend is never `@import`ed (comptime discard), so sqlite-only
//! builds never need libpq headers/libs.

const build_options = @import("build_options");

pub const sqlite = @import("sqlite/Sqlite.zig");

// Only available when the app listed postgres in `-Ddb_used`.
// Otherwise an empty stub so `@import("databases").postgres` still
// resolves (with no `PostgresBackend` inside) instead of failing the
// whole package import.
pub const postgres = if (build_options.enable_postgres)
    @import("postgres/Postgres.zig")
else
    struct {};

// Internal helpers — exposed so the package's own test_runner.zig can
// be discovered by `zig build test`. The root re-export also enables
// `zig fetch` to include the test runner in the package hash.
pub const test_runner = @import("test_runner.zig");

// Generic database abstraction (currently a thin alias for Sqlite.zig;
// kept as a stable seam so consumers can swap implementations later).
pub const database = @import("database.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
