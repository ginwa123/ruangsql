//! SQLite backend used everywhere nalar needs a database. Provides
//! basic `exec` / `query` / `queryRow` for single-statement operations
//! and a `Transaction` RAII type for multi-statement atomic operations.
//!
//! See `sqlite_test.zig` (the canonical documentation of the public
//! API surface) for usage patterns and test coverage.
//!
//! The `c` declarations are platform-scoped (Linux uses `@cImport` with
//! the system sqlite3.h; macOS/Windows use manual extern declarations
//! because the headers aren't on the default include path).

const std = @import("std");
const builtin = @import("builtin");

// Alternative sqlite3_bind_text binding that takes the destructor parameter
// as `isize` (a raw integer) instead of a `sqlite3_destructor_type` function
// pointer. The cImport-generated binding uses the function-pointer type,
// which Zig's comptime alignment check rejects when we try to pass `-1`
// (the SQLITE_TRANSIENT sentinel) because `-1` (= 0xFFFFFFFFFFFFFFFF) is not
// 8-byte aligned on aarch64-macos. At the C ABI level both isize and a
// function pointer occupy one 8-byte register on x86_64/aarch64 — the
// bits pass through unchanged. SQLite's compiled check
// `if (xDel == SQLITE_TRANSIENT)` is a bitwise comparison and succeeds
// regardless of whether we declared the parameter as isize or as a
// function pointer on the Zig side.
// Wrapper for `sqlite3_bind_text` that takes the destructor parameter as
// `isize` (a raw integer) instead of `sqlite3_destructor_type` (a function
// pointer). The cImport-generated binding uses the function-pointer type,
// which Zig's comptime alignment check rejects when we try to construct
// the SQLITE_TRANSIENT sentinel (= -1 cast to a function pointer, but
// `0xFFFFFFFFFFFFFFFF` is not 8-byte aligned on aarch64-macos).
//
// We side-step the alignment check by declaring this wrapper with an
// `isize` destructor parameter. At the C ABI level both `isize` and a
// function pointer occupy one 8-byte register on x86_64/aarch64 — the
// bits pass through unchanged. SQLite's compiled check
// `if (xDel == SQLITE_TRANSIENT)` is a bitwise comparison and succeeds
// regardless of whether we declared the parameter as `isize` or as a
// function pointer on the Zig side.
//
// The `@extern` builtin returns `?*const FnType` (nullable); we unwrap with
// `orelse unreachable` because the symbol is statically linked from
// `vendor/sqlite3/sqlite3.c` on all platforms.
const sqlite3_bind_text_isize_Fn = fn (
    ?*anyopaque,
    c_int,
    [*]const u8,
    c_int,
    isize,
) callconv(.c) c_int;
const sqlite3_bind_text_isize_opt: ?*const sqlite3_bind_text_isize_Fn =
    @extern(*const sqlite3_bind_text_isize_Fn, .{ .name = "sqlite3_bind_text" });
const sqlite3_bind_text_isize: *const sqlite3_bind_text_isize_Fn =
    sqlite3_bind_text_isize_opt orelse unreachable;

/// Values SQLite accepts for `PRAGMA synchronous`. Kept as an enum (not a
/// raw integer) so a caller cannot silently pass a bitmask soup.
pub const Synchronous = enum(u8) {
    off = 0,
    normal = 1,
    full = 2,
    extra = 3,

    pub fn sql(self: Synchronous) []const u8 {
        return switch (self) {
            .off => "OFF",
            .normal => "NORMAL",
            .full => "FULL",
            .extra => "EXTRA",
        };
    }
};

/// Connection policy applied to every `SqliteBackend` at `init`.
///
/// WHY THIS EXISTS — `init` used to hard-code `journal_mode=WAL` +
/// `busy_timeout=5000` and nothing else. WAL gives a database file
/// exactly ONE writer slot, and a write that cannot take it blocks for
/// `busy_timeout` and then FAILS: the write is lost, not delayed. With a
/// 5-second ceiling and several processes sharing one file, every write on
/// the hot path (`UPDATE sessions …`, `INSERT INTO logs …`) could come
/// back as:
///
/// ```text
/// warning: sqlite3 step failed: database is locked (sql: …)
/// ```
///
/// …repeated, forever, each one a full 5-second stall.
///
/// Defaults, and what each buys:
///
///   - `busy_timeout_ms` — the ONLY defence a WAL writer has against a
///     competing writer. Raised from 5 s to 15 s: the wait costs nothing
///     when nobody else is writing (it only happens while the slot is
///     genuinely taken) and converts most real contention from "write
///     lost" into "write delayed".
///
///   - `synchronous` — left at `.full`, SQLite's own default, so this
///     package does not silently change any consumer's durability. In WAL
///     mode `.normal` is the documented recommendation (sync at
///     checkpoints instead of on every commit); an app that prefers it
///     opts in: `db.applyConfig(alloc, .{ .synchronous = .normal })`.
///     Trade-off: on an OS crash / power cut the last few commits may be
///     lost. `PRAGMA integrity_check` still passes and SQLite's WAL
///     guarantees still hold, because recovery goes through the
///     checkpoint.
///
///   - `journal_size_limit_bytes` — caps the `-wal` file. Without it the
///     WAL is only ever APPENDED: `wal_autocheckpoint` caps how much is
///     copied back per checkpoint, but nothing shrinks the file, so on a
///     long-lived install it grows until a checkpoint can reset it. -1
///     means "no limit" (SQLite's own default).
///
///   - `wal_autocheckpoint_pages` — SQLite's default, stated explicitly
///     so `Config` is a complete description of the connection rather
///     than a delta on top of whatever the library happens to do.
pub const Config = struct {
    busy_timeout_ms: u32 = 15_000,
    synchronous: Synchronous = .full,
    journal_size_limit_bytes: i64 = 64 * 1024 * 1024,
    wal_autocheckpoint_pages: u32 = 1_000,
    /// Page cache for THIS connection, in KiB (`PRAGMA cache_size = -N`,
    /// i.e. a size in KiB rather than a page count). Default 8 MiB — SQLite
    /// ships 2 MiB, which is small for a table that is read on every
    /// request. 0 leaves SQLite's own default in place.
    ///
    /// The cache is per connection, so a pool of N connections spends
    /// N × this if you open several connections by hand.
    cache_size_kb: u32 = 8_000,
    /// Extra READ connections `init` opens alongside the primary one.
    ///
    /// WAL gives a database file MANY concurrent readers and exactly ONE
    /// writer. A single connection therefore serialises every read behind
    /// one mutex — a read queued behind a write waits for the whole write,
    /// and reads never use more than one core. Opening readers makes them
    /// genuinely parallel; writers keep using the primary connection, which
    /// is the only one SQLite allows to write anyway.
    ///
    /// 0 = no pooling (exactly the old single-connection behaviour).
    /// Default 7 → 8 connections total, sized to a typical 2–8 core
    /// runtime.
    read_conns: usize = 7,
    /// Ceiling on the reader pool. 0 = UNLIMITED (the default): a read
    /// that finds every reader busy opens another connection rather than
    /// queueing, so read concurrency is bounded by in-flight reads and
    /// never by a fixed pool size.
    ///
    /// The pool is elastic because a reader must not be reused while a
    /// `Rows` from it is still open — see `ReaderPool.claim`. A reader is
    /// only returned to the idle list after its statement is reset, which
    /// ends the read transaction that was pinning the connection's
    /// snapshot, so a reused reader always starts a FRESH read.
    ///
    /// Set this only to bound memory: every pooled reader spends its own
    /// `cache_size_kb` of page cache and its own `mmap_size_bytes` of
    /// address space.
    max_read_conns: usize = 0,
    /// `PRAGMA mmap_size` in bytes: read the database through a memory
    /// mapping instead of `read()`. 0 leaves SQLite's default (no mmap).
    ///
    /// Trades page-cache accounting for syscalls: pages still come from
    /// the OS file cache, but each page hit skips a syscall and a copy.
    /// It is not extra anonymous memory, so it does not count against a
    /// container's `memory.max` the way `cache_size` does.
    ///
    /// Default 256 MiB of window: a single mapping, only as many pages as
    /// the database actually has are ever resident, so a generous cap is
    /// free. Set 0 to leave SQLite's own default (no mmap).
    mmap_size_bytes: u64 = 256 * 1024 * 1024,
};

/// What `readConfig` observed on the connection. Printed by consumers at
/// boot so a future "database is locked" report carries the live
/// connection's actual settings instead of a guess.
pub const ActiveConfig = struct {
    /// SQLite's journal-mode names ("delete", "truncate", "persist",
    /// "memory", "wal", "off") all fit in 16 bytes. A fixed buffer keeps
    /// `ActiveConfig` allocation-free — it exists for one log line and
    /// must not hand the caller an ownership obligation.
    journal_mode_buf: [16]u8 = undefined,
    journal_mode_len: usize = 0,
    busy_timeout_ms: u32,
    synchronous: i64,
    wal_autocheckpoint_pages: u32,
    /// Signed: SQLite's default here is -1 ("no limit"), which is exactly
    /// what an unconfigured connection reports.
    journal_size_limit_bytes: i64,

    /// Borrowed view of `journal_mode_buf` — valid for as long as `self`.
    pub fn journalMode(self: *const ActiveConfig) []const u8 {
        return self.journal_mode_buf[0..self.journal_mode_len];
    }
};

