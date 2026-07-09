const std = @import("std");
const Io = std.Io;
const ziggy = @import("ziggy");
const railroad = @import("railroad");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) @panic("bad arguments");

    const file_path = args[1];

    const src = Io.Dir.cwd().readFileAllocOptions(
        io,
        file_path,
        arena,
        .limited(ziggy.max_size),
        .of(u8),
        0,
    ) catch |err| {
        std.process.fatal("unable to read '{s}': {t}", .{ file_path, err });
    };

    var meta: ziggy.Deserializer.Meta = .init;
    var diagrams = ziggy.deserializeLeaky(ziggy.Dictionary(railroad.Diagram), arena, src, &meta, .{}) catch |err| {
        if (err == error.OutOfMemory) @panic("oom");
        std.process.fatal("{f}", .{meta.reportErrorsFmt(arena, .{}, file_path, src, err)});
    };

    diagrams.fields.values()[0].layout();
    std.debug.print("{f}", .{diagrams.fields.values()[0]});
}
