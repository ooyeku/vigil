const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create the vigil module
    const vigil_mod = b.addModule("vigil", .{
        .root_source_file = b.path("src/vigil.zig"),
        .target = target,
    });

    // Create the legacy submodule
    _ = b.addModule("vigil/legacy", .{
        .root_source_file = b.path("src/legacy.zig"),
        .target = target,
    });

    // Create example executable
    const exe = b.addExecutable(.{
        .name = "vigil-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vigil", .module = vigil_mod },
            },
        }),
    });

    b.installArtifact(exe);

    // Create run step for the example
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    // Add vigilant server example
    const server_exe = b.addExecutable(.{
        .name = "vigilant-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/vigilant_server/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vigil", .module = vigil_mod },
            },
        }),
    });
    b.installArtifact(server_exe);

    const server_run_cmd = b.addRunArtifact(server_exe);
    server_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        server_run_cmd.addArgs(args);
    }
    const server_run_step = b.step("example-server", "Run the vigilant server example");
    server_run_step.dependOn(&server_run_cmd.step);

    // Add Python test server command
    const test_server_cmd = b.addSystemCommand(&.{
        "python3",
        "examples/vigilant_server/test_server.py",
    });

    const test_server_step = b.step(
        "test-server",
        "Run the vigilant server Python test script",
    );
    test_server_step.dependOn(&test_server_cmd.step);

    // Add tests
    const lib_unit_tests = b.addTest(.{
        .root_module = vigil_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
