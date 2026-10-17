# ruangsql

> WARNING: This repo is AI slop and experimental, DO NOT USE IN PRODUCTION!!!!!!

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

## PostgreSQL backend

Compiled only with `-Ddb_used=sqlite,postgres`. Same API and `Error` set as the SQLite
backend, so `database.Db` stays swappable.

- **Statements are prepared once per connection.** The first call with a given SQL text
  `PQprepare`s it and later calls `PQexecPrepared` it, so PostgreSQL parses and plans it
  once instead of on every call. Anything PostgreSQL refuses to prepare — a
  multi-statement string, a parameter type it cannot infer — falls back to
  `PQexecParams`, and the refusal is remembered per connection.
  `STMT_CACHE_SIZE` statements are cached per connection; `preparedStatements()`
  reports the count.
- **Statements run on a connection pool.** `Config.conns` (default 7) connections are
  pre-warmed at `init`; the pool grows to `Config.max_conns` (default 32, 0 =
  unlimited) and shrinks back to the warm floor after `Config.max_idle_time_ms` idle.
  A statement that finds every connection busy waits `Config.conn_wait_ms` and then
  runs on the primary connection, which `readFallbackCount()` counts.
  `Config.conns = 0` keeps every statement on one connection, like the SQLite backend
  with `read_conns = 0`.
- **Transactions stay on the primary connection**, held for the whole transaction, so a
  `db.exec()` issued while one is open runs on a pooled connection — outside it.

Set both backends' policies in one call:

```zig
try database.openConfigured(&db, io, .{ .postgres_conninfo = url }, .{
    .postgres = .{ .conns = 7, .max_conns = 32 },
});
```

`database.open` and `database.openWithConfig` are unchanged; the SQLite policy the
latter takes is still ignored on a postgres build.

## Testing

```sh
zig build test                                  # sqlite-only (default, no libpq needed)
zig build test -Ddb_used=sqlite,postgres        # also compiles + runs postgres tests
zig build test -Dforce-vendor=true              # force the vendored amalgamation path
```

Postgres tests need a live server; without one they self-skip (pass with
no assertions) via `test_helpers.getOrStartTestInstance`. CI provides a
postgres service on Ubuntu for real coverage.

## Lint

Every `.zig` file in the package is checked by **zginlint**
([github.com/ginwa123/zglint](https://github.com/ginwa123/zglint)), a
std-only linter pinned by URL + hash in `build.zig.zon`:

```sh
zig build zginlint        # install the CLI into zig-out/bin/zginlint
zig build zginlint:check  # the gate: src + bench + build.zig, zero findings
```

Two rules run, both at zero tolerance — there is no baseline, no per-file
ceiling and no suppression comment:

- `zginlint/max-comment-lines` — a **comment block** (a run of consecutive
  comment-only lines) may be at most **2 lines**. `///` doc comments and
  `//!` container docs count like any other comment; a blank line or a line
  carrying code ends the block, and a trailing comment after code is never
  counted.
- `zginlint/no-catch-unreachable` — the banned `catch` + `unreachable`
  pair, which panics without a message in Debug/ReleaseSafe and is
  undefined behaviour in ReleaseFast. Use `catch @panic("...")` instead.
  The scan is over raw bytes, so even a prose mention of the pair inside
  a scanned path counts as a finding.

CI runs the same gate as the `zginlint` job, so a comment block over the
ceiling fails the build instead of drifting back in.