const JOURNAL_MODE_BUF_LEN = 16;

pub const Error = error{
    OpenFailed,
    DatabaseNotFound,
    PermissionDenied,
    DiskFull,
    DatabaseCorrupt,
    QueryFailed,
    PrepareFailed,
    BindFailed,
    ExecuteFailed,
    /// The reader pool is at `Config.max_read_conns` and every reader is
    /// busy. Only reachable when `max_read_conns` is non-zero; the default
    /// is unlimited, so the pool opens another connection instead.
    PoolExhausted,
    RowNotFound,
    OutOfMemory,
    Canceled,
    /// Returned by any Transaction method (exec/query/queryRow/commit/rollback)
    /// called after the transaction has been completed. Indicates the tx
    /// is single-use and must not be touched again. The mutex is no longer
    /// held, so any further use would race with concurrent writers on the
    /// same backend. The recommended defer pattern is:
    ///   `defer tx.rollback() catch |err| switch (err) {
    ///       error.TransactionClosed => {},
    ///       else => return err,
    ///   };`
    TransactionClosed,
};

/// Cross-platform sqlite3 bindings.
///
/// IMPORTANT: The `c` declarations are scoped INSIDE `SqliteBackend` (lazily
/// resolved when the struct is referenced) — not at file level. The reason is
/// that `@cImport(@cInclude("sqlite3.h"))` requires the sqlite3 header to be
/// present in the compiler's include path AT THE TIME the import is resolved.
/// On macOS, the system's `sqlite3.h` is keg-only and not in the default
/// include path; CI installs only `openssl@3`, not `sqlite3`. Hoisting the
/// `@cImport` to file level would force every translation unit that
/// `@import("Sqlite.zig")`s to provide sqlite3 headers — including the test
/// target, which has no good reason to need them at type-check time. The
/// original (pre-windows-compatibility) code put cImport inside the struct
/// for this reason; we preserve that pattern here.
///
/// On Windows (where vendored sqlite3 is compiled in from source), the
/// `c` is a struct of manual `extern fn` declarations — also evaluated
/// lazily because the struct field of the same name is referenced only
/// when SqliteBackend is actually used.
/// File descriptors one pooled reader holds, MEASURED (not guessed) by
/// opening seven connections to one WAL database and reading the links
/// under `/proc/self/fd`.
///
/// It is 2, not 3: each connection holds the database file and its `-wal`,
/// but the `-shm` (the WAL index) is a single shared-memory segment per
/// PROCESS per database file, so it is paid once for the whole pool rather
/// than per reader.
///
/// Over-reserving would be the safe direction to err, so note that the cap
/// below uses this figure directly: 100 readers ≈ 200 descriptors, plus
/// one `-shm`.
pub const FDS_PER_READER: usize = 2;

/// Descriptors reserved for everything that is NOT a pooled reader:
/// listening sockets, one per connected SSE client, open source files,
/// subprocess pipes. This has to be generous. A server that keeps a
/// long-lived SSE stream per browser tab is already using hundreds before
/// the database opens anything.
pub const FD_HEADROOM: usize = 256;

/// How many readers this process can afford, derived from its actual
/// `RLIMIT_NOFILE` rather than from a guess.
///
/// This is the hard ceiling the reader pool obeys even when
/// `Config.max_read_conns == 0`. "Unlimited" has to mean "bounded by the
/// resource", not "bounded by nothing": a pooled reader costs
/// `FDS_PER_READER` descriptors, and when the process runs out,
/// `sqlite3_open` returns SQLITE_CANTOPEN and the failure surfaces as
/// `unable to open database file` on a `PRAGMA journal_mode = WAL` — which
/// reads like a permissions or path problem and is neither.
pub fn fdDerivedReaderCap() usize {
    if (builtin.os.tag == .windows) return 32; // no RLIMIT_NOFILE to read
    // `cur` is the SOFT limit — the one actually enforced, and the one a
    // `ulimit -n` in a launcher script would have lowered.
    const lim = std.posix.getrlimit(std.posix.rlimit_resource.NOFILE) catch return 32;
    const soft = @as(usize, @intCast(lim.cur));
    if (soft <= FD_HEADROOM) return 1;
    const affordable = (soft - FD_HEADROOM) / FDS_PER_READER;
    return @max(affordable, 1);
}

