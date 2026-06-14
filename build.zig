const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize;

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

    // Add tests
    const lib_unit_tests = b.addTest(.{
        .root_module = vigil_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
