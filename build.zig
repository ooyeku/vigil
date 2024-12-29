const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "vigil",
        .root_source_file = b.path("src/vigil.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Make the library available as a package
    _ = b.addModule("vigil_lib", .{
        .root_source_file = b.path("src/vigil.zig"),
    });

    // Install library artifacts
    b.installArtifact(lib);

    // Create example executable
    const exe = b.addExecutable(.{
        .name = "vigil-example",
        .root_source_file = b.path("src/example.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("vigil", b.modules.get("vigil_lib").?);
    b.installArtifact(exe);

    // Create run step for the example
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&run_cmd.step);

    // Add tests
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/vigil.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
