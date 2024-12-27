const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Create library
    const lib = b.addStaticLibrary(.{
        .name = "vigil",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = b.path("src/vigil.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Make the library available as a package
    _ = b.addModule("vigil", .{
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

    exe.root_module.addImport("vigil", b.modules.get("vigil").?);
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
