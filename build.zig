const std = @import("std");
const zon = @import("build.zig.zon");
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

    const schema_mod = b.createModule(.{
        .root_source_file = b.path(".ziggy-schema"),
    });

    const example_ziggy_mod = b.createModule(.{
        .root_source_file = b.path("example.ziggy"),
    });

    const nightwatch = b.dependency("nightwatch", .{
        .target = target,
        .optimize = optimize,
        .macos_fsevents = true,
    });
    const nightwatch_mod = nightwatch.module("nightwatch");

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const exe = b.addExecutable(.{
        .name = "railroad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "railroad", .module = mod },
                .{ .name = "ziggy", .module = ziggy_mod },
                .{ .name = ".ziggy-schema", .module = schema_mod },
                .{ .name = "example.ziggy", .module = example_ziggy_mod },
                .{ .name = "nightwatch", .module = nightwatch_mod },
            },
        }),
    });
    exe.root_module.addOptions("options", options);

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

    const release = b.step("release", "create release builds");
    setupReleaseStep(
        b,
        release,
        options,
        mod,
        ziggy_mod,
        schema_mod,
        example_ziggy_mod,
        nightwatch_mod,
    );
}

pub fn setupReleaseStep(
    b: *std.Build,
    release_step: *std.Build.Step,
    options: *std.Build.Step.Options,
    rr_mod: *std.Build.Module,
    ziggy_mod: *std.Build.Module,
    schema_mod: *std.Build.Module,
    example_ziggy_mod: *std.Build.Module,
    nightwatch_mod: *std.Build.Module,
) void {
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (targets) |t| {
        const release_target = b.resolveTargetQuery(t);
        const optimize: std.builtin.OptimizeMode = .ReleaseFast;

        const release_cli_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = release_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "railroad", .module = rr_mod },
                .{ .name = "ziggy", .module = ziggy_mod },
                .{ .name = ".ziggy-schema", .module = schema_mod },
                .{ .name = "example.ziggy", .module = example_ziggy_mod },
                .{ .name = "nightwatch", .module = nightwatch_mod },
            },
        });
        release_cli_mod.addOptions("options", options);

        const release_exe = b.addExecutable(.{
            .name = "railroad",
            .root_module = release_cli_mod,
        });

        switch (t.os_tag.?) {
            .macos, .windows => {
                const archive_name = b.fmt("{t}-{s}.zip", .{
                    zon.name,
                    t.zigTriple(b.allocator) catch unreachable,
                });

                const zip = b.addSystemCommand(&.{
                    "zip",
                    "-9",
                    // "-dd",
                    "-q",
                    "-j",
                });
                const archive = zip.addOutputFileArg(archive_name);
                zip.addDirectoryArg(release_exe.getEmittedBin());
                _ = zip.captureStdOut(.{});

                release_step.dependOn(&b.addInstallFileWithDir(
                    archive,
                    .{ .custom = "releases" },
                    archive_name,
                ).step);
            },
            else => {
                const archive_name = b.fmt("{t}-{s}.tar.xz", .{
                    zon.name,
                    t.zigTriple(b.allocator) catch unreachable,
                });

                const tar = b.addSystemCommand(&.{
                    "gtar",
                    "-cJf",
                });

                const archive = tar.addOutputFileArg(archive_name);
                tar.addArg("-C");

                tar.addDirectoryArg(release_exe.getEmittedBinDirectory());
                tar.addArg("railroad");
                _ = tar.captureStdOut(.{});

                release_step.dependOn(&b.addInstallFileWithDir(
                    archive,
                    .{ .custom = "releases" },
                    archive_name,
                ).step);
            },
        }
    }
}
