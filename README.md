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
