//! `databases` package — public API root: `@import("databases")` reaches `database` /
//! `sqlite` / `postgres`. build.zig wires the backend deps for the target — consumers must NOT re-link them.

const build_options = @import("build_options");

pub const sqlite = @import("sqlite/Sqlite.zig");

// Only available when the app listed postgres in `-Ddb_used`; otherwise an empty
// stub, so `@import("databases").postgres` still resolves instead of failing the import.
pub const postgres = if (build_options.enable_postgres)
    @import("postgres/Postgres.zig")
else
    struct {};

// Internal helper — re-exported so the package's own test_runner.zig is discovered by
// `zig build test` (and `zig fetch` includes it in the package hash).
pub const test_runner = @import("test_runner.zig");

// Generic database abstraction (currently a thin alias for Sqlite.zig;
// kept as a stable seam so consumers can swap implementations later).
pub const database = @import("database.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
