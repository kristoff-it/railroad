const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ziggy = b.dependency("ziggy", .{});
    const ziggy_mod = ziggy.module("ziggy");

    const mod = b.addModule("railroad", .{
        .root_source_file = b.path("src/root.zig"),
    });

    mod.addImport("ziggy", ziggy_mod);

    const exe = b.addExecutable(.{
        .name = "railroad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "railroad", .module = mod },
                .{ .name = "ziggy", .module = ziggy_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "run railroad");
    const run_exe = b.addRunArtifact(exe);
    run_exe.addPassthruArgs();
    run_step.dependOn(&run_exe.step);
}
