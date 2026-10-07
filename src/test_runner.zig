const build_options = @import("build_options");

test {
    _ = @import("sqlite/sqlite_test.zig");
    _ = @import("sqlite/sqlite_test_rows_capture_error.zig");
    // WAL writer-slot behaviour: two connections contending for the one
    // write slot a WAL database file allows.
    _ = @import("sqlite/sqlite_lock_test.zig");
    // The transparent fast path: prepared-statement cache, packed rows and
    // reader pooling behind the UNCHANGED exec/query/queryRow contract.
    _ = @import("sqlite/sqlite_fastpath_test.zig");
    // Reader pooling (`Config.read_conns`). Separate from the fastpath
    // file because that one opens `:memory:`, which pooling skips.
    _ = @import("sqlite/sqlite_pool_test.zig");
    // Postgres tests only when the app listed postgres in `-Ddb_used`.
    // They need a live PG server; sqlite-only builds (the default)
    // skip them entirely so `zig build test` works without libpq.
    if (build_options.enable_postgres) {
        _ = @import("postgres/postgres_test.zig");
        _ = @import("postgres/test_helpers_test.zig");
    }
}
