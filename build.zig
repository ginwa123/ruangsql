//! `databases` package — self-contained Zig package exposing the sqlite3 + libpq bindings,
//! with per-target system-lib probing and a vendored amalgamation fallback.

const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform "does this file exist" check for the probe: direct syscalls rather
/// than `std.c` (no libc linked by default); Windows must also exclude the DIRECTORY bit.
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
        // macOS: libc `access()` — same F_OK check as `test -f`; the extern always
        // resolves because the build runner links libc.
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

/// Probe the HOST system for sqlite3 + libpq + openssl at build-config time (~25 ms;
/// no caching). Only native builds qualify — a cross-compile's host libs are the wrong OS.
pub fn probeSystemLibs(b: *std.Build, target: std.Build.ResolvedTarget) SystemLibs {
    // Only native (target == host) goes system-only; a cross-compile targets another
    // OS, so its host libs are unusable and it always falls back to the vendored path.
    if (target.result.os.tag != b.graph.host.result.os.tag) {
        return .{
            .use_system_sqlite3 = false,
            .use_system_pq = false,
            .use_system_ssl = false,
            .use_system_crypto = false,
        };
    }

    // libpq-fe.h is at /usr/include/postgresql on Debian/Ubuntu and directly in
    // /usr/include on Arch — check both. Pure-Zig (no `sh`), so Windows needs no bash.
    var sqlite_hdr: bool = false;
    var sqlite_lib: bool = false;
    var pq_hdr: bool = false;
    var pq_lib: bool = false;
    var ssl_hdr: bool = false;
    var ssl_lib: bool = false;
    var crypto_lib: bool = false;
    switch (b.graph.host.result.os.tag) {
        .linux => {
            // Arch/Fedora install into /usr/lib/ directly; Debian/Ubuntu use
            // multiarch /usr/lib/<triplet>/ — probe both layouts.
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
            // Header-only probe (vcpkg): MSVC and MinGW name the .lib files
            // differently, so let the linker report a missing one instead.
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

    // Windows probes headers only (vcpkg sysroot; the linker reports a missing .lib);
    // Linux/macOS must ALSO have the .so/.dylib or a header-only install fails at load.
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

    // Vendored sqlite3 amalgamation dir, relative to this build.zig; the fetch script
    // scripts/fetch-vendor-sqlite3.sh populates it. Override with `-Dvendor-dir=...`.
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

    // Force the vendored sqlite3 amalgamation even when the probe finds system sqlite3 —
    // needed when the system lib lacks FTS5 (stock vcpkg). libpq/openssl still follow the probe.
    const sqlite_vendor = b.option(
        bool,
        "sqlite-vendor",
        "Always compile the vendored sqlite3 amalgamation (with FTS5) instead of linking system sqlite3; libpq/openssl still follow the system probe",
    ) orelse false;

    // Backend list for `-Ddb_used` (comma-separated — the CLI passes strings only),
    // forwarded by the app's root build.zig. The default "sqlite" never links libpq.
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

    // `build_options.enable_postgres` is read at comptime, so the unchosen branch is
    // dropped before `@cImport` — sqlite-only builds need no libpq headers at all.
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_postgres", enable_postgres);
    mod.addOptions("build_options", build_options);

    // Probe the host: usable system libs are linked directly, otherwise fall back to the
    // vendored amalgamation, which works on any host with a C compiler.
    const sys = if (force_vendor) SystemLibs{
        .use_system_sqlite3 = false,
        .use_system_pq = false,
        .use_system_ssl = false,
        .use_system_crypto = false,
    } else probeSystemLibs(b, target);

    // Header path for `@cImport(@cInclude("sqlite3.h"))` in src/sqlite/Sqlite.zig: on the
    // system path /usr/include is already searched; the vendor dir co-locates header and .c.
    if (!sys.use_system_sqlite3) {
        mod.addIncludePath(b.path(vendor_dir));
    } else {
        // Only Linux gets /usr/include here: on Windows that path resolves to a bogus
        // UNC-style directory and translate-c fails (vcpkg headers are added below).
        if (target.result.os.tag == .macos) {
            // Keg-only: formula `sqlite` lives at opt/sqlite (NOT opt/sqlite3);
            // both paths are added for hosts using either name.
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite/include" });
            mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite3/include" });
        }
        if (target.result.os.tag == .linux) {
            mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
        }
    }

    // Flags mirror the project convention: SQLITE_THREADSAFE=1 (multi-threaded app),
    // SQLITE_OMIT_LOAD_EXTENSION, and SQLITE_ENABLE_FTS5 (required by the FTS5 indexes).
    const sqlite_c = b.path(b.fmt("{s}/sqlite3.c", .{vendor_dir}));
    const sqlite_flags = &[_][]const u8{
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_ENABLE_FTS5",
    };
    switch (target.result.os.tag) {
        .linux => {
            if (sys.use_system_sqlite3 and !sqlite_vendor) {
                // System sqlite3: link the shared lib instead of compiling the
                // amalgamation (saves ~3 min on a first build + ~10 MB of artifacts).
                mod.linkSystemLibrary("sqlite3", .{});
            } else {
                // Vendored amalgamation (also via -Dsqlite-vendor): compile sqlite3.c here and
                // re-add the vendor include that the probe-true branch above skipped.
                mod.addIncludePath(b.path(vendor_dir));
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
            // libpq only when -Ddb_used opts in AND the probe found it: sqlite-only builds
            // link no -lpq and add no postgresql include path, though Postgres.zig stays on disk.
            if (enable_postgres and sys.use_system_pq) {
                mod.linkSystemLibrary("pq", .{});
                // Both paths: Debian/Ubuntu keep libpq-fe.h under /usr/include/postgresql,
                // Arch directly in /usr/include; harmless when the other is missing.
                mod.addIncludePath(.{ .cwd_relative = "/usr/include/postgresql" });
            }
            // ssl/crypto are linked only when probed: the amalgamation pulls in no TLS, but
            // the app's libpq/openssl use does depend on them.
            if (sys.use_system_ssl) mod.linkSystemLibrary("ssl", .{});
            if (sys.use_system_crypto) mod.linkSystemLibrary("crypto", .{});
        },
        .macos => {
            // macOS native: prefer brew's keg-only formula `sqlite` (opt/sqlite, with an
            // opt/sqlite3 alternate) when probed; otherwise vendor the amalgamation.
            if (sys.use_system_sqlite3 and !sqlite_vendor) {
                mod.linkSystemLibrary("sqlite3", .{});
                mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite/lib" });
                mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/sqlite3/lib" });
                mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
            } else {
                mod.addIncludePath(b.path(vendor_dir));
                mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
            }
            // libpq only when -Ddb_used opts in AND the probe found brew's keg-only libpq;
            // ssl/crypto stay unwired — brew libpq carries absolute paths, kabelweb owns TLS.
            if (enable_postgres and sys.use_system_pq) {
                mod.linkSystemLibrary("pq", .{});
                mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/lib" });
                mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/libpq/include" });
            }
        },
        .windows => {
            // vcpkg libs when probed (CI path `C:/vcpkg/installed/x64-windows/`), else vendored.
            // addObjectFile, not linkSystemLibrary: vcpkg's MSVC `.lib` names break `-lfoo` here.
            if (sys.use_system_sqlite3) {
                mod.addIncludePath(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/include" });
                if (!sqlite_vendor) {
                    mod.addObjectFile(.{ .cwd_relative = "C:/vcpkg/installed/x64-windows/lib/sqlite3.lib" });
                } else {
                    // Stock vcpkg sqlite3 lacks the fts5 module this package requires, so
                    // compile the amalgamation here while still taking libpq/ssl from vcpkg.
                    mod.addIncludePath(b.path(vendor_dir));
                    mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
                }
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
            // Other targets (FreeBSD, Android, WASI): same amalgamation path; bcrypt,
            // openssl and pq do not apply.
            mod.addCSourceFile(.{ .file = sqlite_c, .flags = sqlite_flags });
        },
    }

    // === Tests for the package itself ===

    // `b.addTest({ .root_module = mod })` walks every `_test.zig` reachable from src/root.zig;
    // Zig 0.16 filters tests at BUILD time (`-Dtest-filter=`), the runner's `--test-filter` aborts.
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "Only run tests whose name contains this substring",
    ) orelse "";
    const test_filters: []const []const u8 = if (test_filter.len > 0) &.{test_filter} else &.{};

    const mod_tests = b.addTest(.{ .root_module = mod, .filters = test_filters });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run databases package tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(b.getInstallStep());

    // === Benchmark ===

    // `zig build bench`: deterministic sqlite workload emitting one JSON object on stdout,
    // optimized but with safety checks, so a silent misbind cannot look like a fast run.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("sqlite", mod);
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    // Install it too, so the Containerfile can COPY a single path and a
    // human can run `zig-out/bin/bench` directly without `zig build`.
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the deterministic sqlite benchmark");
    bench_step.dependOn(&run_bench.step);

    // The comment-ceiling / catch-unreachable linter (github.com/ginwa123/zglint),
    // pinned in build.zig.zon; `zig build zginlint:check` is the gate CI runs.
    const zginlint_dep = b.dependency("zginlint", .{
        .target = target,
        .optimize = optimize,
    });
    const zginlint_exe = zginlint_dep.artifact("zginlint");
    const install_zginlint = b.addInstallArtifact(zginlint_exe, .{});
    b.step("zginlint", "Build the zginlint CLI into zig-out/bin/zginlint")
        .dependOn(&install_zginlint.step);

    // The whole gate: the paths it covers, and the comment-block ceiling.
    // 2 lines is tighter than the tool's own default of 3.
    const zginlint_scope = [_][]const u8{ "src", "bench", "build.zig" };

    // `has_side_effects` is load-bearing: a Run step is keyed by its binary and argv,
    // NOT by the tree it reads, so without it a rerun silently skips the scan.
    const zginlint_check = b.step("zginlint:check", "Enforce the zginlint rules on the tree (zero findings)");
    const run_zginlint_check = b.addRunArtifact(zginlint_exe);
    run_zginlint_check.setCwd(b.path("."));
    run_zginlint_check.addArgs(&.{ "--max-comment-lines", "2" });
    run_zginlint_check.addArgs(&zginlint_scope);
    run_zginlint_check.has_side_effects = true;
    zginlint_check.dependOn(&run_zginlint_check.step);
}
