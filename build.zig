const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_optimize = b.option(
        std.builtin.Optimize,
        "bench-optimize",
        "Optimization mode for benchmarks",
    ) orelse .fast;
    const test_filter = b.option([]const u8, "test-filter", "Run only tests matching this name");

    const semantic_lock_module = b.addModule("semantic_lock", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app = b.addExecutable(.{
        .name = "semantic_lock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "semantic_lock", .module = semantic_lock_module }},
        }),
    });
    b.installArtifact(app);

    const run_app = b.addRunArtifact(app);
    run_app.step.dependOn(b.getInstallStep());
    run_app.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_app.step);

    const unit_tests = b.addTest(.{
        .root_module = semantic_lock_module,
        .filters = if (test_filter) |filter| &.{filter} else &.{},
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const benchmark_semantic_lock_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    const zbench_module = b.dependency("zbench", .{
        .target = target,
        .optimize = bench_optimize,
    }).module("zbench");
    const benchmark = b.addExecutable(.{
        .name = "semantic-lock-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/conflict_graph.zig"),
            .target = target,
            .optimize = bench_optimize,
            .imports = &.{
                .{ .name = "semantic_lock", .module = benchmark_semantic_lock_module },
                .{ .name = "zbench", .module = zbench_module },
            },
        }),
    });
    const run_benchmark = b.addRunArtifact(benchmark);

    const benchmark_step = b.step("bench", "Run benchmarks (fast by default)");
    benchmark_step.dependOn(&run_benchmark.step);
}
