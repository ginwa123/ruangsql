//! SQLite backend for every nalar database: `exec` / `query` / `queryRow`, plus a `Transaction` RAII type for multi-statement atomic work.
//! See `sqlite_test.zig` for the canonical API doc; the `c` declarations are platform-scoped (Linux `@cImport`, macOS/Windows manual externs).

const std = @import("std");
const builtin = @import("builtin");

// Destructor parameter declared as `isize` because the Zig comptime alignment check rejects `-1` (SQLITE_TRANSIENT) through the cImport function-pointer type on aarch64-macos.
// At the C ABI level both occupy one 8-byte register, so the bits pass through unchanged and the SQLite `xDel == SQLITE_TRANSIENT` comparison still succeeds. `orelse unreachable` is safe: the symbol is statically linked everywhere.
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

/// Connection policy applied to every `SqliteBackend` at `init`; the defaults are chosen so a caller that passes `{}` gets a connection that survives contention instead of losing writes.
pub const Config = struct {
    busy_timeout_ms: u32 = 15_000,
    synchronous: Synchronous = .full,
    journal_size_limit_bytes: i64 = 64 * 1024 * 1024,
    wal_autocheckpoint_pages: u32 = 1_000,
    /// Page cache for THIS connection, in KiB (`PRAGMA cache_size = -N`). Default 8 MiB; SQLite ships 2 MiB. 0 leaves the SQLite default.
    /// The cache is per connection, so a pool of N connections spends N x this.
    cache_size_kb: u32 = 8_000,
    /// Extra READ connections `init` opens alongside the primary one: WAL gives a database MANY concurrent readers and exactly ONE writer, and a single connection serialises every read behind one mutex.
    /// 0 = no pooling (single-connection behaviour). Default 7 -> 8 connections total, sized to a typical 2-8 core runtime.
    read_conns: usize = 7,
    /// Ceiling on the reader pool. 0 = UNLIMITED (the default): a read that finds every reader busy opens another connection rather than queueing, so read concurrency is bounded by in-flight reads.
    /// MUST be at least `read_conns`; a value at or below it is treated as `read_conns` (see `ReaderPool.effectiveCap`). Raise it only to bound memory: each reader spends its own `cache_size_kb` plus `mmap_size_bytes`.
    max_read_conns: usize = 0,
    /// How long a read waits for a pooled reader to come free before falling back to the primary connection. Default 5 s. 0 = never wait.
    /// Serving a read on the WRITE connection delays the `BEGIN IMMEDIATE` of unrelated writers into their own `busy_timeout` ("database is locked"), so the pool waits instead.
    reader_wait_ms: u32 = 5_000,
    /// How long an idle reader above the warm floor may sit before the pool closes it. 0 = reap on the next `release` / `claim` / `reapIdle` pass. Default 60 s.
    /// The pool never shrinks below `read_conns` (the warm floor), and a CLAIMED reader is never reaped: only entries sitting in the idle list past this age are closed.
    max_idle_time_ms: u64 = 60_000,
    /// Minimum gap between two reaping passes, in milliseconds. 0 = derive it from `max_idle_time_ms` (a quarter of it, floored at 1 s).
    /// The inline passes are traffic-driven, so a consumer that goes quiet never triggers one and its pool stays fat: the tick needs to know the interval. `reapIdleThrottled` honours it (tick blindly on any cadence); `reapIdle` always runs.
    reap_interval_ms: u64 = 0,
    /// `PRAGMA mmap_size` in bytes: read the database through a memory mapping instead of `read()`. 0 leaves the SQLite default (no mmap).
    /// Pages still come from the OS file cache, but each page hit skips a syscall and a copy; it is not anonymous memory, so it does not count against a container `memory.max`. Default 256 MiB window.
    mmap_size_bytes: u64 = 256 * 1024 * 1024,
    /// Allocator for the reader pool connections, its index lists, and each connection prepared-statement cache. null (the default) uses `std.heap.smp_allocator`.
    /// CONSTRUCTOR lifetime, NOT the row-lifetime allocator `query` / `exec` take: a pooled reader outlives the request that opened it, so a request arena would leave `slots` holding a pointer into freed memory.
    allocator: ?std.mem.Allocator = null,
};

/// What `readConfig` observed on the connection. Printed by consumers at boot so a future "database is locked" report carries the live settings instead of a guess.
pub const ActiveConfig = struct {
    /// The journal-mode names SQLite reports all fit in 16 bytes; a fixed buffer keeps `ActiveConfig` allocation-free (it exists for one log line and must not hand out an ownership obligation).
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
    /// The reader pool is at `Config.max_read_conns` with every reader busy. Only reachable when `max_read_conns` is non-zero; the default is unlimited, so the pool opens another connection instead.
    PoolExhausted,
    RowNotFound,
    OutOfMemory,
    Canceled,
    /// Returned by any Transaction method called after the transaction has been completed: the mutex is no longer held, so any further use would race with concurrent writers on the same backend. The tx is single-use.
    /// Recommended defer pattern: `defer tx.rollback() catch |err| switch (err) { error.TransactionClosed => {}, else => return err };`
    TransactionClosed,
};

/// File descriptors one pooled reader holds: 2 (the database file and its `-wal`). The `-shm` WAL index is one shared-memory segment per PROCESS per database file, so it is paid once for the whole pool.
/// The `c` declarations are scoped INSIDE `SqliteBackend`, resolved lazily: `@cImport` needs sqlite3.h on the include path when the import resolves, and on macOS the system header is keg-only.
pub const FDS_PER_READER: usize = 2;

/// Descriptors reserved for everything that is NOT a pooled reader: listening sockets, one per connected SSE client, open source files, subprocess pipes.
/// It is the reserve for a HEALTHY budget: `readerCapForSoftLimit` scales it down rather than spending a reserve the process does not have.
pub const FD_HEADROOM: usize = 256;

/// How long a write-connection fallback stays quiet after it has been logged once.
/// The fallback is a property of the POOL being saturated, not of any one read: a burst would otherwise print one line per read and bury the log, so one line per interval keeps the signal.
pub const FALLBACK_LOG_INTERVAL_MS: i64 = 60_000;

/// Longest single park inside `ReaderPool.waitForReaderLocked`: a waiter wakes on this slice even when nothing signalled it, so it re-reads the clock and can honour its budget.
/// Short enough that an idle reader handed back is picked up promptly, long enough that a saturated pool does not spin.
pub const MAX_WAIT_SLICE_MS: i64 = 250;

/// How many readers this process can afford, derived from its actual soft `RLIMIT_NOFILE`. This is the hard ceiling the pool obeys even when `Config.max_read_conns == 0`: "unlimited" means bounded by the resource, not by nothing.
/// Running out of descriptors makes `sqlite3_open` return SQLITE_CANTOPEN, surfacing as `unable to open database file` on a `PRAGMA journal_mode = WAL`, which reads like a path or permissions problem and is neither.
pub fn fdDerivedReaderCap() usize {
    if (builtin.os.tag == .windows) return 32; // no RLIMIT_NOFILE to read
    // `cur` is the SOFT limit — the one actually enforced, and the one a
    // `ulimit -n` in a launcher script would have lowered.
    const lim = std.posix.getrlimit(std.posix.rlimit_resource.NOFILE) catch return 32;
    return readerCapForSoftLimit(@intCast(lim.cur));
}

