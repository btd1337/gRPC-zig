const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spice_dep = b.dependency("spice", .{});
    const spice_mod = spice_dep.module("spice");

    // Server executable
    const server = b.addExecutable(.{
        .name = "grpc-server",
        .root_source_file = .{ .path = "src/server.zig" },
        .target = target,
        .optimize = optimize,
    });
    server.addModule("spice", spice_mod);
    b.installArtifact(server);

    // Client executable
    const client = b.addExecutable(.{
        .name = "grpc-client",
        .root_source_file = .{ .path = "src/client.zig" },
        .target = target,
        .optimize = optimize,
    });
    client.addModule("spice", spice_mod);
    b.installArtifact(client);

    // Benchmark executable
    const benchmark = b.addExecutable(.{
        .name = "grpc-benchmark",
        .root_source_file = .{ .path = "src/benchmark.zig" },
        .target = target,
        .optimize = optimize,
    });
    benchmark.addModule("spice", spice_mod);
    b.installArtifact(benchmark);

    // Benchmark run step
    const run_benchmark = b.addRunArtifact(benchmark);
    run_benchmark.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_benchmark.addArgs(args);
    }
    const benchmark_step = b.step("benchmark", "Run benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    // Example executables
    const server_example = b.addExecutable(.{
        .name = "grpc-server-example",
        .root_source_file = .{ .path = "examples/basic_server.zig" },
        .target = target,
        .optimize = optimize,
    });
    server_example.addModule("spice", spice_mod);
    b.installArtifact(server_example);

    const client_example = b.addExecutable(.{
        .name = "grpc-client-example", 
        .root_source_file = .{ .path = "examples/basic_client.zig" },
        .target = target,
        .optimize = optimize,
    });
    client_example.addModule("spice", spice_mod);
    b.installArtifact(client_example);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/tests.zig" },
        .target = target,
        .optimize = optimize,
    });
    tests.addModule("spice", spice_mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}