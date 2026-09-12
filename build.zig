//! `databases` package — self-contained Zig package that exposes the
//! sqlite3 + libpq bindings used by nalarcore.
//!
//! Consumers (`b.dependency("databases", .{...})`) get the right sqlite3
//! + openssl + libpq link line + include paths based on the TARGET they
//! pass in. This means a Linux native build, a Linux → Windows cross-
//! compile, and a macOS native build each pick up the correct deps
//! automatically — without the consumer needing to wire per-platform
//! system libraries themselves.
//!
//! Why per-TARGET (not per-Compile from the consumer): the consumer
//! build.zig's `linkPlatformDeps` no longer needs to know about
//! sqlite3 / openssl / libpq. The databases module carries those deps
//! for its own target, and Zig's module-graph dep propagation handles
//! the rest.
//!
//! ## System-deps probe
//!
//! In addition to the vendored sqlite3 amalgamation, this package probes
//! the host system at build config time for sqlite3 + libpq + openssl.
//! If the host has all of them (the normal case on Arch / Debian /
//! Fedora / Ubuntu dev hosts), the package links the system sqlite3 via
//! `linkSystemLibrary("sqlite3")` and skips the 9 MB amalgamation
//! compile entirely. This is what the user asked for: "before use
//! vendor script to build, check the current system deps first, if
//! system have the lib no need use vendor".
//!
//! Override with `-Dforce-vendor=true` to always compile the vendored
//! amalgamation (useful for CI runners + testing the vendored path).

