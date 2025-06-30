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
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const wasm_lib = b.addExecutable(.{
        .name = "bisharper-wasm",
        .root_source_file = b.path("src/lzss/wasm/extern.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });

    // WASM-specific settings
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;
    wasm_lib.import_memory = true;
    wasm_lib.stack_size = 1024 * 1024;

    // Create separate install step for WASM
    const wasm_install = b.addInstallArtifact(wasm_lib, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });

    // Build steps
    const wasm_step = b.step("wasm", "Build WASM library");
    wasm_step.dependOn(&wasm_install.step);

    const native_step = b.step("native", "Build native library and executable");
    native_step.dependOn(&lib.step);
    native_step.dependOn(&exe.step);

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
