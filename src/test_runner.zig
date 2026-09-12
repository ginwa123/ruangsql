const build_options = @import("build_options");

test {
    _ = @import("sqlite/sqlite_test.zig");
    _ = @import("sqlite/sqlite_test_rows_capture_error.zig");
    // Postgres tests only when the app listed postgres in `-Ddb_used`.
    // They need a live PG server; sqlite-only builds (the default)
    // skip them entirely so `zig build test` works without libpq.
    if (build_options.enable_postgres) {
        _ = @import("postgres/postgres_test.zig");
        _ = @import("postgres/test_helpers_test.zig");
    }
}
