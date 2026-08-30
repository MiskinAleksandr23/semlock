const std = @import("std");
const zbench = @import("zbench");
const semantic_lock = @import("semantic_lock");

const Query = struct {
    left: usize,
    right_exclusive: usize,
};

const PartBounds = struct {
    left: usize,
    right: usize,
};

const ConflictLock = semantic_lock.ConflictGraphLockV2;

const parts_count = 4;
const max_query_len = 1 << 11;
const array_len = 1 << 12;
const part_len = array_len / parts_count;
const work_count = 1 << 15;
const thread_count = 6;

const Operation = enum {
    set_range,
    add_range,
    sum_range,
    point_get,
    point_set,
};

const Request = union(Operation) {
    set_range: struct {
        query: Query,
        value: usize,
    },
    add_range: struct {
        query: Query,
        value: usize,
    },
    sum_range: Query,
    point_get: usize,
    point_set: struct {
        index: usize,
        value: usize,
    },
};

const Workload = struct {
    name: []const u8,
    point_set: u8 = 0,
    point_get: u8 = 0,
    set_range: u8 = 0,
    add_range: u8 = 0,
    sum_range: u8 = 0,

    fn chooseOperation(self: *const Workload, random: std.Random) Operation {
        const choice: u16 = random.uintLessThan(u8, 100);

        var upper: u16 = self.point_set;
        if (choice < upper) return .point_set;

        upper += self.point_get;
        if (choice < upper) return .point_get;

        upper += self.set_range;
        if (choice < upper) return .set_range;

        upper += self.add_range;
        if (choice < upper) return .add_range;

        return .sum_range;
    }

    fn total(self: *const Workload) u16 {
        return @as(u16, self.point_set) +
            @as(u16, self.point_get) +
            @as(u16, self.set_range) +
            @as(u16, self.add_range) +
            @as(u16, self.sum_range);
    }

    pub fn run(self: *Workload, allocator: std.mem.Allocator) void {
        runArrayBenchmark(allocator, self) catch |err| {
            std.debug.panic("benchmark failed: {s}", .{@errorName(err)});
        };
    }
};

const workloads = [_]Workload{
    .{
        .name = "(a) 50% point-set, 50% point-get",
        .point_set = 50,
        .point_get = 50,
    },
    .{
        .name = "(b) 50% point-get, 50% sumRange",
        .point_get = 50,
        .sum_range = 50,
    },
    .{
        .name = "(c) 20% of every operation",
        .point_set = 20,
        .point_get = 20,
        .set_range = 20,
        .add_range = 20,
        .sum_range = 20,
    },
    .{
        .name = "(d) 40% get/sumRange, 10% set/addRange",
        .point_set = 10,
        .point_get = 40,
        .add_range = 10,
        .sum_range = 40,
    },
    .{
        .name = "(e) 40% get/set, 10% sumRange/addRange",
        .point_set = 40,
        .point_get = 40,
        .add_range = 10,
        .sum_range = 10,
    },
    .{
        .name = "(f) 90% addRange, 5% setRange/sumRange",
        .set_range = 5,
        .add_range = 90,
        .sum_range = 5,
    },
};

fn randomQuery(random: std.Random, size: usize, max_length: usize) Query {
    std.debug.assert(size > 0);
    std.debug.assert(max_length > 0);
    std.debug.assert(max_length <= size);

    const length = random.intRangeAtMost(usize, 1, max_length);
    const left = random.intRangeAtMost(usize, 0, size - length);

    return .{
        .left = left,
        .right_exclusive = left + length,
    };
}

fn randomRequest(random: std.Random, operation: Operation) Request {
    return switch (operation) {
        .point_set => .{ .point_set = .{
            .index = random.uintLessThan(usize, array_len),
            .value = 1,
        } },
        .point_get => .{ .point_get = random.uintLessThan(usize, array_len) },
        .set_range => .{ .set_range = .{
            .query = randomQuery(random, array_len, max_query_len),
            .value = 1,
        } },
        .add_range => .{ .add_range = .{
            .query = randomQuery(random, array_len, max_query_len),
            .value = 1,
        } },
        .sum_range => .{ .sum_range = randomQuery(random, array_len, max_query_len) },
    };
}

