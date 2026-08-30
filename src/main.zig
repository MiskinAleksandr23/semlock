const std = @import("std");
const semantic_lock = @import("semantic_lock");

pub fn main(init: std.process.Init) !void {
    var graph = try semantic_lock.ConflictGraphLock.init(init.gpa, 10);
    defer graph.deinit();
}