pub const SqliteBackend = struct {
    const c = @cImport(@cInclude("sqlite3.h"));

    // `SQLITE_TRANSIENT` sentinel — passed as -1 via the
    // `sqlite3_bind_text_isize` wrapper above (which takes isize instead
    // of the cImport-generated `sqlite3_destructor_type` function pointer
    // type). See the long comment on the wrapper for why this matters.
    const SQLITE_DESTRUCTOR_TRANSIENT: isize = -1;

    io: std.Io = .failing,
    db: ?*c.sqlite3 = null,
    mutex: std.Io.Mutex = .init,
    /// Tracks the current transaction nesting depth (0 = no tx active;
    /// 1 = top-level BEGIN in flight; 2+ = nested SAVEPOINT). Incremented
    /// by `begin` / `savepoint`, decremented by `commit` / `rollback`.
    /// Used to choose between `BEGIN` / `COMMIT` (depth 0↔1) and
    /// `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` (depth >= 1).
    transaction_depth: u32 = 0,

    /// Per-connection prepared-statement cache. Filled by `exec` /
    /// `queryRow` on first use of each SQL text.
    stmt_cache: StmtCache = .{},

    /// Elastic pool of extra READ-ONLY connections.
    ///
    /// Empty / `enabled == false` when `Config.read_conns == 0` or the
    /// path is `:memory:`, in which case every statement runs on the
    /// backend's own connection (the historical behaviour).
    ///
    /// WHY CLAIM/RELEASE AND NOT ROUND-ROBIN. A `Rows` from `query` keeps
    /// stepping its statement AFTER `query` returns, and an open statement
    /// keeps a READ TRANSACTION open on that connection — and SQLite allows
    /// only one read transaction per connection. So a connection with a
    /// live iterator is pinned to the snapshot it opened, and every later
    /// read handed to it is served from that old snapshot. A round-robin
    /// pool does exactly that, intermittently and invisibly: writes commit,
    /// and one read in N reports the previous state.
    ///
    /// A reader is therefore owned EXCLUSIVELY by one read at a time, and
    /// returns to the idle list only after its statement has been reset
    /// (`Rows.deinit`), which ends the read transaction. A reused reader
    /// therefore always begins a fresh read.
    ///
    /// Because a busy reader is never shared, there is nothing to wait for:
    /// if every reader is busy the pool simply opens another one, bounded
    /// only by `Config.max_read_conns` (0 = unlimited). Read concurrency
    /// tracks in-flight reads instead of a fixed pool size.
    pool: ReaderPool = .{},

    /// True while a `Rows` is stepping THIS backend's own CACHED
    /// statement. Only the primary connection needs it — pooled readers
    /// are exclusively owned, so nothing else can touch them. It matters on
    /// the primary when pooling is off (`:memory:` / `read_conns = 0`) or
    /// for `needsWriteConnection` SQL, where `query`, `exec` and
    /// `queryRow` all share one connection.
    ///
    /// Without it, `exec` / `queryRow` would `sqlite3_reset` +
    /// `sqlite3_clear_bindings` the statement a live iterator is stepping
    /// and rebind it to their own arguments.
    iterating: std.atomic.Value(bool) = .init(false),

    /// Open `db_path` with the default `Config`. Same as
    /// `initWithConfig(io, db_path, .{})`.
    pub fn init(self: *SqliteBackend, io: std.Io, db_path: [:0]const u8) Error!void {
        return self.initWithConfig(io, db_path, .{});
    }

    /// Open `db_path` and immediately apply `cfg` to the connection.
    ///
    /// WAL is re-asserted here as well: `PRAGMA journal_mode` needs a brief
    /// exclusive lock to CHANGE mode, but re-asserting it on a database
    /// that is already in WAL mode is a no-op that does not contend, and
    /// it makes `initWithConfig` a complete description of the connection
    /// rather than a delta on top of whatever the library happens to do.
    pub fn initWithConfig(
        self: *SqliteBackend,
        io: std.Io,
        db_path: [:0]const u8,
        cfg: Config,
    ) Error!void {
        try openSingle(self, io, db_path, cfg);

        // Reads get their own connections. Best-effort: if the extra
        // connections cannot be opened, the backend still works exactly
        // like the single-connection version rather than failing to start.
        if (cfg.read_conns == 0) return;
        // An in-memory database belongs to the CONNECTION that opened it:
        // a second connection would see an empty, unrelated database. So
        // `:memory:` (and an unshared `file::memory:`) always stays on one
        // connection — which is also what every `:memory:` test expects.
        if (isInMemoryPath(db_path)) return;
        self.pool.enable(io, db_path, cfg);
        // Pre-warm the initial readers so the first burst of concurrent
        // reads does not each pay to open + `applyConfig` a connection.
        // The pool still grows past this on demand; `read_conns` is the
        // warm floor, not the ceiling.
        self.pool.prewarm(io, cfg.read_conns) catch |err| {
            std.log.warn("sqlite: reader pool warm-up failed ({s}); the pool will grow on demand", .{@errorName(err)});
        };
    }

    /// Open one connection and apply `cfg` to it. No pooling — the
    /// building block for both the primary connection and the readers.
    fn openSingle(
        slot: *SqliteBackend,
        io: std.Io,
        db_path: [:0]const u8,
        cfg: Config,
    ) Error!void {
        slot.io = io;
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(db_path.ptr, &db);
        if (rc != c.SQLITE_OK) {
            _ = c.sqlite3_close(db);
            return switch (rc) {
                c.SQLITE_CANTOPEN => Error.DatabaseNotFound,
                c.SQLITE_PERM => Error.PermissionDenied,
                c.SQLITE_FULL => Error.DiskFull,
                c.SQLITE_CORRUPT => Error.DatabaseCorrupt,
                else => error.OpenFailed,
            };
        }
        slot.db = db;
        try slot.applyConfig(cfg);
    }

    /// True for the SQLite spellings of a private, connection-local
    /// in-memory database.
    fn isInMemoryPath(db_path: []const u8) bool {
        if (std.mem.eql(u8, db_path, ":memory:")) return true;
        // `file::memory:...` is in-memory too; if it carries
        // `cache=shared` the connections would share one database, but
        // pooling a shared-cache memory DB buys nothing, so skip it.
        if (std.mem.startsWith(u8, db_path, "file::memory:")) return true;
        return false;
    }

    /// True for SQL that inspects CONNECTION state rather than table data.
    ///
    /// `last_insert_rowid()`, `changes()` and `total_changes()` are
    /// per-connection counters. A reader connection has never written
    /// anything, so it would answer `0` — silently wrong. These statements
    /// therefore have to stay on the connection that did the write.
    ///
    /// This is the one thing pooling cannot make transparent by routing
    /// alone, so it is decided by name. The check is a case-insensitive
    /// substring scan over a handful of needles, and only ever runs for a
    /// statement that is already a read.
    fn needsWriteConnection(sql: []const u8) bool {
        const needles = [_][]const u8{ "last_insert_rowid", "total_changes", "changes(" };
        for (needles) |needle| {
            if (containsIgnoreCase(sql, needle)) return true;
        }
        return false;
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0 or haystack.len < needle.len) return false;
        var i: usize = 0;
        const last = haystack.len - needle.len;
        while (i <= last) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    /// Elastic pool of READ-ONLY connections, owned by the primary
    /// `SqliteBackend` and shared by every thread that reads through it.
    ///
    /// Contract: `claim` hands a connection to EXACTLY ONE read at a time.
    /// The owner keeps it until `release`, which it must call only once the
    /// statement is reset — see the `SqliteBackend.pool` field for why that
    /// ordering is the whole point.
    ///
    /// Connections are individually heap-allocated (`*SqliteBackend`)
    /// rather than held in one contiguous slice, so growing the pool never
    /// MOVES a slot that a `Rows` is holding.
    const ReaderPool = struct {
        const alloc = std.heap.smp_allocator;

        enabled: bool = false,
        io: std.Io = .failing,
        /// Owned copy of the database path. The pool opens connections lazily,
        /// long after `initWithConfig`'s `db_path` argument has gone out of
        /// scope, so a borrow would be a use-after-free waiting for the
        /// first read that needs a new reader.
        db_path: ?[:0]u8 = null,
        cfg: Config = .{},
        /// Every open reader, claimed or idle.
        slots: std.ArrayListUnmanaged(*SqliteBackend) = .empty,
        /// Indices into `slots` that are free to claim. An index is in
        /// exactly one of the two lists at any time.
        idle: std.ArrayListUnmanaged(usize) = .empty,
        /// Guards `slots` / `idle` structure only. Held briefly — never
        /// across a statement — so it is not the read hot path's limiter.
        mutex: std.Io.Mutex = .init,

        fn enable(self: *ReaderPool, io: std.Io, db_path: [:0]const u8, cfg: Config) void {
            self.db_path = alloc.dupeZ(u8, db_path) catch {
                // Without the path the pool cannot open anything, so leave
                // it disabled: every read falls back to the primary
                // connection, which is correct, just serialized.
                std.log.warn("sqlite: could not copy the database path; reader pool disabled", .{});
                return;
            };
            self.enabled = true;
            self.io = io;
            self.cfg = cfg;
        }

        /// The database path this pool opens readers against.
        ///
        /// An error rather than an `unreachable`: `closeAll` clears
        /// `db_path`, so a `claim` racing shutdown would otherwise turn a
        /// shutdown-ordering bug into a panic.
        fn path(self: *ReaderPool) Error![:0]const u8 {
            return self.db_path orelse Error.DatabaseNotFound;
        }

        /// Open up to `n` readers now so a burst does not each pay for a
        /// connection open + `applyConfig`.
        fn prewarm(self: *ReaderPool, io: std.Io, n: usize) !void {
            self.mutex.lock(io) catch return Error.Canceled;
            defer self.mutex.unlock(io);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (self.atCap()) break;
                const slot = alloc.create(SqliteBackend) catch return Error.OutOfMemory;
                slot.* = .{};
                // Same reason as `openSlot`: `applyConfig` can fail after
                // the handle is assigned, so the handle needs closing.
                const db_path = try self.path();
                openSingle(slot, io, db_path, self.cfg) catch |err| {
                    slot.deinit();
                    alloc.destroy(slot);
                    return err;
                };
                try self.slots.append(alloc, slot);
                try self.idle.append(alloc, self.slots.items.len - 1);
            }
        }

        /// Open one more reader.
        ///
        /// ONE cleanup path, deliberately. An `errdefer` fires on EVERY
        /// error return, so pairing it with an explicit `alloc.destroy` on
        /// any one of those paths is a double free — which is exactly what
        /// this function used to do, and it only surfaced under fd
        /// exhaustion, because that is what makes the error paths run.
        fn openSlot(self: *ReaderPool, io: std.Io) !*SqliteBackend {
            const slot = alloc.create(SqliteBackend) catch return Error.OutOfMemory;
            // `pool = .{}` — a reader never nests a pool of its own.
            slot.* = .{};
            // `deinit`, not a bare `alloc.destroy`: `openSingle` can fail
            // AFTER assigning `slot.db` (it is `applyConfig` that fails,
            // and that runs last), so the sqlite handle must be closed or
            // its fds leak for the life of the process. `deinit` is safe on
            // a half-open backend — every step null-checks first.
            errdefer alloc.destroy(slot);
            errdefer slot.deinit();
            openSingle(slot, io, try self.path(), self.cfg) catch |err| return err;

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.atCap()) return error.PoolExhausted;
            try self.slots.append(alloc, slot);
            return slot;
        }

        /// True when the pool must not open another reader.
        ///
        /// `Config.max_read_conns` is the POLICY cap, and 0 means "no
        /// policy cap" — but there is still a hard ceiling, because a
        /// pooled reader costs `FDS_PER_READER` file descriptors and the
        /// consumer process needs those for its own sockets. A long-lived
        /// server that fans out one fd per SSE client WILL run the process
        /// out of descriptors otherwise, at which point `sqlite3_open`
        /// returns SQLITE_CANTOPEN and every read that needs a new reader
        /// fails with "unable to open database file".
        fn atCap(self: *ReaderPool) bool {
            if (self.cfg.max_read_conns != 0 and self.slots.items.len >= self.cfg.max_read_conns) {
                return true;
            }
            return self.slots.items.len >= fdDerivedReaderCap();
        }

        /// Take exclusive ownership of a reader, opening one if every
        /// existing reader is busy. Never blocks on another read.
        pub fn claim(self: *ReaderPool, io: std.Io) Error!*SqliteBackend {
            try self.mutex.lock(io);
            if (self.idle.pop()) |idx| {
                self.mutex.unlock(io);
                return self.slots.items[idx];
            }
            self.mutex.unlock(io);
            return self.openSlot(io);
        }

        /// Hand a reader back. Call ONLY once its statement has been reset
        /// or finalized, so the next read starts a fresh snapshot.
        pub fn release(self: *ReaderPool, io: std.Io, slot: *SqliteBackend) void {
            // The index lookup reads `slots.items`, so it MUST happen under
            // the mutex: a concurrent `claim` → `openSlot` can reallocate
            // that slice, and scanning the stale pointer is undefined.
            self.mutex.lock(io) catch return;
            defer self.mutex.unlock(io);
            const idx = self.indexOf(slot) orelse return;
            self.idle.append(alloc, idx) catch {
                // Out of memory for the idle index. Deliberately do NOT
                // `swapRemove` the slot out of `slots` here: that would
                // renumber every later index and silently hand the same
                // connection to two readers. Keeping it claimed leaks one
                // connection, which is the safe direction to fail.
                std.log.err("sqlite: reader pool lost an idle slot to OOM; leaking one connection", .{});
            };
        }

        fn indexOf(self: *ReaderPool, slot: *SqliteBackend) ?usize {
            for (self.slots.items, 0..) |s, i| {
                if (s == slot) return i;
            }
            return null;
        }

        fn closeAll(self: *ReaderPool, io: std.Io) void {
            self.mutex.lock(io) catch {};
            defer self.mutex.unlock(io);
            for (self.slots.items) |slot| {
                slot.deinit();
                alloc.destroy(slot);
            }
            self.slots.deinit(alloc);
            self.idle.deinit(alloc);
            self.slots = .empty;
            self.idle = .empty;
            if (self.db_path) |owned_path| alloc.free(owned_path);
            self.db_path = null;
            self.enabled = false;
        }

        pub fn count(self: *ReaderPool) usize {
            return self.slots.items.len;
        }
    };

    /// True when reads can be served by a pooled reader.
    fn poolReady(self: *SqliteBackend) bool {
        return self.pool.enabled;
    }

    /// Take a reader for one read, or fall back to `self`.
    ///
    /// NEVER returns an error. A read that fails because the pool could not
    /// grow is strictly worse than a read that queues behind a write: the
    /// first is a 500 the caller sees, the second is the pre-pooling
    /// behaviour and is merely slower. The pool runs out of capacity for
    /// reasons that have nothing to do with whether this particular read
    /// can be answered — most often descriptors, which is exactly why the
    /// exhaustion showed up as `unable to open database file` on a
    /// `PRAGMA` rather than as anything that looked like a database error.
    fn claimReader(self: *SqliteBackend) *SqliteBackend {
        return self.pool.claim(self.io) catch |err| {
            std.log.warn(
                "sqlite: reader pool unavailable ({s}); serving this read on the write connection",
                .{@errorName(err)},
            );
            return self;
        };
    }

    /// Re-apply `cfg` to an already-open connection. Needs no allocator:
    /// the PRAGMA statements are formatted into stack buffers.
    ///
    /// Every statement is a PRAGMA with no bind parameters, so routing it
    /// through the statement path is safe — the "empty slice binds as SQL
    /// NULL" quirk only bites when a `?` is present.
    pub fn applyConfig(self: *SqliteBackend, cfg: Config) Error!void {
        var busy_buf: [64]u8 = undefined;
        const busy = std.fmt.bufPrint(busy_buf[0..], "PRAGMA busy_timeout = {d}", .{cfg.busy_timeout_ms}) catch return Error.ExecuteFailed;
        var auto_buf: [64]u8 = undefined;
        const auto_ckpt = std.fmt.bufPrint(auto_buf[0..], "PRAGMA wal_autocheckpoint = {d}", .{cfg.wal_autocheckpoint_pages}) catch return Error.ExecuteFailed;
        var size_buf: [64]u8 = undefined;
        const size_limit = std.fmt.bufPrint(size_buf[0..], "PRAGMA journal_size_limit = {d}", .{cfg.journal_size_limit_bytes}) catch return Error.ExecuteFailed;
        var sync_buf: [64]u8 = undefined;
        const sync = std.fmt.bufPrint(sync_buf[0..], "PRAGMA synchronous = {s}", .{cfg.synchronous.sql()}) catch return Error.ExecuteFailed;

        try self.execPragma("PRAGMA journal_mode = WAL");
        try self.execPragma(busy);
        try self.execPragma(sync);
        try self.execPragma(auto_ckpt);
        try self.execPragma(size_limit);

        // Sizing knobs. Both default ON (8 MiB cache, 256 MiB mmap window)
        // because the defaults are what a caller gets for free; set either
        // to 0 to hand the decision back to SQLite.
        if (cfg.cache_size_kb != 0) {
            var cache_buf: [64]u8 = undefined;
            const cache = std.fmt.bufPrint(cache_buf[0..], "PRAGMA cache_size = -{d}", .{cfg.cache_size_kb}) catch return Error.ExecuteFailed;
            try self.execPragma(cache);
        }
        if (cfg.mmap_size_bytes != 0) {
            var mmap_buf: [64]u8 = undefined;
            const mmap = std.fmt.bufPrint(mmap_buf[0..], "PRAGMA mmap_size = {d}", .{cfg.mmap_size_bytes}) catch return Error.ExecuteFailed;
            try self.execPragma(mmap);
        }
    }

    /// `exec` with no allocator: `executeStatement` never touches the
    /// allocator (it is `_ = allocator` in the body — the parameter exists
    /// only for signature symmetry with `exec`), so the PRAGMA path can
    /// pass `undefined` and avoid making every caller thread an allocator
    /// through just to set a timeout.
    fn execPragma(self: *SqliteBackend, sql: []const u8) Error!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeStatement(self, undefined, sql, &.{});
    }

    /// Read the connection's current settings back.
    pub fn readConfig(self: *SqliteBackend, allocator: std.mem.Allocator) Error!ActiveConfig {
        // `Row.values[i]` are allocator-owned and freed by `Row.deinit`, so
        // every value is copied out BEFORE that defer runs.
        var row = try self.queryRow(allocator, "PRAGMA journal_mode", &.{});
        defer row.deinit(allocator);
        if (row.values.len == 0) return Error.RowNotFound;
        if (row.values[0].len > JOURNAL_MODE_BUF_LEN) return Error.QueryFailed;
        var mode_buf: [JOURNAL_MODE_BUF_LEN]u8 = undefined;
        @memcpy(mode_buf[0..row.values[0].len], row.values[0]);

        return .{
            .journal_mode_buf = mode_buf,
            .journal_mode_len = row.values[0].len,
            .busy_timeout_ms = @intCast(try readPragmaInt(self, allocator, "PRAGMA busy_timeout")),
            .synchronous = try readPragmaInt(self, allocator, "PRAGMA synchronous"),
            .wal_autocheckpoint_pages = @intCast(try readPragmaInt(self, allocator, "PRAGMA wal_autocheckpoint")),
            .journal_size_limit_bytes = try readPragmaInt(self, allocator, "PRAGMA journal_size_limit"),
        };
    }

    fn readPragmaInt(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8) Error!i64 {
        var row = try self.queryRow(allocator, sql, &.{});
        defer row.deinit(allocator);
        if (row.values.len == 0) return Error.RowNotFound;
        return std.fmt.parseInt(i64, row.values[0], 10) catch Error.QueryFailed;
    }

    /// Prepare `sql` for a statement that runs to completion INSIDE the
    /// caller's lock (`exec` / `queryRow` / the `Transaction` variants).
    ///
    /// Uses the cache, EXCEPT when a `Rows` iterator is currently stepping
    /// this connection's cached statement. `acquire` would `sqlite3_reset`
    /// + `sqlite3_clear_bindings` that statement and rebind it to this
    /// caller's arguments — destroying the live iterator's remaining rows
    /// and handing it somebody else's parameters, from another thread.
    ///
    /// `SqliteBackend.iterating` is set by `query` while it has a cached
    /// statement checked out. The load is safe here because the caller
    /// holds `self.mutex`, and `query` holds the same mutex across both
    /// the load-and-acquire and the store — so the check and the claim
    /// cannot interleave.
    fn prepareForImmediateUse(self: *SqliteBackend, sql: []const u8) Error!ImmediateStmt {
        const db = self.db orelse return Error.DatabaseNotFound;
        if (!cacheableSql(sql) or self.iterating.load(.acquire)) {
            return .{ .stmt = try prepareOneShot(db, sql), .cached = false };
        }
        return .{ .stmt = try self.stmt_cache.acquire(db, sql), .cached = true };
    }

    const ImmediateStmt = struct {
        stmt: *c.sqlite3_stmt,
        cached: bool,
    };

    /// Inner implementation: prepare + bind + step a single SQL statement.
    /// Caller MUST hold the backend mutex. Used by both `exec` (with lock)
    /// and `Transaction.exec` (without re-locking — the tx already holds it).
    fn executeStatement(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!void {
        _ = allocator;
        const db = self.db orelse return Error.DatabaseNotFound;

        // Empty SQL is a successful no-op. sqlite3_prepare_v2 with a
        // zero-length input returns OK with stmt=NULL; calling step()
        // on a NULL stmt is documented as harmless. Treat the whole
        // thing as a no-op up front to avoid the NULL-stmt edge case
        // and to make the documented behavior explicit at the wrapper
        // level (callers don't need to special-case "" themselves).
        if (sql.len == 0) return;

        const prepared = self.prepareForImmediateUse(sql) catch |err| {
            std.log.info("sqlite3 prepare failed: {s} (sql: {s})", .{ c.sqlite3_errmsg(db), sql });
            return err;
        };
        const stmt = prepared.stmt;
        const cached = prepared.cached;
        // ALWAYS close the statement before returning. A statement left at
        // SQLITE_ROW keeps an implicit READ TRANSACTION open on the
        // connection, and an open read transaction makes a following
        // `BEGIN IMMEDIATE` fail with SQLITE_BUSY *without* consulting
        // busy_timeout — it cannot upgrade the snapshot. `reset` ends it
        // (and hands a cached statement back ready for the next bind).
        defer if (cached) {
            _ = c.sqlite3_reset(stmt);
        } else {
            _ = c.sqlite3_finalize(stmt);
        };

        try bindArgsExec(stmt, argv);

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_ROW) {
                continue;
            } else if (rc == c.SQLITE_DONE) {
                break;
            } else {
                const err_msg = c.sqlite3_errmsg(db);
                std.log.info("sqlite3 step failed: {s} (sql: {s})", .{ err_msg, sql });
                return Error.ExecuteFailed;
            }
        }
    }

    /// Read `stmt`'s current row into an allocator-owned `Row`, in TWO
    /// allocations: the `values` slice, and one buffer holding every
    /// column's bytes back to back.
    ///
    /// The naive version allocated once per column, so a 3-column row cost
    /// four allocator calls and the same number of frees — on a path that
    /// runs per request and, for a list endpoint, per ROW. Callers see the
    /// same `Row.values` shape and the same `Row.deinit` contract.
    ///
    /// SQL NULL still maps to an empty slice, as everywhere else here.
    fn readRowPacked(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col_count: usize) Error!Row {
        const values = allocator.alloc([]u8, col_count) catch return Error.OutOfMemory;
        errdefer allocator.free(values);

        var total: usize = 0;
        for (0..col_count) |i| {
            total += @intCast(c.sqlite3_column_bytes(stmt, @intCast(i)));
        }
        const data = allocator.alloc(u8, total) catch return Error.OutOfMemory;
        errdefer allocator.free(data);

        var off: usize = 0;
        for (0..col_count) |i| {
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, @intCast(i)));
            if (c.sqlite3_column_text(stmt, @intCast(i))) |text| {
                @memcpy(data[off .. off + len], text[0..len]);
            }
            values[i] = data[off .. off + len];
            off += len;
        }

        return .{ .values = values, .arena = data };
    }

    pub fn exec(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return executeStatement(self, allocator, sql, argv);
    }

    /// Inner implementation: prepare + bind + step ONCE for a single-row
    /// SELECT. Caller MUST hold the backend mutex. Used by both `queryRow`
    /// (with lock) and `Transaction.queryRow` (without re-locking).
    fn executeQueryRow(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Row {
        // `prepareForImmediateUse` re-checks `self.db`, but do it here too:
        // `queryRow` before `init` must answer `DatabaseNotFound`, not
        // whatever prepare would report on a null handle.
        if (self.db == null) return Error.DatabaseNotFound;

        const prepared = try self.prepareForImmediateUse(sql);
        const stmt = prepared.stmt;
        defer if (prepared.cached) {
            _ = c.sqlite3_reset(stmt);
        } else {
            _ = c.sqlite3_finalize(stmt);
        };

        try bindArgsText(stmt, argv);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_ROW) {
            return Error.RowNotFound;
        }

        const col_count: usize = @intCast(c.sqlite3_column_count(stmt));
        return readRowPacked(allocator, stmt, col_count);
    }

    pub fn queryRow(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
        // A `queryRow` completes inside the lock, so it can borrow a pooled
        // reader for the duration of the call and hand it straight back —
        // no `Rows` outlives it, so no snapshot outlives it either.
        //
        // `needsWriteConnection` SQL (`last_insert_rowid()` and friends)
        // and an unavailable pool both fall back to the primary, which is
        // where a `Transaction` reads anyway (via `tx.queryRow`) so it
        // sees its own uncommitted writes.
        if (needsWriteConnection(sql) or !self.poolReady()) {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return executeQueryRow(self, allocator, sql, argv);
        }
        const slot = self.claimReader();
        if (slot == self) {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return executeQueryRow(self, allocator, sql, argv);
        }
        defer self.pool.release(self.io, slot);
        try slot.mutex.lock(slot.io);
        defer slot.mutex.unlock(slot.io);
        return executeQueryRow(slot, allocator, sql, argv);
    }

    pub const Rows = struct {
        allocator: std.mem.Allocator,
        stmt: ?*c.sqlite3_stmt,
        /// Non-owning reference to the db, captured at query time. Needed
        /// so that `next()` can call `sqlite3_errmsg(db)` when
        /// `sqlite3_step()` returns an error — the stmt pointer alone
        /// does not give access to the db handle. See `captureError`.
        db: ?*c.sqlite3,
        /// Player that owns the cached statement, when this iterator came
        /// from `query` (see `SqliteBackend.iterating`), OR the pooled
        /// reader this iterator holds exclusively.
        slot: ?*SqliteBackend = null,
        /// The pool `slot` must be returned to, when this iterator holds a
        /// pooled reader. null on the primary path (nothing to give back).
        ///
        /// The release happens in `deinit`, AFTER the statement is reset —
        /// that ordering is what guarantees the next reader of this
        /// connection starts a fresh read instead of inheriting the
        /// snapshot this iterator opened.
        pool: ?*ReaderPool = null,
        /// True when `stmt` belongs to the statement cache: `deinit` resets
        /// it for reuse instead of finalizing it.
        cached: bool = false,
        /// Tracks whether the iterator has reached SQLITE_DONE so that
        /// subsequent `next()` calls short-circuit to null without
        /// re-invoking `sqlite3_step()`. See `next` for the rationale.
        done: bool = false,
        /// Most recent SQLite error message, captured by `next()` when
        /// `sqlite3_step()` returns a non-ROW rc. Owned by Rows; freed
        /// in `deinit`. Callers can read it via `getLastErrorMessage()`
        /// to surface a USEFUL error to the user — without this, the
        /// only signal was the `Error.QueryFailed` enum name and the
        /// raw SQLite message was lost (logged but not returned).
        last_error_msg: ?[]u8 = null,

        pub fn deinit(self: *Rows) void {
            if (self.last_error_msg) |msg| {
                self.allocator.free(msg);
                self.last_error_msg = null;
            }
            if (self.stmt) |s| {
                if (self.cached) {
                    // Hand the statement back reset, and reopen the slot for
                    // the next cached iterator.
                    _ = c.sqlite3_reset(s);
                    if (self.slot) |slot| slot.iterating.store(false, .release);
                } else {
                    _ = c.sqlite3_finalize(s);
                }
            }
            self.stmt = null;
            // Give the reader back only now that its statement is closed —
            // otherwise the next read on this connection would be served
            // from the snapshot this iterator just finished reading.
            if (self.pool) |pool| {
                if (self.slot) |slot| pool.release(slot.io, slot);
            }
            self.pool = null;
            self.slot = null;
        }

        /// Capture `sqlite3_errmsg(db)` into `last_error_msg` so callers
        /// can surface it. Best-effort: silently no-ops when `db` is
        /// null (backend closed) or when allocation fails — the caller
        /// still gets the Error enum either way, this just enriches it.
        fn captureError(self: *Rows) void {
            if (self.db) |d| {
                const err_msg_c = c.sqlite3_errmsg(d);
                const span = std.mem.span(err_msg_c);
                if (self.last_error_msg) |old| self.allocator.free(old);
                self.last_error_msg = self.allocator.dupe(u8, span) catch null;
            }
        }

        /// Returns the most recent SQLite error message, or null if no
        /// error has been captured yet. The returned slice is owned by
        /// Rows and is valid until `deinit()` is called.
        pub fn getLastErrorMessage(self: *Rows) ?[]const u8 {
            return self.last_error_msg;
        }

        pub fn next(self: *Rows) Error!?Row {
            // Defensive: once we've returned null (DONE) for a query,
            // subsequent calls should keep returning null without
            // re-invoking sqlite3_step. Empirically, calling step()
            // after DONE on a SELECT can return ROW again (with the
            // same row data) on some SQLite versions/configurations —
            // which would surface as a duplicated final row in the
            // caller's loop. Track the done state explicitly so we
            // don't depend on sqlite's rc-after-DONE behavior.
            if (self.done) return null;
            const rc = c.sqlite3_step(self.stmt);
            if (rc == c.SQLITE_DONE) {
                self.done = true;
                return null;
            }
            if (rc == c.SQLITE_MISUSE) {
                // The statement has already returned DONE and step()
                // was called again. Treat the same as DONE.
                self.done = true;
                return null;
            }
            if (rc != c.SQLITE_ROW) {
                // Capture the SQL error message so callers can surface it
                // (e.g. "fts5: syntax error" instead of bare "QueryFailed").
                self.captureError();
                return Error.QueryFailed;
            }

            const stmt = self.stmt orelse return Error.DatabaseNotFound;
            const col_count: usize = @intCast(c.sqlite3_column_count(stmt));
            return try readRowPacked(self.allocator, stmt, col_count);
        }
    };

    pub const Row = struct {
        values: [][]u8,
        /// Backing buffer for the column bytes when the row was read with
        /// the packed reader: every `values[i]` is a slice of THIS one
        /// allocation, so `deinit` frees it once instead of walking the
        /// columns. null means the columns own separate allocations.
        ///
        /// Why it exists: a 3-column row used to cost four allocator calls
        /// (the values array plus one per column) on a path that runs once
        /// per request. Two is the floor without hand-rolling alignment,
        /// and it is what turns a 20-row list read from ~80 allocator calls
        /// into ~40.
        arena: ?[]u8 = null,

        pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
            if (self.arena) |buf| {
                allocator.free(buf);
            } else {
                for (self.values) |v| {
                    allocator.free(v);
                }
            }
            allocator.free(self.values);
        }
    };

    /// A database transaction. Mirrors Go's `sql.Tx` — acquire one via
    /// `SqliteBackend.begin()` (top-level) or `SqliteBackend.savepoint(name)`
    /// (nested). Run statements with the tx methods, then `commit()` to make
    /// changes permanent or `rollback()` to discard them.
    ///
    /// **Mutex semantics:** The `SqliteBackend.mutex` is acquired and held
    /// for the entire lifetime of the transaction. Concurrent `exec`/`query`
    /// calls from other threads block until `commit()`/`rollback()` releases
    /// it. DO NOT call `db.exec()` / `db.query()` from within the same thread
    /// that holds a tx — `std.Io.Mutex` is NOT reentrant; calling a
    /// lock-acquiring method on the backend from inside `tx.exec` will
    /// deadlock. Use `tx.exec` / `tx.query` / `tx.queryRow` instead.
    ///
    /// **Single-use:** All methods (`exec`, `query`, `queryRow`, `commit`,
    /// `rollback`) return `Error.TransactionClosed` if called after a
    /// successful `commit()` or `rollback()`. This is a SAFETY check, not
    /// ergonomics: after the mutex is released by commit/rollback, any
    /// further `tx.*` call would invoke SQL on the underlying connection
    /// WITHOUT the mutex held, racing with concurrent writers. Returning an
    /// error prevents the UB. The recommended idiom is:
    ///
    /// ```zig
    /// var tx = try db.begin();
    /// defer tx.rollback() catch |err| switch (err) {
    ///     error.TransactionClosed => {}, // already committed/rolled back
    ///     else => return err,
    /// };
    /// ```
    ///
    /// The `defer tx.rollback() catch |err| switch(err) { error.TransactionClosed => {}, ... }`
    /// pattern mirrors Go's `defer tx.Rollback()` (which silently succeeds
    /// on `sql.ErrTxDone`); the explicit switch is required because Zig
    /// surfaces all errors.
    ///
    /// **Borrowed slices:** As with the non-tx `Row` type, slices returned
    /// from `tx.queryRow()` / `tx.query()` are allocated by the caller's
    /// allocator; the caller must call `Row.deinit(allocator)` to free them.
    pub const Transaction = struct {
        backend: *SqliteBackend,
        depth: u32,
        completed: bool = false,

        pub fn exec(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!void {
            if (self.completed) return Error.TransactionClosed;
            return executeStatement(self.backend, allocator, sql, argv);
        }

        pub fn queryRow(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Row {
            if (self.completed) return Error.TransactionClosed;
            return executeQueryRow(self.backend, allocator, sql, argv);
        }

        pub fn query(self: *Transaction, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
            if (self.completed) return Error.TransactionClosed;
            return executeQuery(self.backend, allocator, sql, argv);
        }

        /// Internal helper: run COMMIT (or RELEASE sp_<n> for nested tx),
        /// decrement depth, release the mutex on the outermost commit,
        /// and flip `completed`. Shared between `commit` (which gates
        /// on `completed` first and returns `TransactionClosed` on
        /// re-finalization) and `commitOrRollback` (which silently
        /// no-ops on re-finalization).
        ///
        /// MUST NOT be called directly — callers are `commit` and
        /// `commitOrRollback`, which both gate on `self.completed`
        /// BEFORE calling this helper. Calling without the gate
        /// would skip the re-finalization check and could release
        /// the mutex twice (UB).
        fn _doFinalizeCommit(self: *Transaction) Error!void {
            const db = self.backend.db orelse {
                self.completed = true;
                // On backend-closed: depth is a property of the backend
                // (not the connection), so we decrement it for consistency.
                // Only release the mutex on the outermost commit/rollback —
                // inner savepoints hold the mutex on behalf of the outer tx.
                self.backend.transaction_depth -= 1;
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.DatabaseNotFound;
            };

            // SQL depends on depth:
            //   depth == 1 → top-level COMMIT
            //   depth >= 2 → RELEASE for the matching SAVEPOINT
            var sql_buf: [32:0]u8 = undefined;
            const sql_slice = if (self.depth == 1)
                std.fmt.bufPrint(sql_buf[0..31], "COMMIT", .{}) catch return Error.ExecuteFailed
            else
                std.fmt.bufPrint(sql_buf[0..31], "RELEASE sp_{d}", .{self.depth}) catch
                    return Error.ExecuteFailed;
            sql_buf[sql_slice.len] = 0;

            const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
            self.completed = true;
            self.backend.transaction_depth -= 1;
            // Only the OUTERMOST commit releases the mutex. An inner
            // savepoint commit (depth >= 2) leaves the mutex held so
            // the surrounding outer transaction can keep using it.
            if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);

            if (rc != c.SQLITE_OK) {
                return Error.ExecuteFailed;
            }
        }

        pub fn commit(self: *Transaction) Error!void {
            if (self.completed) return Error.TransactionClosed;
            return self._doFinalizeCommit();
        }

        /// Commit the transaction if it has not yet been finalized. If the
        /// transaction was already committed or rolled back, this is a no-op
        /// returning success (NOT `Error.TransactionClosed` — that would defeat
        /// the point of the defer-idiom). Mirrors Go's
        /// `(*Tx).CommitOrRollback` (Go 1.21+).
        ///
        /// The recommended defer-idiom for transactions (canonical pattern):
        ///
        /// ```zig
        /// var tx = try db.begin();
        /// defer tx.commitOrRollback() catch {};
        /// errdefer tx.rollback() catch {}; // atomic: error paths roll back
        /// try tx.exec(alloc, "INSERT INTO foo VALUES (?)", &.{"a"});
        /// try tx.commit();
        /// ```
        ///
        /// The `defer` is a safety net (finalizes on early return), the
        /// explicit `commit()` is the happy-path finalize. If `commit()`
        /// already ran, the deferred `commitOrRollback()` is a silent
        /// no-op. The `errdefer` keeps error paths atomic: Zig runs
        /// defers LIFO, so on error `rollback()` fires first and the
        /// deferred commit becomes a no-op. Without it, the deferred
        /// commit would persist a partial prefix. Do NOT issue raw "BEGIN"/"COMMIT"/"ROLLBACK" via
        /// `db.exec()` — that bypasses the mutex + depth tracking.
        ///
        /// This replaces the more verbose pattern:
        ///
        /// ```zig
        /// defer tx.rollback() catch |err| switch (err) {
        ///     error.TransactionClosed => {}, // already committed
        ///     else => return err,
        /// };
        /// ```
        ///
        /// **Why use commitOrRollback instead of `commit` in defer?**
        /// Because if your code path called `commit()` explicitly before the
        /// defer fired, `commitOrRollback` is a silent no-op — whereas
        /// `tx.commit()` would return `Error.TransactionClosed` (and the catch
        /// would log it). Both are correct; commitOrRollback is just
        /// ergonomically cleaner for the deferred-finalize pattern.
        ///
        /// **Why use commitOrRollback instead of `rollback` in defer?**
        /// Same reason: if `commit()` ran before the defer fired,
        /// `rollback()` returns `Error.TransactionClosed`. The
        /// `defer rollback() catch switch(TransactionClosed => {})` pattern
        /// works but is verbose.
        ///
        /// **Error semantics:**
        /// - If the COMMIT (or RELEASE for nested tx) SQL fails: returns
        ///   `Error.ExecuteFailed`. `completed` is set so a future
        ///   `rollback()` returns `TransactionClosed`.
        /// - If the backend was deinitialized during the tx: returns
        ///   `Error.DatabaseNotFound`.
        /// - Otherwise: returns success.
        pub fn commitOrRollback(self: *Transaction) Error!void {
            if (self.completed) return; // already finalized — silent no-op
            return self._doFinalizeCommit();
        }

        pub fn rollback(self: *Transaction) Error!void {
            if (self.completed) return Error.TransactionClosed;
            const db = self.backend.db orelse {
                self.completed = true;
                self.backend.transaction_depth -= 1;
                // Same depth-gated mutex release as commit(): only the
                // outermost rollback actually frees the lock.
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.DatabaseNotFound;
            };

            var sql_buf: [32:0]u8 = undefined;
            const sql_slice = if (self.depth == 1)
                std.fmt.bufPrint(sql_buf[0..31], "ROLLBACK", .{}) catch return Error.ExecuteFailed
            else
                std.fmt.bufPrint(sql_buf[0..31], "ROLLBACK TO sp_{d}", .{self.depth}) catch
                    return Error.ExecuteFailed;
            sql_buf[sql_slice.len] = 0;

            const rc = c.sqlite3_exec(db, &sql_buf, null, null, null);
            self.completed = true;
            self.backend.transaction_depth -= 1;
            // See commit() above — inner savepoint rollback must NOT
            // release the mutex; the outer transaction is still alive.
            if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);

            if (rc != c.SQLITE_OK) {
                return Error.ExecuteFailed;
            }
        }
    };

    /// Inner implementation: prepare + bind a SELECT statement, returning
    /// a `Rows` iterator. Caller MUST hold the backend mutex. Used by
    /// both `query` (with lock) and `Transaction.query` (without re-locking).
    fn executeQuery(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Rows {
        const db = self.db orelse return Error.DatabaseNotFound;

        // NOT served from `stmt_cache`. A `Rows` keeps using its statement
        // after this function unlocks, so a cached statement could be reset
        // by a second `query` on the same connection while the first
        // iterator is still mid-result. `exec` / `queryRow` finish inside
        // the lock and are safe to cache; an iterator is not, so it keeps
        // its own statement.
        var stmt: ?*c.sqlite3_stmt = null;
        const prep_rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (prep_rc != c.SQLITE_OK) {
            return Error.PrepareFailed;
        }

        if (stmt) |s| {
            bindArgsText(s, argv) catch |err| {
                _ = c.sqlite3_finalize(s);
                return err;
            };
        }

        return Rows{
            .allocator = allocator,
            .stmt = stmt,
            .db = db,
        };
    }

    /// `query` body for a connection that may hand out its CACHED
    /// statement. Falls back to a one-shot statement when the cache must
    /// not be touched: a non-DML/SELECT text, or another iterator already
    /// using this connection's cached statement. Caller holds the lock.
    fn executeQueryMaybeCached(
        slot: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Rows {
        const db = slot.db orelse return Error.DatabaseNotFound;
        if (!cacheableSql(sql)) return executeQuery(slot, allocator, sql, argv);

        if (slot.iterating.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            // Someone else is already stepping this connection's cached
            // statement; a second live iterator needs its own.
            return executeQuery(slot, allocator, sql, argv);
        }
        errdefer slot.iterating.store(false, .release);

        const stmt = try slot.stmt_cache.acquire(db, sql);
        try bindArgsText(stmt, argv);
        return Rows{
            .allocator = allocator,
            .stmt = stmt,
            .db = db,
            .slot = slot,
            .cached = true,
        };
    }

    pub fn query(self: *SqliteBackend, allocator: std.mem.Allocator, sql: []const u8, argv: []const []const u8) Error!Rows {
        // The lock is released here, not in `Rows.deinit`. Holding it for
        // the whole iteration would be faster (no two threads stepping one
        // sqlite3 handle), but it would turn a caller that forgets `deinit`
        // into a permanently stalled connection — and "you only leak a
        // statement" is the contract existing callers were written against.
        //
        // That is also why the pooled path hands the reader to the `Rows`
        // INSTEAD of returning it to the idle list: the connection's read
        // transaction stays open while the caller steps, and handing it to
        // anybody else would serve them that same pinned snapshot. The
        // `Rows` returns it in `deinit`, after `sqlite3_reset` has ended
        // the transaction.
        if (needsWriteConnection(sql) or !self.poolReady()) {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return executeQueryMaybeCached(self, allocator, sql, argv);
        }
        const slot = self.claimReader();
        if (slot == self) {
            // Pool could not grow: serve the read on the write connection,
            // which is shared — so take the cached-statement guard.
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            return executeQueryMaybeCached(self, allocator, sql, argv);
        }
        errdefer self.pool.release(self.io, slot);
        try slot.mutex.lock(slot.io);
        defer slot.mutex.unlock(slot.io);
        // One-shot statement: the slot is exclusively ours, so there is
        // nothing to gain from the cache and no one to collide with.
        var rows = try executeQuery(slot, allocator, sql, argv);
        rows.pool = &self.pool;
        rows.slot = slot;
        rows.cached = false;
        return rows;
    }

    // ─── Prepared-statement cache ───────────────────────────────────────
    //
    // `exec` and `queryRow` used to `sqlite3_prepare_v2` + `sqlite3_finalize`
    // on EVERY call. For a server that runs the same handful of statements
    // per request, the parse + bytecode generation + teardown costs more
    // than executing the statement — a point read spent most of its time
    // re-compiling itself.
    //
    // Both now go through `stmt_cache`, keyed by SQL text, and the savings
    // are transparent: `exec` / `queryRow` keep their exact signatures,
    // semantics and ownership rules, so every existing caller speeds up
    // without changing a line.
    //
    // `query` deliberately does NOT use the cache: a `Rows` iterator keeps
    // stepping its statement AFTER `query` releases the mutex, so two live
    // iterators on one connection would fight over a single cached
    // statement. `exec` / `queryRow` complete inside the lock, which is
    // what makes them safe to share.

    /// Statements the cache is allowed to hold: a SELECT or a DML
    /// statement (INSERT / UPDATE / DELETE / REPLACE).
    ///
    /// DDL and PRAGMA are deliberately excluded. Two reasons, both
    /// observed rather than theoretical:
    ///
    ///   - Re-running DDL is an ERROR case (`CREATE TABLE` twice). With a
    ///     cached statement the failure moves from prepare time to step
    ///     time, which would silently change `Error.PrepareFailed` into
    ///     `Error.ExecuteFailed` for existing callers.
    ///   - A PRAGMA's result depends on connection state, so reusing one
    ///     statement for it is not obviously equivalent.
    ///
    /// The statements that make a server hot — point reads, range reads,
    /// inserts, updates, deletes — are all in. Leading `WITH` (a CTE) is
    /// not recognised and simply runs uncached.
    fn cacheableSql(sql: []const u8) bool {
        var i: usize = 0;
        while (i < sql.len and switch (sql[i]) {
            ' ', '\t', '\n', '\r' => true,
            else => false,
        }) : (i += 1) {}
        const rest = sql[i..];
        const keywords = [_][]const u8{ "select", "insert", "update", "delete", "replace" };
        for (keywords) |kw| {
            if (rest.len < kw.len) continue;
            var matches = true;
            for (kw, 0..) |ch, j| {
                if (std.ascii.toLower(rest[j]) != ch) {
                    matches = false;
                    break;
                }
            }
            if (matches) return true;
        }
        return false;
    }

    /// Prepare a statement the cache must not keep (DDL / PRAGMA / anything
    /// unrecognised). The caller finalizes it.
    fn prepareOneShot(db: *c.sqlite3, sql: []const u8) Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return Error.PrepareFailed;
        return stmt.?;
    }

    /// Bind `argv` for a WRITE: an empty slice binds SQL NULL. This is the
    /// package's documented convention for `exec` (an INSERT of `""` stores
    /// NULL, and a NOT NULL column rejects it) and it is unchanged.
    fn bindArgsExec(stmt: *c.sqlite3_stmt, argv: []const []const u8) Error!void {
        for (argv, 0..) |arg, i| {
            const idx: c_int = @intCast(i + 1);
            const rc = if (arg.len == 0)
                c.sqlite3_bind_null(stmt, idx)
            else
                sqlite3_bind_text_isize(@ptrCast(stmt), idx, arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
            if (rc != c.SQLITE_OK) return Error.BindFailed;
        }
    }

    /// Bind `argv` for a READ: every argument is bound as TEXT, so an empty
    /// slice is an empty STRING — not NULL.
    ///
    /// This asymmetry with `bindArgsExec` is deliberate and load-bearing.
    /// `query` / `queryRow` have always bound this way, and callers rely on
    /// it for the "optional filter" idiom:
    ///
    /// ```sql
    /// SELECT … FROM t WHERE (? = '' OR id = ?)
    /// ```
    ///
    /// with the unused filter passed as `""`. Under `bindArgsExec` that `""`
    /// becomes NULL, `NULL = ''` is NULL rather than true, the WHERE clause
    /// evaluates to NULL, and the query silently returns NO ROWS instead of
    /// ignoring the filter. (`exec` binding `""` as NULL is the documented
    /// write-side behaviour and stays.)
    fn bindArgsText(stmt: *c.sqlite3_stmt, argv: []const []const u8) Error!void {
        for (argv, 0..) |arg, i| {
            const rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
            if (rc != c.SQLITE_OK) return Error.BindFailed;
        }
    }

    /// Per-connection cache of prepared statements, keyed by SQL text.
    ///
    /// Entries live until `SqliteBackend.deinit`. A cached statement is
    /// handed to exactly one caller at a time (the backend mutex is what
    /// guarantees that) and `acquire` resets it before returning.
    ///
    /// The SQL text is duplicated as the map key, so callers may pass a
    /// temporary / stack / per-request-arena slice.
    ///
    /// The keys are tiny (one copy of each distinct statement a caller
    /// uses) and there are a handful per connection, so the cache owns them
    /// through `std.heap.smp_allocator` — a thread-safe allocator with no
    /// deinit obligation. That keeps `init`'s signature (and therefore
    /// every existing call site) unchanged.
    const StmtCache = struct {
        map: std.StringHashMapUnmanaged(*c.sqlite3_stmt) = .empty,

        const allocator: std.mem.Allocator = std.heap.smp_allocator;

        /// Finalize every cached statement. Called by `deinit`.
        pub fn deinit(self: *StmtCache) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                _ = c.sqlite3_finalize(entry.value_ptr.*);
                allocator.free(entry.key_ptr.*);
            }
            self.map.deinit(allocator);
            self.map = .empty;
        }

        /// How many distinct statements this connection has cached.
        pub fn count(self: *const StmtCache) usize {
            return self.map.count();
        }

        /// Hand out the statement for `sql`, reset and ready to bind.
        /// Prepares + caches it on first use.
        fn acquire(self: *StmtCache, db: *c.sqlite3, sql: []const u8) Error!*c.sqlite3_stmt {
            if (self.map.get(sql)) |stmt| {
                _ = c.sqlite3_reset(stmt);
                _ = c.sqlite3_clear_bindings(stmt);
                return stmt;
            }
            var stmt: ?*c.sqlite3_stmt = null;
            // SQLITE_PREPARE_PERSISTENT tells the planner this text will be
            // reused; without it SQLite avoids caching lookaside buffers
            // (it assumes the statement is short-lived).
            const rc = c.sqlite3_prepare_v3(
                db,
                sql.ptr,
                @intCast(sql.len),
                c.SQLITE_PREPARE_PERSISTENT,
                &stmt,
                null,
            );
            if (rc != c.SQLITE_OK) return Error.PrepareFailed;
            const key = allocator.dupe(u8, sql) catch {
                _ = c.sqlite3_finalize(stmt);
                return Error.OutOfMemory;
            };
            self.map.put(allocator, key, stmt.?) catch {
                allocator.free(key);
                _ = c.sqlite3_finalize(stmt);
                return Error.OutOfMemory;
            };
            return stmt.?;
        }
    };

    pub fn deinit(self: *SqliteBackend) void {
        // Reader connections are owned by this backend; close them with it.
        if (self.pool.enabled) self.pool.closeAll(self.io);
        // Finalize cached statements BEFORE closing the connection —
        // sqlite3_finalize needs the statements to still be valid.
        self.stmt_cache.deinit();
        if (self.db) |d| {
            _ = c.sqlite3_close(d);
        }
        // CRITICAL: null out `db` after closing so the Transaction code's
        // `self.backend.db == null` use-after-free guard actually fires.
        // Without this, the pointer dangles and any subsequent operation
        // would dereference freed memory.
        self.db = null;
    }

    /// Begin a new top-level transaction on this backend. Returns a
    /// `Transaction` whose `exec`/`query` methods operate inside the
    /// transaction until `commit()` or `rollback()` is called.
    ///
    /// The backend's mutex is acquired and held for the entire transaction
    /// lifetime. Concurrent `exec`/`query` calls on the same backend
    /// (from other threads) block until the transaction ends.
    ///
    /// Returns `Error.DatabaseNotFound` if the backend is not initialized.
    /// Returns `Error.ExecuteFailed` if the underlying `BEGIN` SQL fails
    /// (e.g. already inside a transaction — should not happen if the
    /// caller respects the mutex contract).
    ///
    /// Cancel-safe: if the Io runtime cancels mid-`lock()`, returns
    /// `error.Canceled` without acquiring the lock or starting a tx.
    pub fn begin(self: *SqliteBackend) Error!Transaction {
        if (self.db == null) return Error.DatabaseNotFound;

        // Acquire the mutex BEFORE issuing BEGIN. This is the critical
        // correctness invariant: while the tx is alive, no other
        // backend.exec / backend.query call can interleave.
        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);

        // BEGIN IMMEDIATE, not plain BEGIN. This is not a style preference.
        //
        // A DEFERRED transaction takes a read snapshot on its first SELECT
        // and only asks for the write lock when it first WRITES. If any
        // other connection committed in between, SQLite cannot replay the
        // reads for the caller, so it returns SQLITE_BUSY_SNAPSHOT —
        // reported as "database is locked", returned IMMEDIATELY, and the
        // busy handler is deliberately NOT consulted (there is no safe
        // retry). Reproduced against SQLite 3.53.4:
        //
        //   H2 deferred-BEGIN read-then-write: database is locked (0.0000s)
        //
        // So every transaction that reads before it writes was a coin flip
        // against any other process on the same file. BEGIN IMMEDIATE takes
        // the write lock up front, where `busy_timeout` DOES apply, and the
        // wait is honoured.
        //
        // A read-only transaction now also holds the write slot for its
        // lifetime. Call `beginDeferred()` if you genuinely need the old
        // semantics.
        //
        // On any failure, the errdefer releases the mutex.
        const rc = c.sqlite3_exec(self.db.?, "BEGIN IMMEDIATE", null, null, null);
        if (rc != c.SQLITE_OK) {
            return Error.ExecuteFailed;
        }

        // Track depth BEFORE returning the Transaction so commit/rollback
        // can choose the correct SQL (COMMIT vs RELEASE sp_<n>).
        self.transaction_depth += 1;
        return Transaction{
            .backend = self,
            .depth = self.transaction_depth,
            .completed = false,
        };
    }

    /// Begin a DEFERRED transaction — plain `BEGIN`, taking the write lock
    /// lazily at the first write.
    ///
    /// ⚠️ This is the pre-`BEGIN IMMEDIATE` behaviour and it is a trap: a
    /// transaction that reads, has another connection commit, and then
    /// writes fails IMMEDIATELY with `ExecuteFailed` ("database is locked"),
    /// ignoring `busy_timeout` entirely (SQLITE_BUSY_SNAPSHOT — the reads
    /// cannot be replayed, so there is no safe retry).
    ///
    /// Only use it when the transaction provably never writes — a read-only
    /// report, say. Anything that writes should use `begin()`.
    pub fn beginDeferred(self: *SqliteBackend) Error!Transaction {
        if (self.db == null) return Error.DatabaseNotFound;

        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);

        const rc = c.sqlite3_exec(self.db.?, "BEGIN", null, null, null);
        if (rc != c.SQLITE_OK) {
            return Error.ExecuteFailed;
        }

        self.transaction_depth += 1;
        return Transaction{
            .backend = self,
            .depth = self.transaction_depth,
            .completed = false,
        };
    }

    /// Open a nested savepoint within the current transaction. Must be
    /// called WHILE a tx is already open (i.e. between `begin()` /
    /// `savepoint()` and the corresponding `commit()` / `rollback()`).
    ///
    /// Savepoints let you roll back PART of a transaction without
    /// discarding the whole thing — useful for "try this batch, discard
    /// if it fails, keep going" patterns.
    ///
    /// The savepoint is named `sp_<depth>` (auto-generated based on the
    /// current depth). The returned Transaction's `depth` field is >= 2.
    ///
    /// **Caller must hold an active transaction.** Calling `savepoint()`
    /// when `transaction_depth == 0` returns `Error.ExecuteFailed`
    /// (SQLite rejects SAVEPOINT outside an outer tx).
    pub fn savepoint(self: *SqliteBackend) Error!Transaction {
        if (self.db == null) return Error.DatabaseNotFound;
        if (self.transaction_depth == 0) return Error.ExecuteFailed;

        // Mutex is already held by the outer tx — do NOT re-lock.

        self.transaction_depth += 1;
        const new_depth = self.transaction_depth;

        // Build a NUL-terminated SAVEPOINT name. We use a fixed-size
        // sentinel-terminated buffer because sqlite3_exec takes a C string.
        // `sql_buf[0..31]` is `[]u8` (what bufPrint expects); the 32nd byte
        // holds the NUL sentinel we set after formatting.
        var sql_buf: [32:0]u8 = undefined;
        const sql_slice = std.fmt.bufPrint(sql_buf[0..31], "SAVEPOINT sp_{d}", .{new_depth}) catch
            return Error.ExecuteFailed;
        sql_buf[sql_slice.len] = 0;

        const rc = c.sqlite3_exec(self.db.?, &sql_buf, null, null, null);
        if (rc != c.SQLITE_OK) {
            self.transaction_depth -= 1;
            return Error.ExecuteFailed;
        }

        return Transaction{
            .backend = self,
            .depth = new_depth,
            .completed = false,
        };
    }

    /// Number of rows changed by the most recent INSERT/UPDATE/DELETE
    /// statement. Used by callers that need to know whether their
    /// `db.exec` actually matched any rows (the API doesn't return the
    /// change count directly). See `sqlite3_changes` in the C API.
    /// Caller is responsible for being on the same thread (or holding
    /// the mutex) as the most recent write — the count is per-connection
    /// state in SQLite, not per-statement.
    pub fn changes(self: *SqliteBackend) i64 {
        const db = self.db orelse return 0;
        return c.sqlite3_changes(db);
    }
};