fn requestBounds(request: Request) PartBounds {
    const query: Query = switch (request) {
        .point_set => |point| .{
            .left = point.index,
            .right_exclusive = point.index + 1,
        },
        .point_get => |index| .{
            .left = index,
            .right_exclusive = index + 1,
        },
        .set_range => |range| range.query,
        .add_range => |range| range.query,
        .sum_range => |query| query,
    };

    return .{
        .left = query.left / part_len,
        .right = (query.right_exclusive - 1) / part_len,
    };
}

fn executeRequest(
    graph: *ConflictLock,
    values: []std.atomic.Value(usize),
    request: Request,
) void {
    const operation = std.meta.activeTag(request);
    const vertex_id: usize = @backingInt(operation);
    const bounds = requestBounds(request);

    graph.acquire(vertex_id, bounds.left, bounds.right);
    defer graph.release(vertex_id, bounds.left, bounds.right);

    switch (request) {
        .point_set => |point| values[point.index].store(point.value, .monotonic),
        .point_get => |index| std.mem.doNotOptimizeAway(values[index].load(.monotonic)),
        .set_range => |range| {
            for (range.query.left..range.query.right_exclusive) |index| {
                values[index].store(range.value, .monotonic);
            }
        },
        .add_range => |range| {
            for (range.query.left..range.query.right_exclusive) |index| {
                _ = values[index].fetchAdd(range.value, .monotonic);
            }
        },
        .sum_range => |query| {
            var sum: usize = 0;
            for (query.left..query.right_exclusive) |index| {
                sum +%= values[index].load(.monotonic);
            }
            std.mem.doNotOptimizeAway(sum);
        },
    }
}

fn runWorker(
    graph: *ConflictLock,
    values: []std.atomic.Value(usize),
    workload: *const Workload,
    worker_index: usize,
) void {
    var prng = std.Random.DefaultPrng.init(@intCast(worker_index + 1));
    const random = prng.random();

    for (0..work_count) |_| {
        const operation = workload.chooseOperation(random);
        const request = randomRequest(random, operation);
        executeRequest(graph, values, request);
    }
}

fn addArrayConflicts(graph: *ConflictLock) !void {
    try graph.addConflict(@backingInt(Operation.set_range), @backingInt(Operation.set_range));
    try graph.addConflict(@backingInt(Operation.set_range), @backingInt(Operation.add_range));
    try graph.addConflict(@backingInt(Operation.set_range), @backingInt(Operation.sum_range));
    try graph.addConflict(@backingInt(Operation.set_range), @backingInt(Operation.point_get));
    try graph.addConflict(@backingInt(Operation.set_range), @backingInt(Operation.point_set));
    try graph.addConflict(@backingInt(Operation.add_range), @backingInt(Operation.sum_range));
    try graph.addConflict(@backingInt(Operation.add_range), @backingInt(Operation.point_get));
    try graph.addConflict(@backingInt(Operation.add_range), @backingInt(Operation.point_set));
    try graph.addConflict(@backingInt(Operation.sum_range), @backingInt(Operation.point_set));
}

fn runArrayBenchmark(allocator: std.mem.Allocator, workload: *const Workload) !void {
    std.debug.assert(workload.total() == 100);

    var values: std.ArrayList(std.atomic.Value(usize)) = .empty;
    defer values.deinit(allocator);
    try values.appendNTimes(allocator, .init(0), array_len);

    var graph = try ConflictLock.init(allocator, 5);
    defer graph.deinit();
    try addArrayConflicts(&graph);

    var threads: [thread_count]std.Thread = undefined;
    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |thread| thread.join();
    }

    for (0..thread_count) |worker_index| {
        threads[spawned_count] = try std.Thread.spawn(
            .{},
            runWorker,
            .{ &graph, values.items, workload, worker_index },
        );
        spawned_count += 1;
    }
}

pub fn main(init: std.process.Init) !void {
    var benchmark = zbench.Benchmark.init(init.gpa, .{
        .iterations = 100,
        .items_per_run = thread_count * work_count,
    });
    defer benchmark.deinit();

    for (&workloads) |*workload| {
        try benchmark.addParam(workload.name, workload, .{});
    }

    const stdout: std.Io.File = .stdout();
    try benchmark.run(init.io, stdout);
}