const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform "does this file exist" check used by the system-deps
/// probe below. Earlier revisions ran `sh -c "test -f ..."` here, which
/// is unreliable on Windows dev boxes (Git for Windows ships bash.exe at
/// `C:\Program Files\Git\bin` but doesn't add it to PATH automatically).
/// The probe then silently spawned-failed and fell through to the vendored
/// path even when vcpkg had the libraries installed at
/// `C:\vcpkg\installed\x64-windows\`. Host-OS-specific direct syscalls
/// via `std.os`, NOT `std.c` — build.zig doesn't link libc by default
/// (Zig 0.16 requires an explicit `link_libc = true` on the build runner
/// module for `std.c` to resolve `fopen`).
///
///   - Linux:   `faccessat(AT_FDCWD, path, mode=0)` returns 0 when
///              the file exists.
///   - macOS:   same `faccessat` (POSIX).
///   - Windows: `GetFileAttributesW` returns INVALID_FILE_ATTRIBUTES on
///              missing; existence = attrs != invalid AND attrs doesn't
///              have the DIRECTORY bit set (mirror `test -f`).
fn fileExists(absolute_path: []const u8) bool {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    if (absolute_path.len >= buf.len) return false;
    @memcpy(buf[0..absolute_path.len], absolute_path);
    buf[absolute_path.len] = 0;
    return switch (builtin.os.tag) {
        .linux => blk: {
            const rc = std.os.linux.faccessat(std.os.linux.AT.FDCWD, &buf, 0, 0);
            break :blk rc == 0;
        },
        // macOS: libc `access()` — same F_OK check as `test -f`.
        // (The build runner links libc, so the extern is always
        // resolvable; no shell-out needed. Zig 0.16 removed
        // std.posix.access / made it Io-based, and the old shell-out
        // used std.heap.GeneralPurposeAllocator + a pre-0.16
        // std.process.run signature that no longer compile.)
        .macos => blk: {
            const rc = std.c.access(&buf, 0); // F_OK = 0
            break :blk rc == 0;
        },
        .windows => blk: {
            var wide: [std.fs.max_path_bytes]u16 = undefined;
            const written = std.unicode.wtf8ToWtf16Le(&wide, absolute_path) catch break :blk false;
            if (written >= wide.len) break :blk false;
            wide[written] = 0;
            const attrs = GetFileAttributesW(@ptrCast(&wide));
            if (attrs == INVALID_FILE_ATTRIBUTES) break :blk false;
            if ((attrs & FILE_ATTRIBUTE_DIRECTORY) != 0) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

extern "kernel32" fn GetFileAttributesW(lpPathName: [*:0]const u16) callconv(.winapi) u32;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x00000010;

/// Result of probing the host system for sqlite3 + libpq + openssl.
const SystemLibs = struct {
    /// True when the probe found sqlite3.h AND libsqlite3.so on the host.
    use_system_sqlite3: bool,
    /// True when the probe found libpq-fe.h AND libpq.so on the host.
    use_system_pq: bool,
    /// True when the probe found openssl/ssl.h AND libssl.so on the host.
    use_system_ssl: bool,
    /// True when the probe found openssl/ssl.h AND libcrypto.so on the host.
    use_system_crypto: bool,
};

/// Probe the host system for sqlite3 + libpq + openssl.
///
/// Runs `sh -c` synchronously at build config time (via
/// `std.process.run`) and parses 6 boolean fields out of its stdout.
/// The probe runs in ~25 ms on a typical Linux host — cheap enough
/// to re-run on every `zig build` invocation (no caching needed).
///
/// Only Linux is probed. macOS Homebrew sqlite3 is keg-only; Windows
/// needs explicit .lib paths; both fall back to vendor. Cross-compile
/// (Linux host → Windows target) also falls back to vendor because
/// the probe checks the HOST's system libs, not the TARGET's.
///
/// `target` is the COMPILE's resolved target. Cross-compile always
/// returns "no system libs" because the host's libs are for the host
/// OS, not the target OS.
pub fn probeSystemLibs(b: *std.Build, target: std.Build.ResolvedTarget) SystemLibs {
    // Only native (target == host) goes system-only. Cross-compile
    // (Linux host → macOS target, or vice versa) always falls back
    // to the vendored amalgamation because the host's libs are for
    // the host OS, not the target OS.
    if (target.result.os.tag != b.graph.host.result.os.tag) {
        return .{
            .use_system_sqlite3 = false,
            .use_system_pq = false,
            .use_system_ssl = false,
            .use_system_crypto = false,
        };
    }

    // Linux: libpq-fe.h location varies by distro — Arch Linux has it
    // at /usr/include/libpq-fe.h directly, Debian/Ubuntu at
    // /usr/include/postgresql/libpq-fe.h. Check both.
    //
    // macOS: Homebrew ships keg-only sqlite3 + libpq at
    // /opt/homebrew/opt/<name>/{include,lib}/. There is no ldconfig
    // on macOS — we test the .dylib file directly. The probe accepts
    // either the keg-only path OR the system /usr/include (rare but
    // documented for completeness).
    //
    // Pure-Zig probe (no shell, no `bash`/`sh` dependency). Earlier
    // revisions ran `sh -c "test -f ..."` + `ldconfig -p | grep ...`
    // via `std.process.run`. On Windows dev boxes without `bash`/`sh`
    // on PATH the spawn failed and the probe fell through to "vendor
    // fallback" — which then tried to compile the 9 MB sqlite3.c
    // amalgamation even though vcpkg already had vcpkg-installed
    // sqlite3.lib. Same failure mode as the root build.zig + the
    // kabelweb probe — all three get fixed by the same
    // `fileExists(...)` helper at the top of this file.
    var sqlite_hdr: bool = false;
    var sqlite_lib: bool = false;
    var pq_hdr: bool = false;
    var pq_lib: bool = false;
    var ssl_hdr: bool = false;
    var ssl_lib: bool = false;
    var crypto_lib: bool = false;
    switch (b.graph.host.result.os.tag) {
        .linux => {
            // Debian/Ubuntu use multiarch lib dirs
            // (/usr/lib/<triplet>/...), Arch/Fedora use /usr/lib/ directly.
            // Check both layouts.
            sqlite_hdr = fileExists("/usr/include/sqlite3.h");
            sqlite_lib = fileExists("/usr/lib/libsqlite3.so") or
                fileExists("/usr/lib/x86_64-linux-gnu/libsqlite3.so") or
                fileExists("/usr/lib/aarch64-linux-gnu/libsqlite3.so");
            pq_hdr = fileExists("/usr/include/postgresql/libpq-fe.h") or
                fileExists("/usr/include/libpq-fe.h");
            pq_lib = fileExists("/usr/lib/libpq.so") or
                fileExists("/usr/lib/x86_64-linux-gnu/libpq.so") or
                fileExists("/usr/lib/aarch64-linux-gnu/libpq.so");
            ssl_hdr = fileExists("/usr/include/openssl/ssl.h");
            ssl_lib = fileExists("/usr/lib/libssl.so") or
                fileExists("/usr/lib/x86_64-linux-gnu/libssl.so") or
                fileExists("/usr/lib/aarch64-linux-gnu/libssl.so");
            crypto_lib = fileExists("/usr/lib/libcrypto.so") or
                fileExists("/usr/lib/x86_64-linux-gnu/libcrypto.so") or
                fileExists("/usr/lib/aarch64-linux-gnu/libcrypto.so");
        },
        .macos => {
            // Homebrew formula is `sqlite` (opt dir `sqlite`), not `sqlite3`.
            sqlite_hdr = fileExists("/opt/homebrew/opt/sqlite3/include/sqlite3.h") or
                fileExists("/opt/homebrew/opt/sqlite/include/sqlite3.h") or
                fileExists("/usr/include/sqlite3.h");
            sqlite_lib = fileExists("/opt/homebrew/opt/sqlite3/lib/libsqlite3.dylib") or
                fileExists("/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib") or
                fileExists("/usr/lib/libsqlite3.dylib");
            pq_hdr = fileExists("/opt/homebrew/opt/libpq/include/libpq-fe.h") or
                fileExists("/usr/include/libpq-fe.h");
            pq_lib = fileExists("/opt/homebrew/opt/libpq/lib/libpq.dylib") or
                fileExists("/usr/lib/libpq.dylib");
            ssl_hdr = fileExists("/opt/homebrew/opt/openssl@3/include/openssl/ssl.h") or
                fileExists("/opt/homebrew/opt/openssl/include/openssl/ssl.h") or
                fileExists("/usr/include/openssl/ssl.h");
            ssl_lib = fileExists("/opt/homebrew/opt/openssl@3/lib/libssl.dylib") or
                fileExists("/usr/lib/libssl.dylib");
            crypto_lib = fileExists("/opt/homebrew/opt/openssl@3/lib/libcrypto.dylib") or
                fileExists("/usr/lib/libcrypto.dylib");
        },
        .windows => {
            // Header-only on vcpkg (Windows): lib filenames differ
            // between MSVC and MinGW toolchains — rely on the linker
            // to surface `file not found` if the lib is missing.
            sqlite_hdr = fileExists("C:/vcpkg/installed/x64-windows/include/sqlite3.h");
            pq_hdr = fileExists("C:/vcpkg/installed/x64-windows/include/libpq-fe.h");
            ssl_hdr = fileExists("C:/vcpkg/installed/x64-windows/include/openssl/ssl.h");
        },
        else => {
            sqlite_hdr = false;
            sqlite_lib = false;
            pq_hdr = false;
            pq_lib = false;
            ssl_hdr = false;
            ssl_lib = false;
            crypto_lib = false;
        },
    }

    // Header-only probe on Windows (vcpkg): the package links against the
    // vcpkg sysroot and relies on the linker's search path to find the
    // .lib files. If the lib is missing the linker reports
    // `file not found` with a clear diagnostic. This avoids the
    // per-toolchain lib-name enum (MSVC `sqlite3.lib` vs MinGW
    // `libsqlite3.lib` vs `sqlite3.dll.lib`).
//
// On Linux / macOS we ALSO require the matching .so / .dylib to be
// present — a header-only dev install (sqlite3-dev but no libsqlite3
// runtime) would compile fine but fail at runtime. Cross-checking the
// .so path is a cheap O(1) `faccessat` per probe field and saves the
// consumer from a confusing `dyld: Library not loaded` at first use.
    const use_system_sqlite3 = sqlite_hdr and switch (b.graph.host.result.os.tag) {
        .windows => true,
        else => sqlite_lib,
    };
    const use_system_pq = pq_hdr and switch (b.graph.host.result.os.tag) {
        .windows => true,
        else => pq_lib,
    };
    const use_system_ssl = ssl_hdr and switch (b.graph.host.result.os.tag) {
        .windows => true,
        else => ssl_lib,
    };
    const use_system_crypto = ssl_hdr and switch (b.graph.host.result.os.tag) {
        .windows => true,
        else => crypto_lib,
    };

    std.debug.print(
        "[databases] probe: sqlite3={} libpq={} ssl={} crypto={}\n",
        .{ use_system_sqlite3, use_system_pq, use_system_ssl, use_system_crypto },
    );

    return .{
        .use_system_sqlite3 = use_system_sqlite3,
        .use_system_pq = use_system_pq,
        .use_system_ssl = use_system_ssl,
        .use_system_crypto = use_system_crypto,
    };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Path to the vendored sqlite3 amalgamation, relative to this
    // package's build.zig. Default is `vendor/sqlite3/` co-located with
    // this build.zig (the package owns its own vendor dir — the fetch
    // script at scripts/fetch-vendor-sqlite3.sh populates it).
    // Override with `-Dvendor-dir=...` if you move it elsewhere.
    const vendor_dir = b.option(
        []const u8,
        "vendor-dir",
        "Path to vendor/sqlite3/ (relative to this package, default 'vendor/sqlite3')",
    ) orelse "vendor/sqlite3";

    // Force-use vendor (skip the system probe). Default: false
    // (probe decides).
    const force_vendor = b.option(
        bool,
        "force-vendor",
        "Skip the system probe and always compile the vendored sqlite3 amalgamation",
    ) orelse false;

    // Backend list — set by the app's root build.zig (`-Ddb_used`),
    // forwarded verbatim via `b.dependency("databases", ...)`.
    // Comma-separated (the build runner only passes strings on the
    // CLI — no array-of-string option kind exists). Default `"sqlite"`
    // = sqlite-only: Postgres.zig is never @imported, libpq is never
    // linked, pg tests are skipped. Standalone `zig build test` inside
    // this package also defaults to sqlite-only.
    const db_used_str = b.option(
        []const u8,
        "db_used",
        "Comma-separated database backends to compile: 'sqlite' (default, no libpq), add 'postgres' to also compile postgres (needs libpq)",
    ) orelse "sqlite";
    var enable_postgres = false;
    var db_used_it = std.mem.splitScalar(u8, db_used_str, ',');
    while (db_used_it.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t");
        if (entry.len == 0 or std.mem.eql(u8, entry, "sqlite")) continue;
        if (std.mem.eql(u8, entry, "postgres")) {
            enable_postgres = true;
        } else {
            std.debug.panic("unknown database backend in -Ddb_used='{s}': '{s}' (known: sqlite, postgres)", .{ db_used_str, entry });
        }
    }

    const mod = b.addModule("databases", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Universal: libc is required by every sqlite3 binding + cimport.
    mod.linkSystemLibrary("c", .{});
    mod.link_libc = true;

    // Expose the backend choice to source as `@import("build_options")`.
    // `database.zig` / `root.zig` / `test_runner.zig` read
    // `build_options.enable_postgres` at comptime: the unchosen branch
    // is discarded before `@cImport` runs, so sqlite-only builds never
    // need libpq headers or libs even though Postgres.zig is on disk.
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_postgres", enable_postgres);
    mod.addOptions("build_options", build_options);

    // Probe host system for sqlite3 + libpq + openssl. When the probe
    // finds usable system libs (typical Arch / Debian / Fedora dev
    // hosts), link them and skip the vendored amalgamation entirely.
    // Otherwise fall back to the vendored amalgamation (works on every
    // host with a C compiler).
    const sys = if (force_vendor) SystemLibs{
        .use_system_sqlite3 = false,
        .use_system_pq = false,
        .use_system_ssl = false,
        .use_system_crypto = false,
    } else probeSystemLibs(b, target);

    // sqlite3 header path — needed by `@cImport(@cInclude("sqlite3.h"))`
    // inside src/sqlite/Sqlite.zig. On system path: /usr/include is
    // already on the cimport search path so no addIncludePath needed.
    // On vendor path: the amalgamation co-locates sqlite3.h with the
    // .c file in vendor/sqlite3/, so we add that include path.
    if (!sys.use_system_sqlite3) {
        mod.addIncludePath(b.path(vendor_dir));
    } else {
        // Explicit /usr/include for cimport (most distros have it by
        // default but cross-compile toolchains may not). On macOS we
        // also need the brew keg-only path because the probe accepted
        // either layout.
        //
        // Windows: do NOT add `/usr/include` — it doesn't exist on
        // Windows (vcpkg headers live at C:/vcpkg/installed/x64-windows/
        // include, which the Windows branch below adds separately via
        // `addObjectFile` + the equivalent include path). The previous
        // unconditional `addIncludePath("/usr/include")` made translate-c
        // fail on Windows with `error: the following build command failed
        // with exit code 5` because the path resolves to a non-existent
        // UNC-style `\\usr\include` on Windows hosts (observed on the
        // self-hosted runner after the databases probe started returning
        // `use_system_sqlite3=true` against the vcpkg install).
        if (target.result.os.tag == .macos) {
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite3/include" });
        }
        if (target.result.os.tag == .linux) {
            mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
        }
    }

    // Compile flags mirror the existing project convention:
    //   - SQLITE_THREADSAFE=1       — multi-threaded app, mutexes OK
    //   - SQLITE_OMIT_LOAD_EXTENSION — don't expose the loadable-ext API
    //   - SQLITE_ENABLE_FTS5         — required for the project's FTS5
    //                                  indexes (save_memory, search_history,
    //                                  llm_history)
    const sqlite_c = b.path(b.fmt("{s}/sqlite3.c", .{vendor_dir}));
    const sqlite_flags = &[_][]const u8{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_ENABLE_FTS5",
    };
    switch (target.result.os.tag) {
        .linux => {
            if (sys.use_system_sqlite3) {
                // System sqlite3 — link the shared lib. Don't compile
                // the amalgamation (saves ~3 min on first build +
                // ~10 MB of build artifacts).
                mod.linkSystemLibrary("sqlite3", .{});
            } else {
                // Vendored amalgamation. Compile the .c into every
                // consumer (Zig caches the resulting object file).
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
            // libpq — only when the app opted in via -Ddb_used AND
            // the probe found it. Sqlite-only builds (the default) skip
            // this entirely: no -lpq link, no postgresql include path,
            // even though Postgres.zig stays on disk.
            if (enable_postgres and sys.use_system_pq) {
                mod.linkSystemLibrary("pq", .{});
                // Add both /usr/include and /usr/include/postgresql
                // because Debian/Ubuntu put libpq-fe.h in
                // /usr/include/postgresql while Arch has it directly
                // in /usr/include. Harmless if the other is missing.
                mod.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
            }
            // OpenSSL — only link when system probe finds them. The
            // vendored amalgamation is independent of ssl/crypto
            // (it doesn't pull in TLS), so even if the probe fails for
            // ssl/crypto, the amalgamation still compiles. But we
            // still try to link ssl/crypto when available because the
            // main app's libpq / openssl use depends on them.
            if (sys.use_system_ssl) mod.linkSystemLibrary("ssl", .{});
            if (sys.use_system_crypto) mod.linkSystemLibrary("crypto", .{});
        },
        .macos => {
            // macOS native: prefer the system sqlite3 from Homebrew
            // (keg-only at /opt/homebrew/opt/sqlite3/) when the probe
            // finds it. Otherwise fall back to the vendored
            // amalgamation (works on every host with a C compiler).
            // macOS doesn't currently use libpq or openssl via this
            // package — ssl/crypto are wired only in kabelweb
            // (the libcurl backend needs them for https://).
            if (sys.use_system_sqlite3) {
                mod.linkSystemLibrary("sqlite3", .{});
                mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite3/lib" });
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            } else {
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
        },
        .windows => {
            // Use vcpkg-installed sqlite3 (and libpq/openssl) when the
            // probe finds them. The CI installs them via
            // `vcpkg install --recurse <port>:x64-windows` at
            // `C:/vcpkg/installed/x64-windows/`. This skips the
            // vendored-amalgamation path entirely — the build no
            // longer needs to fetch / compile sqlite3.c (saves ~30s on
            // fresh checkouts). Falls back to vendored on hosts that
            // don't have vcpkg installed (a developer building on
            // Windows without vcpkg still gets a working build).
            //
            // Use addObjectFile (not linkSystemLibrary) to bypass
            // the GNU-vs-MSVC lib-name convention mismatch: the
            // build target is `x86_64-windows-gnu` (GNU toolchain
            // conventions — `libfoo.a`), but vcpkg ships
            // `libfoo.lib` / `sqlite3.lib` (MSVC-style extension
            // with GNU-style name). Explicit object-file links work
            // with either naming — the linker doesn't try to
            // translate `-lfoo` → `libfoo.{a,lib}` it just adds
            // the file the build.zig hands it.
            if (sys.use_system_sqlite3) {
                mod.addIncludePath(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/include" });
                mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/sqlite3.lib" });
                // libpq on Windows — same app gate as Linux above.
                if (enable_postgres and sys.use_system_pq) {
                    mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libpq.lib" });
                }
                if (sys.use_system_ssl) {
                    mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libssl.lib" });
                }
                if (sys.use_system_crypto) {
                    mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/libcrypto.lib" });
                }
            } else {
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
            // bcrypt.dll is needed by kabelweb repo src/server/security.zig
            // (BCryptGenRandom — Zig's std.c.getrandom is `void` on Windows).
            mod.linkSystemLibrary("bcrypt", .{});
        },
        else => {
            // Cross-compile to non-Linux/macOS/Windows targets (FreeBSD,
            // Android, WASI). Same amalgamation path as the named targets;
            // bcrypt / openssl / pq aren't applicable here.
            mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
        },
    }

    // === Tests for the package itself ===
    // `b.addTest({ .root_module = mod })` walks every `_test.zig`
    // reachable from src/root.zig via the `test { _ = @import(...) }`
    // block. The mod already carries link_libc + (system or vendored)
    // sqlite3 amalgamation, so test executables inherit those deps
    // automatically.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run databases package tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(b.getInstallStep());
}