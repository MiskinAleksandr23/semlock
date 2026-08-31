const std = @import("std");

const StripedCounter = struct {
    const stripe_count = 4;

    const Cell = struct {
        value: std.atomic.Value(usize) align(std.atomic.cache_line),
    };

    var next_stripe: std.atomic.Value(usize) = .init(0);
    threadlocal var current_stripe: ?usize = null;

    cells: [stripe_count]Cell,

    fn init() StripedCounter {
        return .{
            .cells = @splat(.{ .value = .init(0) }),
        };
    }

    fn stripeForCurrentThread() usize {
        if (current_stripe) |stripe| return stripe;

        const stripe = next_stripe.fetchAdd(1, .monotonic) % stripe_count;
        current_stripe = stripe;
        return stripe;
    }

    fn increment(self: *StripedCounter) void {
        const stripe = stripeForCurrentThread();
        _ = self.cells[stripe].value.fetchAdd(1, .seq_cst);
    }

    fn decrement(self: *StripedCounter) void {
        const stripe = stripeForCurrentThread();
        const previous = self.cells[stripe].value.fetchSub(1, .release);
        std.debug.assert(previous != 0);
    }

    fn isActive(
        self: *const StripedCounter,
        comptime order: std.builtin.AtomicOrder,
    ) bool {
        for (&self.cells) |*cell| {
            if (cell.value.load(order) != 0) return true;
        }
        return false;
    }
};

const VertexState = struct {
    const kPartsCount = 4;

    const Counter = struct {
        value: std.atomic.Value(usize) align(std.atomic.cache_line),
    };

    exclusive_count: [kPartsCount]Counter = undefined,
    active_count: [kPartsCount]StripedCounter = undefined,

    fn init() VertexState {
        var state: VertexState = undefined;

        inline for (0..kPartsCount) |idx| {
            state.exclusive_count[idx] = .{ .value = .init(0) };
            state.active_count[idx] = .init();
        }

        return state;
    }
};

pub const ConflictGraphLock = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    vertex_states: std.ArrayList(VertexState) = .empty,
    adjacency: std.ArrayList(std.ArrayList(usize)) = .empty,
    has_self_loop: std.ArrayList(bool) = .empty,

    pub fn init(allocator: std.mem.Allocator, vertex_count: usize) !Self {
        var self = Self{ .allocator = allocator };

        try self.adjacency.appendNTimes(allocator, .empty, vertex_count);
        errdefer self.adjacency.deinit(allocator);

        try self.vertex_states.appendNTimes(allocator, .init(), vertex_count);
        errdefer self.vertex_states.deinit(allocator);

        try self.has_self_loop.appendNTimes(allocator, false, vertex_count);
        errdefer self.has_self_loop.deinit(allocator);

        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.adjacency.items) |*neighbors| {
            neighbors.deinit(self.allocator);
        }
        self.adjacency.deinit(self.allocator);
        self.vertex_states.deinit(self.allocator);
        self.has_self_loop.deinit(self.allocator);
    }

    pub fn addConflict(self: *Self, first: usize, second: usize) !void {
        std.debug.assert(first < self.vertex_states.items.len);
        std.debug.assert(second < self.vertex_states.items.len);

        if (first == second) {
            self.has_self_loop.items[first] = true;
            return;
        }

        try self.adjacency.items[first].ensureUnusedCapacity(self.allocator, 1);
        try self.adjacency.items[second].ensureUnusedCapacity(self.allocator, 1);
        self.adjacency.items[first].appendAssumeCapacity(second);
        self.adjacency.items[second].appendAssumeCapacity(first);
    }

    fn isActive(
        self: *const Self,
        vertex_id: usize,
        left: usize,
        right: usize,
        comptime order: std.builtin.AtomicOrder,
    ) bool {
        const state = &self.vertex_states.items[vertex_id];
        if (self.has_self_loop.items[vertex_id]) {
            for (left..(right + 1)) |idx| {
                if (state.exclusive_count[idx].value.load(order) != 0) return true;
            }
            return false;
        }

        for (left..(right + 1)) |idx| {
            if (state.active_count[idx].isActive(order)) return true;
        }
        return false;
    }

    fn leave(self: *Self, vertex_id: usize, left: usize, right: usize) void {
        const state = &self.vertex_states.items[vertex_id];
        if (self.has_self_loop.items[vertex_id]) {
            for (left..(right + 1)) |idx| {
                const previous = state.exclusive_count[idx].value.fetchSub(1, .release);
                std.debug.assert(previous == 1);
            }
            return;
        }
        for (left..(right + 1)) |idx| {
            state.active_count[idx].decrement();
        }
    }

    pub fn acquire(self: *Self, vertex_id: usize, left: usize, right: usize) void {
        std.debug.assert(left < VertexState.kPartsCount);
        std.debug.assert(right < VertexState.kPartsCount);
        std.debug.assert(left <= right);
        std.debug.assert(vertex_id < self.vertex_states.items.len);

        acquire_loop: while (true) {
            var precheck_passed = true;
            for (self.adjacency.items[vertex_id].items) |neighbor_id| {
                if (self.isActive(neighbor_id, left, right, .monotonic)) {
                    precheck_passed = false;
                    break;
                }
            }

            if (!precheck_passed) {
                std.atomic.spinLoopHint();
                continue;
            }

            const state = &self.vertex_states.items[vertex_id];
            if (self.has_self_loop.items[vertex_id]) {
                var success_cas: [VertexState.kPartsCount]bool = @splat(false);
                var lock_self = true;
                for (left..(right + 1)) |idx| {
                    if (state.exclusive_count[idx].value.cmpxchgWeak(
                        0,
                        1,
                        .seq_cst,
                        .monotonic,
                    ) != null) {
                        lock_self = false;
                        break;
                    }
                    success_cas[idx] = true;
                }

                if (!lock_self) {
                    for (left..(right + 1)) |idx| {
                        if (success_cas[idx]) {
                            state.exclusive_count[idx].value.store(0, .release);
                        }
                    }
                    std.atomic.spinLoopHint();
                    continue :acquire_loop;
                }
            } else {
                for (left..(right + 1)) |idx| {
                    state.active_count[idx].increment();
                }
            }

            var validation_passed = true;
            for (self.adjacency.items[vertex_id].items) |neighbor_id| {
                if (self.isActive(neighbor_id, left, right, .seq_cst)) {
                    validation_passed = false;
                    break;
                }
            }

            if (!validation_passed) {
                self.leave(vertex_id, left, right);
                std.atomic.spinLoopHint();
                continue :acquire_loop;
            }

            return;
        }
    }

    pub fn release(self: *Self, vertex_id: usize, left: usize, right: usize) void {
        std.debug.assert(left < VertexState.kPartsCount);
        std.debug.assert(right < VertexState.kPartsCount);
        std.debug.assert(left <= right);
        std.debug.assert(vertex_id < self.vertex_states.items.len);
        self.leave(vertex_id, left, right);
    }
};

