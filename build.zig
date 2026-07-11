const std = @import("std");
const ziggy = @import("ziggy");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ziggy_dep = b.dependency("ziggy", .{
        .target = target,
        .optimize = optimize,
    });
    const ziggy_mod = ziggy_dep.module("ziggy");

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

    const test_step = b.step("test", "run tests");

    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/schema_check.zig"),
        .imports = &.{.{ .name = "railroad", .module = mod }},
    });
    const check_schema = ziggy.addTypeCheckStep(
        b,
        target,
        optimize,
        types_mod,
        b.path(".ziggy-schema"),
    );
    test_step.dependOn(check_schema);
}
