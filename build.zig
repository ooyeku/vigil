const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const package_version = readPackageVersion(b);
    const build_options = b.addOptions();
    build_options.addOption(std.SemanticVersion, "version", package_version);

    // Create the vigil module
    const vigil_mod = b.addModule("vigil", .{
        .root_source_file = b.path("src/vigil.zig"),
        .target = target,
        .optimize = optimize,
    });
    vigil_mod.addOptions("vigil_build_options", build_options);

    // Keep the reduced legacy compatibility module buildable during migration.
    const legacy_mod = b.addModule("vigil/legacy", .{
        .root_source_file = b.path("src/legacy.zig"),
        .target = target,
        .optimize = optimize,
    });
    legacy_mod.addOptions("vigil_build_options", build_options);

    // Add tests
    const lib_unit_tests = b.addTest(.{
        .root_module = vigil_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const legacy_unit_tests = b.addTest(.{
        .root_module = legacy_mod,
    });
    const run_legacy_unit_tests = b.addRunArtifact(legacy_unit_tests);
    const run_legacy_after_root = b.addRunArtifact(legacy_unit_tests);
    run_legacy_after_root.step.dependOn(&run_lib_unit_tests.step);
    const root_test_step = b.step("test-root", "Run current API unit tests");
    root_test_step.dependOn(&run_lib_unit_tests.step);
    const legacy_test_step = b.step("test-legacy", "Run reduced legacy compatibility tests");
    legacy_test_step.dependOn(&run_legacy_unit_tests.step);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_legacy_after_root.step);
}

fn readPackageVersion(b: *std.Build) std.SemanticVersion {
    const contents = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| std.debug.panic("unable to read build.zig.zon: {}", .{err});
    defer b.allocator.free(contents);

    const key = ".version";
    const key_start = std.mem.indexOf(u8, contents, key) orelse
        std.debug.panic("build.zig.zon is missing .version", .{});
    const after_key = contents[key_start + key.len ..];
    const equals_index = std.mem.indexOfScalar(u8, after_key, '=') orelse
        std.debug.panic("build.zig.zon .version is missing '='", .{});
    const after_equals = after_key[equals_index + 1 ..];
    const open_quote = std.mem.indexOfScalar(u8, after_equals, '"') orelse
        std.debug.panic("build.zig.zon .version is missing opening quote", .{});
    const version_start = open_quote + 1;
    const version_tail = after_equals[version_start..];
    const close_quote = std.mem.indexOfScalar(u8, version_tail, '"') orelse
        std.debug.panic("build.zig.zon .version is missing closing quote", .{});

    return std.SemanticVersion.parse(version_tail[0..close_quote]) catch |err|
        std.debug.panic("invalid build.zig.zon .version: {}", .{err});
}
