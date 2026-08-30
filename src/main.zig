const std = @import("std");
const zbench = @import("zbench");

const kCacheSize = 64;

pub const GraphEntry = struct {
    const Self = @This();
    cnt: std.atomic.Value(usize) align(kCacheSize),

    pub fn init() Self {
        return Self{
            .cnt = .init(0),
        };
    }

    inline fn check_contented(self: *Self) bool {
        return self.cnt.load(.monotonic) != 0;
    }

    inline fn try_lock_entry(self: *Self) bool {
        return self.cnt.cmpxchgWeak(0, 1, .acquire, .monotonic) == null;
    }

    fn lock_entry(self: *Self) void {
        while (!self.try_lock_entry()) {
            while (self.cnt.load(.monotonic)) {
                std.atomic.spinLoopHint();
            }
        }
    }
    inline fn unlock_entry(self: *Self) void {
        self.cnt.store(0, .release);
    }

    inline fn atomic_incr(self: *Self, add: usize) void {
        _ = self.cnt.fetchAdd(add, .acq_rel);
    }
    inline fn atomic_dec(self: *Self, sub: usize) void {
        _ = self.cnt.fetchSub(sub, .release);
    }
};

pub const SemGraph = struct {
    const Self = @This();

    fn init(verticesCount: usize, alloc: std.mem.Allocator) !Self {
        var self = Self{
            .alloc = alloc,
            .verticesCount = verticesCount,
        };

        try self.graphMatrix.appendNTimes(alloc, .empty, verticesCount);
        errdefer self.graphMatrix.deinit(alloc);

        try self.verticesEntries.appendNTimes(alloc, .init(), verticesCount);
        errdefer self.verticesEntries.deinit(alloc);

        try self.verticesEntriesSame.appendNTimes(alloc, false, verticesCount);
        errdefer self.verticesEntriesSame.deinit(alloc);

        return self;
    }

    fn deinit(self: *Self) void {
        self.verticesEntries.deinit(self.alloc);
        for (self.graphMatrix.items) |*item| {
            item.deinit(self.alloc);
        }
        self.graphMatrix.deinit(self.alloc);
        self.verticesEntriesSame.deinit(self.alloc);
    }

    alloc: std.mem.Allocator,
    verticesCount: usize,
    verticesEntries: std.ArrayList(GraphEntry) = .empty,
    graphMatrix: std.ArrayList(std.ArrayList(usize)) = .empty, // (u, u) not in graph always here
    verticesEntriesSame: std.ArrayList(bool) = .empty, // (u, u) \in graph

    // TODO: biderectional??
    fn addEdge(self: *Self, from: usize, to: usize) !void {
        try self.graphMatrix.items[from].append(self.alloc, to);
        if (from != to) {
            try self.graphMatrix.items[to].append(self.alloc, from);
        } else {
            self.verticesEntriesSame.items[from] = true;
        }
    }
    fn acquireVertex(self: *Self, id: usize) void {
        while (true) {
            var precheck_passed: bool = true;
            // Precheck phase
            for (self.graphMatrix.items[id].items) |neighbourIdx| {
                if (self.verticesEntries.items[neighbourIdx].check_contented()) {
                    precheck_passed = false;
                    break;
                }
            }

            if (!precheck_passed) {
                std.atomic.spinLoopHint();
                continue;
            }

            // Reservation
            if (self.verticesEntriesSame.items[id]) {
                // (u, u) \in graph
                if (!self.verticesEntries.items[id].try_lock_entry()) {
                    std.atomic.spinLoopHint();
                    continue;
                }
            } else {
                self.verticesEntries.items[id].atomic_incr(1);
            }
            // Validation
            var validation_passed: bool = true;
            for (self.graphMatrix.items[id].items) |neighbourIdx| {
                if (self.verticesEntries.items[neighbourIdx].check_contented()) {
                    validation_passed = false;
                    break;
                }
            }
            if (!validation_passed) {
                self.verticesEntries.items[id].atomic_dec(1);
                std.atomic.spinLoopHint();
                continue;
            }
            return;
            // Acquire lock
        }
    }
    fn releaseVertex(self: *Self, id: usize) void {
        // Valid in both cases: (u, u) (\in or \not in) E
        self.verticesEntries.items[id].atomic_dec(1);
    }
};

pub fn main(init: std.process.Init) !void {
    const semLock = try SemGraph.init(10, init.gpa);
    _ = semLock;
}

test "SanityCheck" {
    var semGraph: SemGraph = try .init(2, std.testing.allocator);
    try semGraph.addEdge(0, 1);
    defer semGraph.deinit();

    const kWorkCount = 20000000;

    var start: isize = 0;

    const ThreadWork = struct {
        fn work1(_semGraph: *SemGraph, _start: *isize) void {
            for (0..kWorkCount) |_| {
                _semGraph.acquireVertex(0);
                _start.* += 1;
                _semGraph.releaseVertex(0);
            }
        }
        fn work2(_semGraph: *SemGraph, _start: *isize) void {
            for (0..kWorkCount) |_| {
                _semGraph.acquireVertex(1);
                _start.* -= 1;
                _semGraph.releaseVertex(1);
            }
        }
    };

    const th1 = try std.Thread.spawn(.{}, ThreadWork.work1, .{ &semGraph, &start });
    const th2 = try std.Thread.spawn(.{}, ThreadWork.work2, .{ &semGraph, &start });

    th1.join();
    th2.join();
    try std.testing.expect(start == 0);
}

fn myBenchmark(allocator: std.mem.Allocator) void {
    // Code to benchmark here
    _ = allocator;
}

test "bench test" {
    const stdout: std.Io.File = .stdout();

    var bench = zbench.Benchmark.init(std.testing.allocator, .{});
    defer bench.deinit();

    try bench.add("My Benchmark", myBenchmark, .{});

    try bench.run(std.testing.io, stdout);
}
