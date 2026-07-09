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
    std.debug.print(
        \\
        \\<html>
        \\<head>
        \\<style>
        \\{s}
        \\</style>
        \\</head>
        \\<body>
        \\{f}
        \\</body>
        \\</html>
    , .{
        css,
        diagrams.fields.values()[0],
    });
}

const css =
    \\svg.railroad-diagram {
    \\    background-color: hsl(30,20%,95%);
    \\}
    \\svg.railroad-diagram path {
    \\    stroke-width: 3;
    \\    stroke: black;
    \\    fill: rgba(0,0,0,0);
    \\}
    \\svg.railroad-diagram text {
    \\    font: bold 14px monospace;
    \\    text-anchor: middle;
    \\    white-space: pre;
    \\}
    \\svg.railroad-diagram text.diagram-text {
    \\    font-size: 12px;
    \\}
    \\svg.railroad-diagram text.diagram-arrow {
    \\    font-size: 16px;
    \\}
    \\svg.railroad-diagram text.label {
    \\    text-anchor: start;
    \\}
    \\svg.railroad-diagram text.comment {
    \\    font: italic 12px monospace;
    \\}
    \\svg.railroad-diagram g.non-terminal text {
    \\    /*font-style: italic;*/
    \\}
    \\svg.railroad-diagram rect {
    \\    stroke-width: 3;
    \\    stroke: black;
    \\    fill: hsl(120,100%,90%);
    \\}
    \\svg.railroad-diagram rect.group-box {
    \\    stroke: gray;
    \\    stroke-dasharray: 10 5;
    \\    fill: none;
    \\}
    \\svg.railroad-diagram path.diagram-text {
    \\    stroke-width: 3;
    \\    stroke: black;
    \\    fill: white;
    \\    cursor: help;
    \\}
    \\svg.railroad-diagram g.diagram-text:hover path.diagram-text {
    \\    fill: #eee;
    \\}
    \\
;
