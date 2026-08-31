const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_optimize = b.option(
        std.builtin.Optimize,
        "bench-optimize",
        "Optimization mode for benchmarks",
    ) orelse .fast;
    const bench_use_v2 = b.option(bool, "bench-v2", "Use ConflictGraphLockV2") orelse true;
    const bench_v2_long_adder = b.option(bool, "bench-v2-long-adder", "Use V2 with striped counters") orelse false;
    const bench_long_adder = b.option(bool, "bench-long-adder", "Use V1 with striped counters") orelse false;
    const bench_no_lock = b.option(bool, "bench-no-lock", "Disable conflict locking") orelse false;
    const bench_threads = b.option(usize, "bench-threads", "Number of benchmark worker threads") orelse 11;
    const bench_json = b.option(bool, "bench-json", "Write benchmark results as JSON") orelse false;
    const bench_parts_count = b.option(usize, "bench-parts-count", "Number of array partitions") orelse 64;
    const bench_stripe_count = b.option(usize, "bench-stripe-count", "Number of LongAdder stripes") orelse 4;
    const bench_array_len = b.option(usize, "bench-array-len", "Benchmark array length") orelse 1 << 26;
    const bench_max_query_len = b.option(usize, "bench-max-query-len", "Maximum range-query length") orelse 10_000;
    const bench_work_count = b.option(usize, "bench-work-count", "Requests per worker and iteration") orelse 1 << 18;
    const bench_iterations = b.option(u32, "bench-iterations", "Measured benchmark iterations") orelse 20;
    const test_filter = b.option([]const u8, "test-filter", "Run only tests matching this name");

    const benchmark_options = b.addOptions();
    benchmark_options.addOption(bool, "use_v2", bench_use_v2);
    benchmark_options.addOption(bool, "v2_long_adder", bench_v2_long_adder);
    benchmark_options.addOption(bool, "long_adder", bench_long_adder);
    benchmark_options.addOption(bool, "no_lock", bench_no_lock);
    benchmark_options.addOption(usize, "thread_count", bench_threads);
    benchmark_options.addOption(bool, "json", bench_json);
    benchmark_options.addOption(usize, "parts_count", bench_parts_count);
    benchmark_options.addOption(usize, "stripe_count", bench_stripe_count);
    benchmark_options.addOption(usize, "array_len", bench_array_len);
    benchmark_options.addOption(usize, "max_query_len", bench_max_query_len);
    benchmark_options.addOption(usize, "work_count", bench_work_count);
    benchmark_options.addOption(u32, "iterations", bench_iterations);
    const benchmark_options_module = benchmark_options.createModule();

    const semantic_lock_module = b.addModule("semantic_lock", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    semantic_lock_module.addImport("bench_options", benchmark_options_module);

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
    benchmark_semantic_lock_module.addImport("bench_options", benchmark_options_module);
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
    benchmark.root_module.addImport("bench_options", benchmark_options_module);

    const compile_benchmark_step = b.step("bench-compile", "Compile benchmarks without running them");
    compile_benchmark_step.dependOn(&benchmark.step);

    const run_benchmark = b.addRunArtifact(benchmark);

    const benchmark_step = b.step("bench", "Run benchmarks (fast by default)");
    benchmark_step.dependOn(&run_benchmark.step);
}