/// The reader-pool ceiling for a process whose soft `RLIMIT_NOFILE` is `soft`. The reserve shrinks to half the budget instead of collapsing the ceiling to 1, so a constrained process such as macOS (soft limit 256 = `FD_HEADROOM`) still gets a usable pool.
/// For any budget at or above `2 * FD_HEADROOM` this is the original rule, so an unconstrained process keeps the exact ceiling it had.
pub fn readerCapForSoftLimit(soft: usize) usize {
    const headroom = @min(FD_HEADROOM, soft / 2);
    const affordable = (soft - headroom) / FDS_PER_READER;
    return @max(affordable, 1);
}

pub const SqliteBackend = struct {
    const c = @cImport(@cInclude("sqlite3.h"));

    // `SQLITE_TRANSIENT` sentinel, passed as -1 via the `sqlite3_bind_text_isize` wrapper above (which takes `isize` instead of the cImport `sqlite3_destructor_type`). See the wrapper comment for why.
    const SQLITE_DESTRUCTOR_TRANSIENT: isize = -1;

    io: std.Io = .failing,
    db: ?*c.sqlite3 = null,
    mutex: std.Io.Mutex = .init,
    /// Current transaction nesting depth: 0 = no tx, 1 = top-level BEGIN in flight, 2+ = nested SAVEPOINT. Incremented by `begin` / `savepoint`, decremented by `commit` / `rollback`.
    /// It chooses between `BEGIN` / `COMMIT` (depth 0<->1) and `SAVEPOINT` / `RELEASE` / `ROLLBACK TO` (depth >= 1).
    transaction_depth: u32 = 0,

    /// Per-connection prepared-statement cache. Filled by `exec` /
    /// `queryRow` on first use of each SQL text.
    stmt_cache: StmtCache = .{},

    /// Elastic pool of extra READ-ONLY connections; empty / `enabled == false` when `Config.read_conns == 0` or the path is `:memory:`, in which case every statement runs on the primary connection.
    /// WHY CLAIM/RELEASE AND NOT ROUND-ROBIN: a `Rows` keeps stepping after `query` returns, and an open statement pins a read transaction to its snapshot (SQLite allows one per connection), so a reader is owned exclusively by one read until its statement is reset.
    pool: ReaderPool = .{},

    /// True while a `Rows` is stepping THIS backend's own CACHED statement. Only the primary connection needs it (a pooled reader is exclusively owned); it matters there when pooling is off or for `needsWriteConnection` SQL.
    /// Without it, `exec` / `queryRow` would `sqlite3_reset` + `sqlite3_clear_bindings` the statement a live iterator is stepping and rebind it to their own arguments.
    iterating: std.atomic.Value(bool) = .init(false),

    /// Reads served on this backend's own connection because the reader
    /// pool could not supply one. Read `readFallbackCount`.
    fallbacks: std.atomic.Value(u64) = .init(0),

    /// Monotonic timestamp (ms) of the last write-connection fallback warning, so a saturated pool reports once per interval instead of once per read.
    fallback_logged_ms: std.atomic.Value(i64) = .init(0),

    /// This connection's index in its pool's `slots`, or null when it is not pooled (the primary connection). Exists so `release` is O(1) instead of a linear scan of every open reader.
    /// Owned by the pool and guarded by the pool mutex; readers are exclusively owned, so no other thread can be looking at it.
    pool_index: ?usize = null,

    /// Open `db_path` with the default `Config`. Same as
    /// `initWithConfig(io, db_path, .{})`.
    pub fn init(self: *SqliteBackend, io: std.Io, db_path: [:0]const u8) Error!void {
        return self.initWithConfig(io, db_path, .{});
    }

    /// Open `db_path` and immediately apply `cfg` to the connection.
    /// WAL is re-asserted here as well: `PRAGMA journal_mode` needs a brief exclusive lock to CHANGE mode, but re-asserting it on a database already in WAL is a no-op that does not contend, so this stays a complete description of the connection.
    pub fn initWithConfig(
        self: *SqliteBackend,
        io: std.Io,
        db_path: [:0]const u8,
        cfg: Config,
    ) Error!void {
        try openSingle(self, io, db_path, cfg);

        // Reads get their own connections. Best-effort: if the extra connections cannot be opened, the backend still works exactly like the single-connection version rather than failing to start.
        if (cfg.read_conns == 0) return;
        // An in-memory database belongs to the CONNECTION that opened it, so a second connection would see an empty, unrelated database: `:memory:` always stays on one connection.
        if (isInMemoryPath(db_path)) return;
        self.pool.enable(io, db_path, cfg);
        // Pre-warm the initial readers so the first burst of concurrent reads does not each pay to open + `applyConfig` a connection.
        // The pool still grows past this on demand: `read_conns` is the warm floor, not the ceiling.
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
        // The statement cache outlives every caller, so it takes the connection's own allocator here rather than one from a later `query` (see `Config.allocator`).
        slot.stmt_cache.owned_allocator = cfg.allocator;
        try slot.applyConfig(cfg);
    }

    /// True for the SQLite spellings of a private, connection-local
    /// in-memory database.
    fn isInMemoryPath(db_path: []const u8) bool {
        if (std.mem.eql(u8, db_path, ":memory:")) return true;
        // `file::memory:...` is in-memory too; a `cache=shared` variant would share one database, but pooling it buys nothing, so skip it.
        if (std.mem.startsWith(u8, db_path, "file::memory:")) return true;
        return false;
    }

    /// True for SQL that inspects CONNECTION state rather than table data: `last_insert_rowid()`, `changes()` and `total_changes()` are per-connection counters, and a reader connection has never written anything, so it would answer `0` (silently wrong).
    /// The one thing pooling cannot make transparent by routing alone, so it is decided by name: a case-insensitive substring scan that only runs for a statement that is already a read.
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

    /// Elastic pool of READ-ONLY connections, owned by the primary `SqliteBackend` and shared by every thread that reads through it. `claim` hands a connection to EXACTLY ONE read at a time until `release`, after the statement is reset.
    /// Connections are individually heap-allocated (`*SqliteBackend`) rather than one contiguous slice, so growing the pool never MOVES a slot that a `Rows` is holding.
    const ReaderPool = struct {
        /// One open reader. `claimed` is the authority on who owns the connection; `idle_since_ms` is only its age stamp, and they are NOT the same fact.
        /// Conflating them was a use-after-free waiting to happen: a duplicated `idle` entry (two `release` calls for one connection) let `claim` hand the SAME connection to two reads, and the loser could have it closed and freed by `reapLocked` while its `Rows` was still stepping it.
        const Slot = struct {
            conn: *SqliteBackend,
            claimed: bool = false,
            /// Monotonic timestamp (`.awake` clock) at which this reader
            /// was returned to the idle list; null when claimed.
            idle_since_ms: ?i64 = null,
        };

        enabled: bool = false,
        io: std.Io = .failing,
        /// Owned copy of the database path: the pool opens connections lazily, long after the `db_path` argument of `initWithConfig` has gone out of scope, so a borrow would be a use-after-free waiting for the first read that needs a new reader.
        db_path: ?[:0]u8 = null,
        cfg: Config = .{},
        /// Every open reader, claimed or idle.
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        /// Indices into `slots` that are free to claim. An index is in
        /// exactly one of the two lists at any time.
        idle: std.ArrayListUnmanaged(usize) = .empty,
        /// Guards `slots` / `idle` structure only. Held briefly — never
        /// across a statement — so it is not the read hot path's limiter.
        mutex: std.Io.Mutex = .init,
        /// Bumped by `release` / `reapIdle` / `closeAll` so a read blocked on a full pool re-checks the pool as soon as a reader comes free.
        /// NOT `std.Io.Condition`: `Condition.wait` has no timeout, so a `claimOrWait` built on it would wait forever and only ever check its budget between waits. A read that must be able to give up needs the bounded wait of `futexWaitTimeout` over this word.
        readers_epoch: std.atomic.Value(u32) = .init(0),
        /// Readers handed out and not yet returned: a `Rows` owns its reader until `deinit`, so a caller that forgets it leaks a CONNECTION, which no allocator and no leak checker can see.
        /// `outstandingClaims()` returning to zero is the only thing that proves the pool gave back what it lent, and it is assertable from a test.
        outstanding: std.atomic.Value(usize) = .init(0),
        /// Monotonic time (ms) before which no reaping pass runs. `reapLocked` walks the whole idle list, so calling it from `release` on every read made every READ pay an O(idle) scan that reaps nothing.
        /// A pass therefore runs at most once per `reapIntervalMs`, pushing the actual reap time out to at most `max_idle_time_ms + reapIntervalMs`. `reapIdle`, the explicit daemon tick, is unaffected and always runs.
        next_reap_ms: i64 = 0,

        fn enable(self: *ReaderPool, io: std.Io, db_path: [:0]const u8, cfg: Config) void {
            // cfg FIRST: the path below is allocated with `self.alloc()`, and `closeAll` frees it the same way. Storing cfg after the dupeZ made the copy come from the default allocator while its free came from the configured one.
            // That allocator mismatch on a live pointer showed up as an "Invalid free" in the debug allocator (the supplied-allocator test caught it).
            self.cfg = cfg;
            self.db_path = self.alloc().dupeZ(u8, db_path) catch {
                // Without the path the pool cannot open anything, so leave it disabled: every read falls back to the primary connection, which is correct, just serialized.
                std.log.warn("sqlite: could not copy the database path; reader pool disabled", .{});
                return;
            };
            self.enabled = true;
            self.io = io;
        }

        /// The database path this pool opens readers against.
        /// An error rather than an `unreachable`: `closeAll` clears `db_path`, so a `claim` racing shutdown would otherwise turn a shutdown-ordering bug into a panic.
        fn path(self: *ReaderPool) Error![:0]const u8 {
            return self.db_path orelse Error.DatabaseNotFound;
        }

        /// The allocator this pool allocates connections and index lists from.
        /// Resolved per call rather than captured in a `const` because `Config.allocator` is set at construction, and a reader is created long afterwards.
        fn alloc(self: *const ReaderPool) std.mem.Allocator {
            return self.cfg.allocator orelse std.heap.smp_allocator;
        }

        /// Minimum gap between automatic reaping passes. 0 when `max_idle_time_ms` is 0, which means "reap on every pass" (what `sqlite_pool_test.zig` uses to test reaping without sleeping).
        /// An explicit `reap_interval_ms` wins; 0 falls back to the derived value, so a consumer that never sets it keeps the behaviour it had before this knob existed.
        fn reapIntervalMs(self: *const ReaderPool) i64 {
            if (self.cfg.max_idle_time_ms == 0) return 0;
            if (self.cfg.reap_interval_ms != 0) {
                return @intCast(self.cfg.reap_interval_ms);
            }
            return @max(@as(i64, @intCast(self.cfg.max_idle_time_ms / 4)), 1_000);
        }

        /// Run a reaping pass if one is due, and schedule the next. Caller holds `mutex`.
        /// Returns how many connections were closed, which is what `release` / `claimOrWait` use to decide whether a waiter has to be woken.
        fn reapIfDueLocked(self: *ReaderPool, now: i64) usize {
            if (now < self.next_reap_ms) return 0;
            self.next_reap_ms = now + self.reapIntervalMs();
            return self.reapLocked(now);
        }

        fn nowMs(io: std.Io) i64 {
            // `.awake` is monotonic (CLOCK_MONOTONIC on Linux), so consecutive reads never go backwards; there is no other clock in src.
            return std.Io.Timestamp.now(io, .awake).toMilliseconds();
        }

        /// Open up to `n` readers now so a burst does not each pay for a
        /// connection open + `applyConfig`.
        fn prewarm(self: *ReaderPool, io: std.Io, n: usize) !void {
            self.mutex.lock(io) catch return Error.Canceled;
            defer self.mutex.unlock(io);
            const now = nowMs(io);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (self.atCap()) break;
                const conn = self.alloc().create(SqliteBackend) catch return Error.OutOfMemory;
                conn.* = .{};
                // Same reason as `openSlot`: `applyConfig` can fail after
                // the handle is assigned, so the handle needs closing.
                const db_path = try self.path();
                openSingle(conn, io, db_path, self.cfg) catch |err| {
                    conn.deinit();
                    self.alloc().destroy(conn);
                    return err;
                };
                try self.slots.append(self.alloc(), .{ .conn = conn, .idle_since_ms = now });
                conn.pool_index = self.slots.items.len - 1;
                try self.idle.append(self.alloc(), self.slots.items.len - 1);
            }
        }

        /// Open one more reader.
        /// ONE cleanup path, deliberately: the `errdefer`s fire on EVERY error return, so pairing them with an explicit `alloc.destroy` on any one of those paths is a double free.
        fn openSlot(self: *ReaderPool, io: std.Io) !*SqliteBackend {
            const conn = self.alloc().create(SqliteBackend) catch return Error.OutOfMemory;
            // `pool = .{}` — a reader never nests a pool of its own.
            conn.* = .{};
            // `deinit`, not a bare `alloc.destroy`: `openSingle` can fail AFTER assigning `slot.db` (it is `applyConfig` that fails, and that runs last), so the sqlite handle must be closed or its fds leak for the life of the process.
            // `deinit` is safe on a half-open backend: every step null-checks first.
            errdefer self.alloc().destroy(conn);
            errdefer conn.deinit();
            openSingle(conn, io, try self.path(), self.cfg) catch |err| return err;

            try self.mutex.lock(io);
            defer self.mutex.unlock(io);
            if (self.atCap()) return error.PoolExhausted;
            try self.slots.append(self.alloc(), .{ .conn = conn, .claimed = true, .idle_since_ms = null });
            conn.pool_index = self.slots.items.len - 1;
            _ = self.outstanding.fetchAdd(1, .monotonic);
            return conn;
        }

        /// The policy ceiling, or 0 when there is none. Never below `read_conns`: the warm floor is opened eagerly at `init`, so a `max_read_conns` at or under it would make the pool refuse connections it had just opened (and `prewarm` breaks on `atCap`, so it would not even open them).
        /// Clamping here keeps a misconfigured pair degrading to "unbounded" (the pre-pooling behaviour) instead of to "no readers at all"; `sqlite_pool_test.zig` pins it.
        fn effectiveCap(self: *ReaderPool) usize {
            if (self.cfg.max_read_conns == 0) return 0;
            return @max(self.cfg.max_read_conns, self.cfg.read_conns);
        }

        /// True when the pool must not open another reader. `Config.max_read_conns` is the POLICY cap (0 = no policy cap), but a pooled reader costs `FDS_PER_READER` descriptors and the process needs those for its own sockets.
        /// How big that ceiling is: on a modern soft limit of 524288 it is 262016, a backstop against descriptor exhaustion rather than a read-concurrency limit. The honest bound on a burst is `max_idle_time_ms` reaping plus `reader_wait_ms` queueing.
        fn atCap(self: *ReaderPool) bool {
            const cap = self.effectiveCap();
            if (cap != 0 and self.slots.items.len >= cap) return true;
            return self.slots.items.len >= fdDerivedReaderCap();
        }

        /// Take an idle reader, if there is one. Caller holds `mutex`.
        /// A stale entry (out of range, or naming a slot some other path already handed out) is dropped rather than returned: handing a CLAIMED connection to a second read is the one mistake this pool cannot recover from.
        fn popIdleLocked(self: *ReaderPool) ?*SqliteBackend {
            while (self.idle.pop()) |idx| {
                if (idx >= self.slots.items.len) continue;
                if (self.slots.items[idx].claimed) continue;
                self.slots.items[idx].claimed = true;
                self.slots.items[idx].idle_since_ms = null;
                _ = self.outstanding.fetchAdd(1, .monotonic);
                return self.slots.items[idx].conn;
            }
            return null;
        }

        /// Take exclusive ownership of a reader, opening one if every existing reader is busy. Never blocks on another read.
        /// Non-waiting form, kept for callers that must not block (a `Transaction` already owns the primary mutex; a caller inside an interrupt-free section). `SqliteBackend.queryRow` / `query` use `claimOrWait` instead.
        pub fn claim(self: *ReaderPool, io: std.Io) Error!*SqliteBackend {
            try self.mutex.lock(io);
            if (self.popIdleLocked()) |conn| {
                self.mutex.unlock(io);
                return conn;
            }
            // Slow path: everything is busy. Reap first: readers that went idle long ago and were never reaped (released when the pool was already at the floor) still occupy slots.
            // Without it, a burst followed by a lull would grow the pool again before the last reap. No new idle reader can have been missed between the pop and here, since we hold the mutex.
            _ = self.reapIfDueLocked(nowMs(io));
            self.mutex.unlock(io);
            return self.openSlot(io);
        }

        /// Wake readers blocked on `claimOrWait`, so they re-check the pool. Safe with the mutex held or not; what matters is that the announced change is already visible in `slots` / `idle`.
        /// `epoch` is bumped BEFORE the futex wake, which closes the race: a waiter that sampled the old epoch either already parked (and gets woken) or has not parked (and its `futexWaitTimeout` returns immediately, because the word no longer matches).
        fn wakeReaders(self: *ReaderPool, io: std.Io) void {
            _ = self.readers_epoch.fetchAdd(1, .release);
            io.futexWake(u32, &self.readers_epoch.raw, std.math.maxInt(u32));
        }

        /// Block until a reader is released or `timeout_ms` elapses, then re-take `mutex` and return. Caller holds `mutex` on entry and again on exit.
        /// Uncancelable and bounded by the timeout rather than by a signal: the caller has to be able to give up eventually, and a cancel would leave the read with nowhere to report the error.
        fn waitForReaderLocked(self: *ReaderPool, io: std.Io, timeout_ms: i64) void {
            if (timeout_ms <= 0) return;
            // Sample BEFORE unlocking: sampling after would let a release
            // land in between and go unnoticed until the next timeout.
            const epoch = self.readers_epoch.load(.acquire);
            self.mutex.unlock(io);
            defer self.mutex.lockUncancelable(io);
            io.futexWaitTimeout(
                u32,
                &self.readers_epoch.raw,
                epoch,
                .{ .duration = .{
                    .raw = .{ .nanoseconds = @intCast(@min(timeout_ms, MAX_WAIT_SLICE_MS) * std.time.ns_per_ms) },
                    .clock = .awake,
                } },
            ) catch {};
        }

        /// `claim`, but WAIT up to `budget_ms` for a reader to be released when the pool is at its ceiling instead of failing at once. Returns `error.PoolExhausted` when the budget expires with no reader free.
        /// Queueing behind another READ costs latency; queueing behind the writer costs correctness, because a read on the write connection holds the single writer mutex for its whole duration and delays unrelated `BEGIN IMMEDIATE`s into their own `busy_timeout`.
        pub fn claimOrWait(self: *ReaderPool, io: std.Io, budget_ms: u32) Error!*SqliteBackend {
            // Fast path, no waiting at all: an idle reader, or room to grow.
            if (self.claim(io)) |conn| {
                return conn;
            } else |err| switch (err) {
                error.PoolExhausted => {},
                else => return err,
            }
            if (budget_ms == 0) return error.PoolExhausted;

            const deadline = nowMs(io) + @as(i64, budget_ms);
            var locked = true;
            try self.mutex.lock(io);
            defer if (locked) self.mutex.unlock(io);

            while (true) {
                if (self.popIdleLocked()) |conn| return conn;
                // Reap first: a reader that went idle long ago still holds
                // its slot, and `atCap` counts slots, not free readers.
                if (self.reapIfDueLocked(nowMs(io)) > 0) self.wakeReaders(io);
                if (self.popIdleLocked()) |conn| return conn;
                if (!self.atCap()) {
                    // Room to grow — but `openSlot` locks the mutex itself.
                    locked = false;
                    self.mutex.unlock(io);
                    return self.openSlot(io);
                }
                const remaining = deadline - nowMs(io);
                if (remaining <= 0) return error.PoolExhausted;
                self.waitForReaderLocked(io, remaining);
            }
        }

        /// Hand a reader back. Call ONLY once its statement has been reset
        /// or finalized, so the next read starts a fresh snapshot.
        pub fn release(self: *ReaderPool, io: std.Io, slot: *SqliteBackend) void {
            // `slots.items` and `slot.pool_index` are both pool-owned, so the lookup MUST happen under the mutex.
            // A concurrent `claim` -> `openSlot` can reallocate that slice, and the reaper renumbers indices when it closes a gap.
            self.mutex.lock(io) catch return;
            const handed_back = blk: {
                defer self.mutex.unlock(io);
                // O(1): the connection carries its own index. The bounds and identity checks cover the only way it can be stale (the reaper closed a gap and renumbered).
                // On a mismatch, fall back to a scan: slow, but it cannot hand out the wrong connection.
                var idx = slot.pool_index orelse (self.indexOf(slot) orelse break :blk false);
                if (idx >= self.slots.items.len or self.slots.items[idx].conn != slot) {
                    idx = self.indexOf(slot) orelse break :blk false;
                }
                break :blk self.releaseAtLocked(io, idx);
            };
            // Announced after the entry is visible in `idle`: a woken waiter whose first act is to re-acquire the mutex has to find something to take, or it sleeps again having lost nothing.
            if (handed_back) self.wakeReaders(io);
        }

        /// The hand-back itself, with `mutex` held. Returns whether a reader was actually returned, which is also what the outstanding counter keys off: every early return leaves the connection claimed.
        fn releaseAtLocked(self: *ReaderPool, io: std.Io, idx: usize) bool {
            if (!self.slots.items[idx].claimed) {
                // Already idle. A second `release` for the same connection would put its index in `idle` a second time, and the next `claim` would hand one connection to two reads.
                return false;
            }
            const stamp = nowMs(io);
            self.slots.items[idx].claimed = false;
            self.slots.items[idx].idle_since_ms = stamp;
            self.idle.append(self.alloc(), idx) catch {
                // Out of memory for the idle index. Deliberately do NOT `swapRemove` the slot out of `slots`: that would renumber every later index and silently hand the same connection to two readers.
                // Keeping it claimed leaks one connection, which is the safe direction to fail.
                self.slots.items[idx].claimed = true;
                self.slots.items[idx].idle_since_ms = null;
                std.log.err("sqlite: reader pool lost an idle slot to OOM; leaking one connection", .{});
                return false;
            };
            _ = self.reapIfDueLocked(stamp);
            _ = self.outstanding.fetchSub(1, .monotonic);
            return true;
        }

        /// Close idle readers older than `max_idle_time_ms`, never dropping below the `read_conns` warm floor and never touching a claimed reader. Public so an optional daemon tick can call it; `release` and the `claim` slow path already call it inline.
        /// ALWAYS RUNS, which is a contract a test depends on: reaping twice in a row to prove the floor holds must not silently no-op the second time. A caller that wants the pass rate-limited should use `reapIdleThrottled`.
        pub fn reapIdle(self: *ReaderPool, io: std.Io) void {
            self.mutex.lock(io) catch return;
            const now = nowMs(io);
            const reaped = self.reapLocked(now);
            self.next_reap_ms = now + self.reapIntervalMs();
            self.mutex.unlock(io);
            // Freeing slots is exactly what a read parked on `claimOrWait` is waiting for: without this it would sit out its whole budget and then fall back, while the pool had room.
            if (reaped > 0) self.wakeReaders(io);
        }

        /// `reapIdle`, but skipped when a pass ran inside `reap_interval_ms`. This is the tick a long-lived server should call: it can fire on any cadence and the pool decides whether the work is due.
        /// The inline passes are traffic-driven (`release`, the `claim` slow path), so a consumer that goes quiet never triggers one and its pool stays fat. `reapIdle` stays always-runs so a test keeps deterministic shrinking.
        pub fn reapIdleThrottled(self: *ReaderPool, io: std.Io) void {
            self.mutex.lock(io) catch return;
            const now = nowMs(io);
            if (now < self.next_reap_ms) {
                self.mutex.unlock(io);
                return;
            }
            const reaped = self.reapLocked(now);
            self.next_reap_ms = now + self.reapIntervalMs();
            self.mutex.unlock(io);
            if (reaped > 0) self.wakeReaders(io);
        }

        /// Caller must hold `mutex`. `now` is a parameter (not read inside) so `release` can pass the timestamp it just stamped without a second clock read.
        /// Returns how many connections were closed, so the caller can decide whether a waiter needs waking.
        fn reapLocked(self: *ReaderPool, now: i64) usize {
            const floor = self.cfg.read_conns;
            var reaped: usize = 0;
            var i: usize = 0;
            while (i < self.idle.items.len) {
                if (self.slots.items.len <= floor) break;
                const idx = self.idle.items[i];
                if (idx >= self.slots.items.len) {
                    // Unreachable: every mutation of `slots` fixes up `idle`. Nothing is orphaned by dropping this entry, since the slot it named is already gone.
                    _ = self.idle.swapRemove(i);
                    continue;
                }
                if (self.slots.items[idx].claimed) {
                    // In use. SKIP, never drop: an entry removed here leaves the slot in NEITHER list, so no claim can ever reach it and no reaper will ever close it, a permanently leaked connection that also counts against the cap.
                    // Try again next pass.
                    i += 1;
                    continue;
                }
                const since = self.slots.items[idx].idle_since_ms orelse {
                    // No age stamp, so its age is unknown; reaping it blind could close a connection someone is stepping. Skip for the same reason as above.
                    i += 1;
                    continue;
                };
                // A clock that went backwards makes the entry look fresh; treat it as fresh rather than reaping a just-released reader.
                if (now < since) {
                    i += 1;
                    continue;
                }
                const age = @as(u64, @intCast(now - since));
                if (age < self.cfg.max_idle_time_ms) {
                    i += 1;
                    continue;
                }
                // Reap it: remove its idle entry, close the connection, then close the gap in `slots`. `slots[idx]` is NOT the last element in general.
                // Move the last slot into the gap and rewrite any idle entry that pointed at the last index, or the next claim hands out the wrong connection (or two readers share one).
                _ = self.idle.swapRemove(i);
                const victim = self.slots.items[idx].conn;
                victim.pool_index = null;
                victim.deinit();
                self.alloc().destroy(victim);
                const last = self.slots.items.len - 1;
                if (idx != last) {
                    self.slots.items[idx] = self.slots.items[last];
                    // The moved connection's cached index must move with it, or its next `release` would name the wrong slot; this is the only place a slot changes index.
                    self.slots.items[idx].conn.pool_index = idx;
                    for (self.idle.items) |*entry| {
                        if (entry.* == last) entry.* = idx;
                    }
                }
                self.slots.items.len -= 1;
                reaped += 1;
                // Do not advance `i`: `swapRemove` moved a new entry here.
            }
            return reaped;
        }

        fn indexOf(self: *ReaderPool, slot: *SqliteBackend) ?usize {
            for (self.slots.items, 0..) |s, i| {
                if (s.conn == slot) return i;
            }
            return null;
        }

        fn closeAll(self: *ReaderPool, io: std.Io) void {
            self.mutex.lock(io) catch {};
            defer self.mutex.unlock(io);
            for (self.slots.items) |slot| {
                slot.conn.deinit();
                self.alloc().destroy(slot.conn);
            }
            self.slots.deinit(self.alloc());
            self.idle.deinit(self.alloc());
            self.slots = .empty;
            self.idle = .empty;
            if (self.db_path) |owned_path| self.alloc().free(owned_path);
            self.db_path = null;
            self.enabled = false;
            // Wake every waiter: a read blocked in `claimOrWait` must not sit out its whole budget against a pool that no longer exists. `popIdleLocked` finds nothing and `openSlot` reports `DatabaseNotFound`, which the caller turns into a fallback.
            self.wakeReaders(io);
        }

        pub fn count(self: *ReaderPool) usize {
            return self.slots.items.len;
        }

        /// Readers handed out and not yet returned. Zero means every claim has been released; anything else is a caller that drained a `Rows` and never `deinit`ed it.
        pub fn outstandingClaims(self: *ReaderPool) usize {
            return self.outstanding.load(.monotonic);
        }

        /// How many readers are sitting in the idle list right now.
        /// Exposed because "the pool is at its ceiling" and "every reader is busy" are different facts, and only the second one is backpressure: a test that cannot see the difference cannot tell a queued read from a hijacked writer.
        pub fn idleCount(self: *ReaderPool) usize {
            self.mutex.lock(self.io) catch return 0;
            defer self.mutex.unlock(self.io);
            return self.idle.items.len;
        }
    };

    /// True when reads can be served by a pooled reader.
    fn poolReady(self: *SqliteBackend) bool {
        return self.pool.enabled;
    }

    /// Take a reader for one read, or fall back to `self`. NEVER returns an error: a read served on the write connection is merely slower, a refused one is a 500 the caller sees.
    /// The pool runs out of capacity (most often descriptors) for reasons unrelated to whether this read can be answered. It WAITS first (`Config.reader_wait_ms`), then falls back and logs at most once per `FALLBACK_LOG_INTERVAL_MS`: a fallback is a symptom of saturation, not one event per read.
    fn claimReader(self: *SqliteBackend) *SqliteBackend {
        const budget = self.pool.cfg.reader_wait_ms;
        return self.pool.claimOrWait(self.io, budget) catch |err| blk: {
            self.fallbacks.store(self.fallbacks.load(.monotonic) + 1, .monotonic);
            self.logFallbackOnce(err);
            break :blk self;
        };
    }

    /// Emit the write-connection fallback at most once per interval.
    fn logFallbackOnce(self: *SqliteBackend, err: Error) void {
        const now = ReaderPool.nowMs(self.io);
        const last = self.fallback_logged_ms.load(.monotonic);
        if (last != 0 and now >= last and now - last < FALLBACK_LOG_INTERVAL_MS) return;
        self.fallback_logged_ms.store(now, .monotonic);
        std.log.warn(
            "sqlite: reader pool unavailable after waiting {d}ms ({s}); serving this read on the write connection",
            .{ self.pool.cfg.reader_wait_ms, @errorName(err) },
        );
    }

    /// How many reads have been served on the write connection because the
    /// pool could not give them a reader. Zero is the only healthy value.
    pub fn readFallbackCount(self: *const SqliteBackend) u64 {
        return self.fallbacks.load(.monotonic);
    }

    /// Pooled readers handed out and not yet returned. Zero when the pool holds nothing. THE leak canary.
    /// A `Rows` owns its reader until `deinit`, so forgetting it leaks a CONNECTION, invisible to `testing.allocator` because the row bytes belong to the caller. Assert this is zero after a call that does database work.
    pub fn outstandingClaims(self: *SqliteBackend) usize {
        return self.pool.outstandingClaims();
    }

    /// Re-apply `cfg` to an already-open connection. Needs no allocator: the PRAGMA statements are formatted into stack buffers.
    /// Every statement is a PRAGMA with no bind parameters, so routing it through the statement path is safe; the "empty slice binds as SQL NULL" quirk only bites when a `?` is present.
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

        // Sizing knobs. Both default ON (8 MiB cache, 256 MiB mmap window); set either to 0 to hand the decision back to SQLite.
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

    /// `exec` with no allocator: `executeStatement` never touches it (the parameter is `_ = allocator` in the body, existing only for signature symmetry with `exec`).
    /// So the PRAGMA path can pass `undefined` instead of making every caller thread an allocator through just to set a timeout.
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

    /// Prepare `sql` for a statement that runs to completion INSIDE the caller's lock (`exec` / `queryRow` / the `Transaction` variants), using the cache except when a `Rows` iterator is currently stepping this connection's cached statement.
    /// `acquire` would `sqlite3_reset` + `sqlite3_clear_bindings` it and rebind it to this caller's arguments, destroying the live iterator's remaining rows from another thread. `SqliteBackend.iterating` marks that case; the load is safe because the caller holds `self.mutex`.
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

    /// Inner implementation: prepare + bind + step a single SQL statement. Caller MUST hold the backend mutex (also used by `Transaction.exec`, which already holds it).
    fn executeStatement(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!void {
        _ = allocator;
        const db = self.db orelse return Error.DatabaseNotFound;

        // Empty SQL is a successful no-op: `sqlite3_prepare_v2` on a zero-length input returns OK with stmt=NULL, and step() on a NULL stmt is documented as harmless.
        // Short-circuit so callers do not have to special-case "" themselves.
        if (sql.len == 0) return;

        const prepared = self.prepareForImmediateUse(sql) catch |err| {
            std.log.info("sqlite3 prepare failed: {s} (sql: {s})", .{ c.sqlite3_errmsg(db), sql });
            return err;
        };
        const stmt = prepared.stmt;
        const cached = prepared.cached;
        // ALWAYS close the statement before returning. A statement left at SQLITE_ROW keeps an implicit READ TRANSACTION open, and that makes a following `BEGIN IMMEDIATE` fail with SQLITE_BUSY *without* consulting busy_timeout (it cannot upgrade the snapshot).
        // `reset` ends it and hands a cached statement back ready for the next bind.
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

    /// Read the current row of `stmt` into an allocator-owned `Row` in TWO allocations: the `values` slice, plus one buffer holding every column's bytes back to back. A 3-column row costs two allocator calls instead of four, on a path that runs per request and, for a list endpoint, per ROW.
    /// Callers see the same `Row.values` shape and the same `Row.deinit` contract. SQL NULL still maps to an empty slice.
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

    /// Inner implementation: prepare + bind + step ONCE for a single-row SELECT. Caller MUST hold the backend mutex (also used by `Transaction.queryRow`, which already holds it).
    fn executeQueryRow(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Row {
        // `prepareForImmediateUse` re-checks `self.db`, but do it here too: `queryRow` before `init` must answer `DatabaseNotFound`, not whatever prepare would report on a null handle.
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
        // A `queryRow` completes inside the lock, so it can borrow a pooled reader for the duration of the call and hand it straight back: no `Rows` outlives it, so no snapshot outlives it either.
        // `needsWriteConnection` SQL and an unavailable pool both fall back to the primary, which is where a `Transaction` reads anyway (via `tx.queryRow`), so it sees its own uncommitted writes.
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
        /// Non-owning reference to the db, captured at query time, so that `next()` can call `sqlite3_errmsg(db)` on an error: the stmt pointer alone does not give access to the db handle. See `captureError`.
        db: ?*c.sqlite3,
        /// Owner of the cached statement, when this iterator came from `query` (see `SqliteBackend.iterating`), OR the pooled reader this iterator holds exclusively.
        slot: ?*SqliteBackend = null,
        /// The pool `slot` must be returned to, when this iterator holds a pooled reader. null on the primary path (nothing to give back).
        /// The release happens in `deinit`, AFTER the statement is reset; that ordering is what guarantees the next reader of this connection starts a fresh read instead of inheriting the snapshot this iterator opened.
        pool: ?*ReaderPool = null,
        /// True when `stmt` belongs to the statement cache: `deinit` resets
        /// it for reuse instead of finalizing it.
        cached: bool = false,
        /// Tracks whether the iterator has reached SQLITE_DONE, so later `next()` calls short-circuit to null without re-invoking `sqlite3_step()`; see `next` for the rationale.
        done: bool = false,
        /// Most recent SQLite error message, captured by `next()` when `sqlite3_step()` returns a non-ROW rc. Owned by Rows, freed in `deinit`, readable via `getLastErrorMessage()`.
        /// Without it the only signal was the `Error.QueryFailed` enum name and the raw SQLite message was lost (logged but not returned).
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
            // Give the reader back only now that its statement is closed; otherwise the next read on this connection would be served from the snapshot this iterator just finished reading.
            if (self.pool) |pool| {
                if (self.slot) |slot| pool.release(slot.io, slot);
            }
            self.pool = null;
            self.slot = null;
        }

        /// Capture `sqlite3_errmsg(db)` into `last_error_msg` so callers can surface it. Best-effort: silently no-ops when `db` is null (backend closed) or when allocation fails.
        /// The caller still gets the Error enum either way; this just enriches it.
        fn captureError(self: *Rows) void {
            if (self.db) |d| {
                const err_msg_c = c.sqlite3_errmsg(d);
                const span = std.mem.span(err_msg_c);
                if (self.last_error_msg) |old| self.allocator.free(old);
                self.last_error_msg = self.allocator.dupe(u8, span) catch null;
            }
        }

        /// Returns the most recent SQLite error message, or null if no error has been captured yet. Owned by Rows; valid until `deinit()`.
        pub fn getLastErrorMessage(self: *Rows) ?[]const u8 {
            return self.last_error_msg;
        }

        pub fn next(self: *Rows) Error!?Row {
            // Defensive: once null (DONE) has been returned for a query, keep returning null without re-invoking `sqlite3_step`. Step after DONE on a SELECT can return ROW again on some SQLite versions, which would surface as a duplicated final row in the caller loop.
            // Track the done state explicitly rather than depending on the SQLite rc-after-DONE behaviour.
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
        /// Backing buffer for the column bytes when the row was read with the packed reader: every `values[i]` is a slice of THIS one allocation, so `deinit` frees it once instead of walking the columns.
        /// null means the columns own separate allocations. Two allocations is the floor without hand-rolling alignment.
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

    /// A database transaction: acquire one via `SqliteBackend.begin()` (top-level) or `savepoint()` (nested), run statements with the tx methods, then `commit()` or `rollback()`. `SqliteBackend.mutex` is held for the whole tx and is NOT reentrant, so use `tx.*`: a `db.exec()` / `db.query()` from the same thread deadlocks.
    /// Single-use: every method after a completed `commit()` / `rollback()` returns `Error.TransactionClosed`, and calling anyway would run SQL WITHOUT the mutex. Idiom: `defer tx.commitOrRollback() catch {};` with `errdefer tx.rollback() catch {};`. Slices from `tx.queryRow()` / `tx.query()` are caller-allocated: free them with `Row.deinit(allocator)`.
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

        /// Internal helper: run COMMIT (or RELEASE sp_<n> for a nested tx), decrement depth, release the mutex on the outermost commit, and flip `completed`.
        /// MUST NOT be called directly: `commit` and `commitOrRollback` both gate on `self.completed` BEFORE calling it, and without that gate it would skip the re-finalization check and could release the mutex twice (UB).
        fn _doFinalizeCommit(self: *Transaction) Error!void {
            const db = self.backend.db orelse {
                self.completed = true;
                // On backend-closed: depth is a property of the backend (not the connection), so decrement it for consistency.
                // Only release the mutex on the outermost commit/rollback; inner savepoints hold the mutex on behalf of the outer tx.
                self.backend.transaction_depth -= 1;
                if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);
                return Error.DatabaseNotFound;
            };

            // SQL depends on depth: depth == 1 -> top-level COMMIT; depth >= 2 -> RELEASE for the matching SAVEPOINT.
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
            // Only the OUTERMOST commit releases the mutex. An inner savepoint commit (depth >= 2) leaves it held so the surrounding outer transaction can keep using it.
            if (self.depth == 1) self.backend.mutex.unlock(self.backend.io);

            if (rc != c.SQLITE_OK) {
                return Error.ExecuteFailed;
            }
        }

        pub fn commit(self: *Transaction) Error!void {
            if (self.completed) return Error.TransactionClosed;
            return self._doFinalizeCommit();
        }

        /// Commit the transaction if it has not yet been finalized; a no-op returning success if it already was (NOT `Error.TransactionClosed`, which would defeat the point of the defer-idiom).
        /// Canonical: `defer tx.commitOrRollback() catch {}` plus `errdefer tx.rollback() catch {}`. Defers run LIFO, so on error `rollback()` fires first and the deferred commit becomes a no-op instead of persisting a partial prefix. Never issue raw `BEGIN` / `COMMIT` / `ROLLBACK` via `db.exec()`: that bypasses the mutex + depth tracking.
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

    /// Inner implementation: prepare + bind a SELECT statement, returning a `Rows` iterator. Caller MUST hold the backend mutex (also used by `Transaction.query`, which already holds it).
    fn executeQuery(
        self: *SqliteBackend,
        allocator: std.mem.Allocator,
        sql: []const u8,
        argv: []const []const u8,
    ) Error!Rows {
        const db = self.db orelse return Error.DatabaseNotFound;

        // NOT served from `stmt_cache`. A `Rows` keeps using its statement after this function unlocks, so a cached statement could be reset by a second `query` on the same connection while the first iterator is still mid-result.
        // `exec` / `queryRow` finish inside the lock and are safe to cache; an iterator is not, so it keeps its own statement.
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

    /// `query` body for a connection that may hand out its CACHED statement.
    /// Falls back to a one-shot statement when the cache must not be touched: a non-DML/SELECT text, or another iterator already using this connection's cached statement. Caller holds the lock.
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
        // The lock is released here, not in `Rows.deinit`. Holding it for the whole iteration would be faster (no two threads stepping one sqlite3 handle), but it would turn a caller that forgets `deinit` into a permanently stalled connection, and "you only leak a statement" is the contract existing callers were written against.
        // That is also why the pooled path hands the reader to the `Rows` INSTEAD of returning it to the idle list: the read transaction stays open while the caller steps, and handing it to anybody else would serve them that same pinned snapshot. `Rows` returns it in `deinit`, after `sqlite3_reset` has ended the transaction.
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
        // One-shot statement, NOT the statement cache. The slot IS exclusively ours for the life of the `Rows`, so there is no collision to avoid, but the cached path pins a prepared statement (plus its bound parameters and a `sqlite3_reset`) to one connection for as long as that connection lives.
        // With `read_conns` as a warm FLOOR and an elastic ceiling, a burst that spreads reads over 50+ readers prepares the same SQL 50 times instead of once, while a one-shot statement is thrown away immediately: `sqlite3_prepare_v2` on a small SELECT is cheaper than a hash lookup plus a reset on a statement this connection may never see again.
        var rows = try executeQuery(slot, allocator, sql, argv);
        rows.pool = &self.pool;
        rows.slot = slot;
        rows.cached = false;
        return rows;
    }

    // ─── Prepared-statement cache ───────────────────────────────────────

    // `exec` and `queryRow` go through `stmt_cache`, keyed by SQL text, so a server that runs the same handful of statements per request does not pay parse + bytecode generation + teardown on every call. Both keep their exact signatures, semantics and ownership rules.
    // `query` deliberately does NOT use the cache: a `Rows` iterator keeps stepping its statement AFTER `query` releases the mutex, so two live iterators on one connection would fight over a single cached statement. `exec` / `queryRow` complete inside the lock, which is what makes them safe to share.

    /// Statements the cache is allowed to hold: a SELECT or a DML statement (INSERT / UPDATE / DELETE / REPLACE).
    /// DDL and PRAGMA are deliberately excluded: re-running DDL is an ERROR case (`CREATE TABLE` twice) and caching would move the failure from prepare time to step time, silently changing `Error.PrepareFailed` into `Error.ExecuteFailed`; a PRAGMA's result depends on connection state. Leading `WITH` is not recognised and runs uncached.
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

    /// Bind `argv` for a WRITE: an empty slice binds SQL NULL. This is the documented convention for `exec` (an INSERT of "" stores NULL, and a NOT NULL column rejects it) and it is unchanged.
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

    /// Bind `argv` for a READ: every argument is bound as TEXT, so an empty slice is an empty STRING, not NULL.
    /// The asymmetry with `bindArgsExec` is deliberate and load-bearing: `query` / `queryRow` callers rely on it for the optional-filter idiom `WHERE (? = '' OR id = ?)` with the unused filter passed as the empty string. Bound as NULL instead, the WHERE clause evaluates to NULL and the query silently returns NO ROWS.
    fn bindArgsText(stmt: *c.sqlite3_stmt, argv: []const []const u8) Error!void {
        for (argv, 0..) |arg, i| {
            const rc = sqlite3_bind_text_isize(@ptrCast(stmt), @intCast(i + 1), arg.ptr, @intCast(arg.len), SQLITE_DESTRUCTOR_TRANSIENT);
            if (rc != c.SQLITE_OK) return Error.BindFailed;
        }
    }

    /// Per-connection cache of prepared statements, keyed by SQL text. Entries live until `SqliteBackend.deinit`.
    /// A cached statement is handed to exactly one caller at a time (the backend mutex is what guarantees that) and `acquire` resets it before returning. The SQL text is duplicated as the map key, so callers may pass a temporary, stack or per-request-arena slice.
    const StmtCache = struct {
        map: std.StringHashMapUnmanaged(*c.sqlite3_stmt) = .empty,
        /// Taken from `Config.allocator` at open; null falls back to
        /// `smp_allocator` (see `allocator`).
        owned_allocator: ?std.mem.Allocator = null,

        /// Same allocator as the reader pool (`Config.allocator`), and for the same reason: entries live until `SqliteBackend.deinit`, which is far past any per-request arena a caller would hand to `query`.
        fn allocator(self: *const StmtCache) std.mem.Allocator {
            return self.owned_allocator orelse std.heap.smp_allocator;
        }

        /// Finalize every cached statement. Called by `deinit`.
        pub fn deinit(self: *StmtCache) void {
            var it = self.map.iterator();
            while (it.next()) |entry| {
                _ = c.sqlite3_finalize(entry.value_ptr.*);
                self.allocator().free(entry.key_ptr.*);
            }
            self.map.deinit(self.allocator());
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
            // SQLITE_PREPARE_PERSISTENT tells the planner this text will be reused; without it SQLite avoids caching lookaside buffers, assuming the statement is short-lived.
            const rc = c.sqlite3_prepare_v3(
                db,
                sql.ptr,
                @intCast(sql.len),
                c.SQLITE_PREPARE_PERSISTENT,
                &stmt,
                null,
            );
            if (rc != c.SQLITE_OK) return Error.PrepareFailed;
            const key = self.allocator().dupe(u8, sql) catch {
                _ = c.sqlite3_finalize(stmt);
                return Error.OutOfMemory;
            };
            self.map.put(self.allocator(), key, stmt.?) catch {
                self.allocator().free(key);
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
        // CRITICAL: null out `db` after closing so the `self.backend.db == null` use-after-free guard in the Transaction code actually fires.
        // Without this, the pointer dangles and any subsequent operation would dereference freed memory.
        self.db = null;
    }

    /// Begin a new top-level transaction on this backend; its `exec` / `query` methods operate inside it until `commit()` or `rollback()` is called.
    /// The backend mutex is acquired and held for the entire transaction lifetime, so concurrent `exec` / `query` calls from other threads block until it ends. `Error.DatabaseNotFound` when not initialized, `Error.ExecuteFailed` if the `BEGIN` SQL fails; cancel-safe (a cancel inside `lock()` returns `error.Canceled` without acquiring the lock or starting a tx).
    pub fn begin(self: *SqliteBackend) Error!Transaction {
        if (self.db == null) return Error.DatabaseNotFound;

        // Acquire the mutex BEFORE issuing BEGIN. This is the critical correctness invariant: while the tx is alive, no other `backend.exec` / `backend.query` call can interleave.
        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);

        // BEGIN IMMEDIATE, not plain BEGIN. This is not a style preference: a DEFERRED transaction takes its read snapshot on the first SELECT and asks for the write lock only on the first WRITE, and if any other connection committed in between, SQLite cannot replay the reads and returns SQLITE_BUSY_SNAPSHOT ("database is locked", immediately, with the busy handler deliberately NOT consulted).
        // BEGIN IMMEDIATE takes the write lock up front, where `busy_timeout` DOES apply and the wait is honoured. A read-only transaction now also holds the write slot for its lifetime, so call `beginDeferred()` if you genuinely need the old semantics. On any failure the errdefer releases the mutex.
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

    /// Begin a DEFERRED transaction: plain `BEGIN`, taking the write lock lazily at the first write.
    /// ⚠️ This is the pre-`BEGIN IMMEDIATE` behaviour and it is a trap: a transaction that reads, has another connection commit, then writes fails IMMEDIATELY with `ExecuteFailed` ("database is locked") and ignores `busy_timeout` entirely (SQLITE_BUSY_SNAPSHOT, the reads cannot be replayed). Only use it when the transaction provably never writes; anything that writes should use `begin()`.
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

    /// Open a nested savepoint within the current transaction; the returned Transaction has `depth >= 2` and its savepoint is named `sp_<depth>`. Savepoints roll back PART of a transaction without discarding the whole thing ("try this batch, discard if it fails, keep going").
    /// **Caller must hold an active transaction**: with `transaction_depth == 0` this returns `Error.ExecuteFailed` (SQLite rejects SAVEPOINT outside an outer tx). The mutex is already held by the outer tx, so it is not re-locked.
    pub fn savepoint(self: *SqliteBackend) Error!Transaction {
        if (self.db == null) return Error.DatabaseNotFound;
        if (self.transaction_depth == 0) return Error.ExecuteFailed;

        // Mutex is already held by the outer tx — do NOT re-lock.

        self.transaction_depth += 1;
        const new_depth = self.transaction_depth;

        // Build a NUL-terminated SAVEPOINT name: `sqlite3_exec` takes a C string.
        // `sql_buf[0..31]` is `[]u8` (what bufPrint expects), and the 32nd byte holds the NUL sentinel set after formatting.
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

    /// Number of rows changed by the most recent INSERT/UPDATE/DELETE, for callers that need to know whether their `db.exec` matched any rows (the API returns no change count).
    /// Per-connection state in SQLite, not per-statement: the caller must be on the thread that wrote, or hold the mutex.
    pub fn changes(self: *SqliteBackend) i64 {
        const db = self.db orelse return 0;
        return c.sqlite3_changes(db);
    }
};
