//! Deterministic benchmark harness for the sqlite backend.
//!
//! Measures the four hot paths a server actually exercises:
//!
//!   insert      — `exec` on a cached prepared INSERT
//!   point_read  — `queryRow` on a cached prepared SELECT by primary key
//!   range_read  — `query` + `Rows.next` over a LIMITed result set
//!   tx_write    — `begin` → 3 writes → `commit` (BEGIN IMMEDIATE)
//!
//! Determinism: the workload is generated from a fixed-seed xorshift PRNG,
//! so every run inserts the same rows in the same order and reads the same
//! keys. Nothing in the measured loop reads a wall clock except the timer
//! itself, and each phase is repeated `REPS` times with the median reported.
//! Every phase also accumulates a checksum over the values it read back, so
//! a run that silently returns different data cannot look like a fast run.
//!
//! Output is a single JSON object on stdout so a container run can be
//! diffed against another.

const std = @import("std");

const sqlite_mod = @import("sqlite").sqlite;
const SqliteBackend = sqlite_mod.SqliteBackend;

const SEED: u64 = 0x5eed_1234_dead_beef;
const ROWS: usize = 5_000;
const REPS: usize = 5;

/// Fixed-seed xorshift64*. Deterministic across platforms and Zig
/// versions, unlike `std.Random.DefaultPrng` whose algorithm is not
/// guaranteed stable.
const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    fn next(self: *Rng) u64 {
        var x = self.state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.state = x;
        return x *% 0x2545_F491_4F6C_DD1D;
    }

    fn int(self: *Rng, comptime T: type) T {
        return @intCast(self.next() % std.math.maxInt(T));
    }
};

/// Monotonic stopwatch over `Io.Clock.awake`. `std.time.Timer` no longer
/// exists in Zig 0.16, and the Io clock is what the backend itself uses,
/// so the two cannot drift apart.
const Timer = struct {
    start: std.Io.Timestamp,

    fn startT(io: std.Io) Timer {
        return .{ .start = std.Io.Timestamp.now(io, .awake) };
    }

    fn readNs(self: Timer, io: std.Io) u64 {
        const now = std.Io.Timestamp.now(io, .awake);
        const d = self.start.durationTo(now);
        return @intCast(@max(0, d.toNanoseconds()));
    }
};

const PhaseResult = struct {
    name: []const u8,
    ops: u64,
    ns_per_op: f64,
    ops_per_sec: f64,
    checksum: u64,
};