test "striped counter collects concurrent increments V2" {
    var counter = StripedCounter.init();

    const Worker = struct {
        fn run(target: *StripedCounter) void {
            for (0..10_000) |_| target.increment();
        }
    };

    var threads: [8]std.Thread = undefined;
    var spawned_count: usize = 0;
    defer {
        for (threads[0..spawned_count]) |thread| thread.join();
    }

    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{&counter});
        spawned_count += 1;
    }

    for (threads) |thread| thread.join();
    spawned_count = 0;

    var total: usize = 0;
    for (&counter.cells) |*cell| total += cell.value.load(.monotonic);
    try std.testing.expectEqual(80_000, total);
}

test "long-adder lock handles shared and self-conflicting vertices V2" {
    var graph = try ConflictGraphLock.init(std.testing.allocator, 2);
    defer graph.deinit();
    try graph.addConflict(0, 1);
    try graph.addConflict(1, 1);

    graph.acquire(0, 1, 2);
    try std.testing.expect(!graph.vertex_states.items[0].active_count[0].isActive(.monotonic));
    try std.testing.expect(graph.vertex_states.items[0].active_count[1].isActive(.monotonic));
    try std.testing.expect(graph.vertex_states.items[0].active_count[2].isActive(.monotonic));
    try std.testing.expect(!graph.vertex_states.items[0].active_count[3].isActive(.monotonic));
    graph.release(0, 1, 2);

    graph.acquire(1, 0, 1);
    try std.testing.expectEqual(1, graph.vertex_states.items[1].exclusive_count[0].value.load(.monotonic));
    try std.testing.expectEqual(1, graph.vertex_states.items[1].exclusive_count[1].value.load(.monotonic));
    try std.testing.expectEqual(0, graph.vertex_states.items[1].exclusive_count[2].value.load(.monotonic));
    try std.testing.expectEqual(0, graph.vertex_states.items[1].exclusive_count[3].value.load(.monotonic));
    graph.release(1, 0, 1);
}
