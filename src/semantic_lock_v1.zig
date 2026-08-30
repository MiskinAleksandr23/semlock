const std = @import("std");

const VertexState = struct {
    active_count: std.atomic.Value(usize) align(std.atomic.cache_line),

    fn init() VertexState {
        return .{ .active_count = .init(0) };
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

    pub fn acquire(self: *Self, vertex_id: usize, _: usize, _: usize) void {
        std.debug.assert(vertex_id < self.vertex_states.items.len);

        while (true) {
            var precheck_passed = true;
            for (self.adjacency.items[vertex_id].items) |neighbor_id| {
                if (self.vertex_states.items[neighbor_id].active_count.load(.monotonic) != 0) {
                    precheck_passed = false;
                    break;
                }
            }

            if (!precheck_passed) {
                std.atomic.spinLoopHint();
                continue;
            }

            if (self.has_self_loop.items[vertex_id]) {
                if (self.vertex_states.items[vertex_id].active_count.cmpxchgWeak(
                    0,
                    1,
                    .seq_cst,
                    .monotonic,
                ) != null) {
                    std.atomic.spinLoopHint();
                    continue;
                }
            } else {
                _ = self.vertex_states.items[vertex_id].active_count.fetchAdd(1, .seq_cst);
            }

            var validation_passed = true;
            for (self.adjacency.items[vertex_id].items) |neighbor_id| {
                if (self.vertex_states.items[neighbor_id].active_count.load(.seq_cst) != 0) {
                    validation_passed = false;
                    break;
                }
            }

            if (!validation_passed) {
                _ = self.vertex_states.items[vertex_id].active_count.fetchSub(1, .release);
                std.atomic.spinLoopHint();
                continue;
            }

            return;
        }
    }

    pub fn release(self: *Self, vertex_id: usize, _: usize, _: usize) void {
        std.debug.assert(vertex_id < self.vertex_states.items.len);
        _ = self.vertex_states.items[vertex_id].active_count.fetchSub(1, .release);
    }
};