const Bench = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    db: SqliteBackend,

    fn open(alloc: std.mem.Allocator, io: std.Io, db_path: [:0]const u8) !Bench {
        var db: SqliteBackend = .{};
        try db.initWithConfig(io, db_path, .{ .allocator = alloc });
        return .{ .alloc = alloc, .io = io, .db = db };
    }

    fn close(self: *Bench) void {
        self.db.deinit();
    }

    fn schema(self: *Bench) !void {
        try self.db.exec(self.alloc,
            \\CREATE TABLE IF NOT EXISTS bench_rows (
            \\  id INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL,
            \\  payload TEXT NOT NULL,
            \\  score INTEGER NOT NULL
            \\)
        , &.{});
        try self.db.exec(self.alloc,
            \\CREATE INDEX IF NOT EXISTS bench_rows_score ON bench_rows(score)
        , &.{});
    }

    /// Fill the table with `ROWS` deterministic rows. Not measured.
    ///
    /// Every bind argument is formatted into a stack buffer, so seeding
    /// allocates nothing and cannot pollute the leak report.
    fn seed(self: *Bench) !void {
        var rng = Rng.init(SEED);
        var tx = try self.db.begin();
        errdefer tx.rollback() catch {};
        var i: usize = 0;
        while (i < ROWS) : (i += 1) {
            var id_buf: [24]u8 = undefined;
            var name_buf: [48]u8 = undefined;
            var payload_buf: [96]u8 = undefined;
            var score_buf: [24]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buf, "{d}", .{i});
            const name = try std.fmt.bufPrint(&name_buf, "row-{d}-{d}", .{ i, rng.int(u16) });
            const payload = try std.fmt.bufPrint(&payload_buf, "payload-{d}-{s}", .{ rng.int(u32), name });
            const score = try std.fmt.bufPrint(&score_buf, "{d}", .{rng.int(u32)});
            try tx.exec(self.alloc,
                \\INSERT INTO bench_rows (id, name, payload, score) VALUES (?, ?, ?, ?)
            , &.{ id, name, payload, score });
        }
        try tx.commit();
    }

    fn phaseInsert(self: *Bench, ops: u64) !PhaseResult {
        var checksum: u64 = 0;
        var per_rep = try self.alloc.alloc(u64, REPS);
        defer self.alloc.free(per_rep);

        var rep: usize = 0;
        while (rep < REPS) : (rep += 1) {
            var timer = Timer.startT(self.io);
            var i: u64 = 0;
            while (i < ops) : (i += 1) {
                const id = ROWS + rep * ops + i;
                var id_buf: [24]u8 = undefined;
                const id_s = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
                try self.db.exec(self.alloc,
                    \\INSERT INTO bench_rows (id, name, payload, score) VALUES (?, ?, ?, ?)
                , &.{ id_s, "bench-name", "bench-payload-value", "42" });
                checksum +%= id;
            }
            per_rep[rep] = timer.readNs(self.io);
        }

        return self.finish("insert", ops, per_rep, checksum);
    }

    fn phasePointRead(self: *Bench, ops: u64) !PhaseResult {
        var checksum: u64 = 0;
        var per_rep = try self.alloc.alloc(u64, REPS);
        defer self.alloc.free(per_rep);

        var rep: usize = 0;
        while (rep < REPS) : (rep += 1) {
            var timer = Timer.startT(self.io);
            var i: u64 = 0;
            while (i < ops) : (i += 1) {
                // Deterministic key spread across the seeded range.
                const key = (i *% 7919) % ROWS;
                var key_buf: [24]u8 = undefined;
                const key_s = try std.fmt.bufPrint(&key_buf, "{d}", .{key});
                var row = try self.db.queryRow(self.alloc,
                    \\SELECT id, name, payload, score FROM bench_rows WHERE id = ?
                , &.{key_s});
                defer row.deinit(self.alloc);
                if (row.values.len != 4) return error.BadRow;
                checksum +%= std.fmt.parseInt(u64, row.values[0], 10) catch 0;
            }
            per_rep[rep] = timer.readNs(self.io);
        }

        return self.finish("point_read", ops, per_rep, checksum);
    }

    fn phaseRangeRead(self: *Bench, ops: u64) !PhaseResult {
        var checksum: u64 = 0;
        var per_rep = try self.alloc.alloc(u64, REPS);
        defer self.alloc.free(per_rep);

        var rep: usize = 0;
        while (rep < REPS) : (rep += 1) {
            var timer = Timer.startT(self.io);
            var i: u64 = 0;
            while (i < ops) : (i += 1) {
                const floor = (i *% 101) % (ROWS - 20);
                var floor_buf: [24]u8 = undefined;
                const floor_s = try std.fmt.bufPrint(&floor_buf, "{d}", .{floor});
                var rows = try self.db.query(self.alloc,
                    \\SELECT id, name, payload, score FROM bench_rows WHERE id >= ? ORDER BY id LIMIT 20
                , &.{floor_s});
                defer rows.deinit();
                var n: u64 = 0;
                while (try rows.next()) |row| {
                    defer row.deinit(self.alloc);
                    if (row.values.len != 4) return error.BadRow;
                    checksum +%= std.fmt.parseInt(u64, row.values[0], 10) catch 0;
                    n += 1;
                }
                if (n != 20) return error.BadRowCount;
            }
            per_rep[rep] = timer.readNs(self.io);
        }

        return self.finish("range_read", ops, per_rep, checksum);
    }

    fn phaseTxWrite(self: *Bench, ops: u64) !PhaseResult {
        var checksum: u64 = 0;
        var per_rep = try self.alloc.alloc(u64, REPS);
        defer self.alloc.free(per_rep);

        var rep: usize = 0;
        while (rep < REPS) : (rep += 1) {
            var timer = Timer.startT(self.io);
            var i: u64 = 0;
            while (i < ops) : (i += 1) {
                const id = 10_000_000 + rep * ops + i;
                var id_buf: [24]u8 = undefined;
                const id_s = try std.fmt.bufPrint(&id_buf, "{d}", .{id});
                var tx = try self.db.begin();
                errdefer tx.rollback() catch {};
                try tx.exec(self.alloc,
                    \\INSERT INTO bench_rows (id, name, payload, score) VALUES (?, ?, ?, ?)
                , &.{ id_s, "tx", "tx-payload", "7" });
                try tx.exec(self.alloc,
                    \\UPDATE bench_rows SET score = score + 1 WHERE id = ?
                , &.{id_s});
                try tx.exec(self.alloc,
                    \\DELETE FROM bench_rows WHERE id = ?
                , &.{id_s});
                try tx.commit();
                checksum +%= id;
            }
            per_rep[rep] = timer.readNs(self.io);
        }

        return self.finish("tx_write", ops, per_rep, checksum);
    }

    fn finish(self: *Bench, name: []const u8, ops: u64, per_rep: []u64, checksum: u64) PhaseResult {
        _ = self;
        std.mem.sort(u64, per_rep, {}, std.sort.asc(u64));
        const median_ns: f64 = @floatFromInt(per_rep[per_rep.len / 2]);
        const ops_f: f64 = @floatFromInt(ops);
        const ns_per_op = median_ns / ops_f;
        return .{
            .name = name,
            .ops = ops,
            .ns_per_op = ns_per_op,
            .ops_per_sec = ops_f / (median_ns / std.time.ns_per_s),
            .checksum = checksum,
        };
    }
};

