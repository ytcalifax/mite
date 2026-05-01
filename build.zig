pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = null,
        .os_tag = .windows,
        .abi = null,
    } });
    const optimize = b.standardOptimizeOption(.{});

    const vt = b.dependency("ghostty", .{}).module("ghostty-vt");

    const exe = b.addExecutable(.{
        .name = "mite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mite.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .win32_manifest = b.path("src/win32/mite.manifest"),
    });

    if (b.lazyDependency("win32", .{})) |win32_dep| {
        exe.root_module.addImport("win32", win32_dep.module("win32"));
        exe.root_module.addIncludePath(b.path("src/win32"));
    }
    exe.root_module.addImport("vt", vt);

    exe.addWin32ResourceFile(.{
        .file = b.path("src/win32/mite.rc"),
    });
    exe.subsystem = .Windows;

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&install.step);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "").dependOn(&run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mite.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (b.lazyDependency("win32", .{})) |win32_dep| {
        tests.root_module.addImport("win32", win32_dep.module("win32"));
        tests.root_module.addIncludePath(b.path("src/win32"));
    }
    tests.root_module.addImport("vt", vt);

    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}

const std = @import("std");
