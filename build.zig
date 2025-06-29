const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const dep_zigrc = b.dependency("zigrc", .{}).artifact("zig-rc");
    const lib = b.addSharedLibrary(.{
        .name = "bisharper",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.root_module.addImport("zigrc", dep_zigrc.root_module);
    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "bisharper",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkLibrary(lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);


    const tests = b.addTest(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("zigrc", dep_zigrc.root_module);

    const run_unit_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_unit_tests.step);
}