pub fn main() !void {
    // A plain arena: the benchmark's own bookkeeping is not what is being
    // measured, and a tracking allocator in the hot path would dominate
    // every number below.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A file-backed DB: WAL, mmap and the reader pool all behave the way
    // they do in production, unlike `:memory:` which skips pooling
    // entirely. The path is fixed so the container run is reproducible.
    const db_path = try alloc.dupeZ(u8, "/tmp/ruangsql-bench/bench.db");
    std.Io.Dir.cwd().deleteFile(io, db_path) catch {};
    std.Io.Dir.cwd().createDirPath(io, "/tmp/ruangsql-bench") catch {};

    var bench = try Bench.open(alloc, io, db_path);
    defer bench.close();

    try bench.schema();
    try bench.seed();

    // Zig 0.16 has no `bufferedWriter`; `File.writer` takes an explicit
    // caller-owned buffer and flushes on demand.
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var file_w = stdout_file.writer(io, &out_buf);
    const w = &file_w.interface;

    try w.print(
        \\{{
        \\  "schema": "bench_rows",
        \\  "rows_seeded": {d},
        \\  "reps": {d},
        \\  "phases": [
        \\
    , .{ ROWS, REPS });

    const phases = [_]struct { name: []const u8, ops: u64, run: *const fn (*Bench, u64) anyerror!PhaseResult }{
        .{ .name = "insert", .ops = 20_000, .run = Bench.phaseInsert },
        .{ .name = "point_read", .ops = 50_000, .run = Bench.phasePointRead },
        .{ .name = "range_read", .ops = 5_000, .run = Bench.phaseRangeRead },
        .{ .name = "tx_write", .ops = 2_000, .run = Bench.phaseTxWrite },
    };

    for (phases, 0..) |p, idx| {
        const r = try p.run(&bench, p.ops);
        try w.print(
            \\    {{ "name": "{s}", "ops": {d}, "ns_per_op": {d:.2}, "ops_per_sec": {d:.0}, "checksum": {d} }}{s}
            \\
        , .{ r.name, r.ops, r.ns_per_op, r.ops_per_sec, r.checksum, if (idx + 1 < phases.len) "," else "" });
    }

    try w.print(
        \\  ],
        \\  "pool": {{ "readers": {d}, "outstanding_claims": {d}, "read_fallbacks": {d} }}
        \\}}
        \\
    , .{ bench.db.pool.count(), bench.db.outstandingClaims(), bench.db.readFallbackCount() });

    try file_w.flush();
}
