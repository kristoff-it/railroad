const std = @import("std");
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ziggy = @import("ziggy");
const railroad = @import("railroad");
const nightwatch = @import("nightwatch");

const Command = enum {
    build,
    live,
    @"install-schema",
    help,
    @"-h",
    @"--help",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fatalHelp();

    const command = std.meta.stringToEnum(Command, args[1]) orelse fatalHelp();
    switch (command) {
        .build => build(io, arena, args[2..]),
        .live => live(io, args[2..]),
        .@"install-schema" => install_schema(io, args[2..]),
        .help, .@"--help", .@"-h" => fatalHelp(),
    }
}

const BuildCommand = struct {
    input_path: []const u8,
    output_dir_path: []const u8,

    fn init(args: []const []const u8) BuildCommand {
        var input_path: ?[]const u8 = null;
        var output_dir_path: ?[]const u8 = null;
        var i: usize = 0;

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (startsWith(u8, arg, "--output=")) {
                if (input_path != null) fatalErr("more than one '--output' argument", .{});

                const output_val = arg["--output=".len..];
                if (output_val.len == 0) fatalErr("missing '--output' value", .{});
                output_dir_path = output_val;
            } else if (eql(u8, arg, "--output")) {
                if (input_path != null) fatalErr("more than one '--output' argument", .{});

                i += 1;
                if (i == args.len) fatalErr("missing '--output' value", .{});
                output_dir_path = args[i];
            } else if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) {
                std.process.fatal(help, .{});
            } else {
                if (input_path != null) fatalErr("more than one input file argument", .{});
                input_path = arg;
            }
        }

        return .{
            .input_path = input_path orelse fatalErr("missing input file argument", .{}),
            .output_dir_path = output_dir_path orelse "diagrams",
        };
    }

    const help =
        \\Usage: railroad build INPUT_ZIGGY_FILE [OPTIONS]
        \\
        \\Build SVG files from a Ziggy diagram input file.
        \\
        \\Command specific options:
        \\ --output, -o DIR  Directory where to put the generated SVG
        \\                   files, defaults to 'diagrams/'.
        \\
        \\
    ;
};
fn build(io: Io, arena: Allocator, args: []const []const u8) void {
    const cmd: BuildCommand = .init(args);

    const src = Io.Dir.cwd().readFileAllocOptions(
        io,
        cmd.input_path,
        arena,
        .limited(ziggy.max_size),
        .of(u8),
        0,
    ) catch |err| fatalErr("unable to read '{s}': {t}", .{
        cmd.input_path,
        err,
    });

    var meta: ziggy.Deserializer.Meta = .init;
    var diagrams = ziggy.deserializeLeaky(ziggy.Dictionary(railroad.Diagram), arena, src, &meta, .{}) catch |err| {
        if (err == error.OutOfMemory) @panic("oom");
        std.process.fatal("{f}", .{
            meta.reportErrorsFmt(arena, .{}, cmd.input_path, src, err),
        });
    };

    const out_dir = Io.Dir.cwd().createDirPathOpen(
        io,
        cmd.output_dir_path,
        .{},
    ) catch |err| fatalErr(
        "unable to create and open directory path '{s}': {t}",
        .{ cmd.output_dir_path, err },
    );

    for (diagrams.fields.keys(), diagrams.fields.values()) |k, *d| {
        d.layout() catch @panic("TODO: report validation errors");
        var name_buf: [std.fs.max_name_bytes]u8 = undefined;
        const file_name = std.fmt.bufPrint(
            &name_buf,
            "{s}.svg",
            .{std.fs.path.basename(k)},
        ) catch fatalErr("diagram name too long: '{s}'", .{k});
        const file = out_dir.createFile(io, file_name, .{ .truncate = true }) catch |err| {
            fatalErr("unable to create file '{s}': {t}", .{ file_name, err });
        };

        var file_writer_buf: [4096]u8 = undefined;
        var file_writer = file.writer(io, &file_writer_buf);

        const w = &file_writer.interface;
        w.print("{f}", .{d.fmt(css)}) catch |err| fatalIo(file_name, err);
        w.flush() catch |err| fatalIo(file_name, err);
    }

    // try w.print(
    //     \\
    //     \\<html>
    //     \\<head>
    //     \\<style>
    //     \\{s}
    //     \\</style>
    //     \\</head>
    //     \\<body>
    // , .{css});

    // for (diagrams.fields.keys(), diagrams.fields.values()) |k, *d| {
    //     try d.layout();
    //     try w.print("<h2>{s}</h2>\n{f}\n", .{ k, d });
    // }

    // try w.print(
    //     \\</body>
    //     \\</html>
    //     \\
    //     \\
    // , .{});
}

fn live(io: Io, args: []const []const u8) void {
    _ = io;
    _ = args;
}
fn install_schema(io: Io, args: []const []const u8) void {
    _ = io;
    _ = args;
}

const css =
    \\<style>
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
    \\</style>
    \\
;

fn fatalHelp() noreturn {
    std.process.fatal(
        \\Usage: railroad [COMMAND] [OPTIONS]
        \\
        \\Commands:
        \\  live              Start the development web server.
        \\  build             Output SVG files.
        \\  help, --help, -h  Show this menu and exit.
    , .{});
}

fn fatalErr(comptime fmt: []const u8, args: anytype) noreturn {
    std.process.fatal("error: " ++ fmt ++ "\n", args);
}

fn fatalIo(file_name: []const u8, err: anyerror) noreturn {
    fatalErr("i/o error for '{s}': {t}", .{ file_name, err });
}
