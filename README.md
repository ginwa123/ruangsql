# ruangsql

Self-contained Zig package exposing the sqlite3 + libpq bindings used by
nalarcore. Extracted from `ginwaaitoolbox/src/modules/databases/`.

Consumers add it via `zig fetch` and wire it with `b.dependency`:

```zig
// build.zig.zon
.dependencies = .{
    .ruangsql = .{
        .url = "https://github.com/ginwa123/ruangsql/archive/<sha>.tar.gz",
        .hash = "<zig-package-hash>",
    },
},
```

```zig
// build.zig
const ruangsql_dep = b.dependency("ruangsql", .{
    .target = target,
    .optimize = optimize,
    // Comma-separated backends: "sqlite" (default, no libpq) or
    // "sqlite,postgres" (also compiles the postgres backend, needs libpq).
    .db_used = "sqlite",
});
mod.addImport("databases", ruangsql_dep.module("databases"));
```

```zig
// source
const database = @import("databases").database; // preferred
const sqlite = @import("databases").sqlite;     // legacy, keep while migrating
const postgres = @import("databases").postgres; // only with -Ddb_used=...,postgres
```

## Layout

- `build.zig` / `build.zig.zon` — package entry (`.name = .databases`,
  Zig `0.16.0`). Probes the host for system sqlite3 / libpq / openssl and
  falls back to the vendored amalgamation.
- `src/root.zig` — public API root.
- `src/database.zig` — unified `Db` interface (compile-time backend choice).
- `src/sqlite/` — `Sqlite.zig` + tests.
- `src/postgres/` — `Postgres.zig`, `test_helpers.zig` + tests.
- `src/test_runner.zig` — aggregates the test suite (`postgres` tests only
  run when `-Ddb_used` includes `postgres`).
- `scripts/fetch-vendor-sqlite3.sh` — downloads the SQLite amalgamation
  into `vendor/sqlite3/` (gitignored). Needed on macOS / Windows and for
  cross-compiles; Linux native builds use system libsqlite3 instead.

## Testing

```sh
zig build test                                  # sqlite-only (default, no libpq needed)
zig build test -Ddb_used=sqlite,postgres        # also compiles + runs postgres tests
zig build test -Dforce-vendor=true              # force the vendored amalgamation path
```

Postgres tests need a live server; without one they self-skip (pass with
no assertions) via `test_helpers.getOrStartTestInstance`. CI provides a
postgres service on Ubuntu for real coverage.
