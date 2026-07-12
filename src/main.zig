const std = @import("std");
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ziggy = @import("ziggy");
const railroad = @import("railroad");
const html = @import("html.zig");
const fatal = @import("fatal.zig");

const default_style = @embedFile("default.css");
const schema = @embedFile(".ziggy-schema");

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: railroad [COMMAND] [OPTIONS]
        \\
        \\Render railroad diagrams defined in a Ziggy Document.
        \\
        \\Run `railroad install-schema` to see the Ziggy Schema
        \\for railroad definitions, go to https://ziggy-lang.io
        \\for more information about Ziggy.
        \\
        \\Commands:
        \\  live            Start the live-reloading web server
        \\  build           Output diagrams as HTML or SVG files
        \\  install-schema  Install the railroad Ziggy Schema
        \\  show-css        Display the default CSS stylesheet
        \\  help            Show this menu and exit
        \\
        \\General options:
        \\  --help, -h      Print command specific usage and extra options
        \\
    , .{});
    std.process.exit(1);
}

const Command = enum {
    live,
    build,
    @"install-schema",
    @"show-css",
    help,
    @"-h",
    @"--help",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("error: missing command\n", .{});
        fatalHelp();
    }

    const command = std.meta.stringToEnum(Command, args[1]) orelse fatalHelp();
    _ = switch (command) {
        .build => build(io, arena, args[2..]),
        .live => @import("main/live.zig").run(io, init.gpa, args[2..]),
        .@"install-schema" => install_schema(io, args[2..]),
        .@"show-css" => show_css(io, args[2..]),
        .help, .@"--help", .@"-h" => fatalHelp(),
    } catch fatal.oom();
}

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

    const css_src = if (cmd.css) |css_path| Io.Dir.cwd().readFileAlloc(
        io,
        css_path,
        arena,
        .unlimited,
    ) catch |err| fatalErr(
        "unable to read '{s}': {t}",
        .{ css_path, err },
    ) else default_style;

    var meta: ziggy.Deserializer.Meta = .init;
    var diagrams = ziggy.deserializeLeaky(ziggy.Dictionary(railroad.Diagram), arena, src, &meta, .{}) catch |err| {
        if (err == error.OutOfMemory) @panic("oom");
        std.process.fatal("{f}", .{
            meta.reportErrorsFmt(arena, .{}, cmd.input_path, src, err),
        });
    };
    for (diagrams.fields.values()) |*d| d.layout() catch @panic("TODO: handle layout");

    const out_dir = Io.Dir.cwd().createDirPathOpen(
        io,
        cmd.output_dir_path,
        .{},
    ) catch |err| fatalErr(
        "unable to create and open directory path '{s}': {t}",
        .{ cmd.output_dir_path, err },
    );

    var file_writer_buf: [4096]u8 = undefined;
    switch (cmd.mode) {
        .svg => {
            for (diagrams.fields.keys(), diagrams.fields.values()) |k, *d| {
                var name_buf: [std.fs.max_name_bytes]u8 = undefined;
                const file_name = std.fmt.bufPrint(
                    &name_buf,
                    "{s}.svg",
                    .{std.fs.path.basename(k)},
                ) catch fatalErr("diagram name too long: '{s}'", .{k});

                const file = out_dir.createFile(io, file_name, .{ .truncate = true }) catch |err| {
                    fatalErr("unable to create file '{s}': {t}", .{ file_name, err });
                };
                defer file.close(io);

                var file_writer = file.writer(io, &file_writer_buf);
                const w = &file_writer.interface;

                w.print("{f}", .{d.fmt(css_src)}) catch |err| fatalIo(file_name, err);
                w.flush() catch |err| fatalIo(file_name, err);
            }
        },
        .html => |name| {
            var name_buf: [std.fs.max_name_bytes]u8 = undefined;
            const html_name = if (endsWith(u8, name, ".html"))
                name
            else
                std.fmt.bufPrint(&name_buf, "{s}.html", .{name}) catch fatalErr(
                    "html file name too long: '{s}'",
                    .{name},
                );

            const file = out_dir.createFile(
                io,
                html_name,
                .{ .truncate = true },
            ) catch |err| fatalErr(
                "unable to create file '{s}': {t}",
                .{ html_name, err },
            );
            defer file.close(io);

            var file_writer = file.writer(io, &file_writer_buf);
            const w = &file_writer.interface;

            html.render(&diagrams, css_src, w) catch |err| fatalErr(
                "error writing to '{s}': {t}",
                .{ html_name, err },
            );
            w.flush() catch |err| fatalIo(html_name, err);
        },
    }
}

fn install_schema(io: Io, args: []const []const u8) void {
    const cmd: InstallSchemaCommand = .init(args);

    const dir = Io.Dir.cwd().createDirPathOpen(
        io,
        cmd.output_dir_path,
        .{},
    ) catch |err| fatalErr(
        "unable to ensure directory path '{s}': {t}",
        .{ cmd.output_dir_path, err },
    );

    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    const full_name = if (endsWith(u8, cmd.name, ".ziggy-schema"))
        cmd.name
    else
        std.fmt.bufPrint(&name_buf, "{s}.ziggy-schema", .{cmd.name}) catch fatalErr(
            "diagram name too long: '{s}'",
            .{cmd.name},
        );

    const file = dir.createFile(
        io,
        full_name,
        .{ .truncate = true },
    ) catch |err| fatalIo(full_name, err);
    defer file.close(io);

    file.writePositionalAll(io, schema, 0) catch |err| fatalIo(full_name, err);
}

fn show_css(io: Io, args: []const []const u8) void {
    if (args.len > 0) {
        if (!eql(u8, args[0], "--help") and !eql(u8, args[0], "-h")) {
            std.debug.print("error: unknown arguments\n\n", .{});
        }
        const help =
            \\Usage: railroad show-css
            \\
            \\Displays the default CSS style.
            \\
            \\
        ;
        std.debug.print("{s}", .{help});
        std.process.exit(1);
    }

    Io.File.stdout().writeStreamingAll(
        io,
        default_style,
    ) catch |err| fatalIo("stdout", err);
}

fn fatalErr(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn fatalIo(file_name: []const u8, err: anyerror) noreturn {
    fatalErr("i/o error for '{s}': {t}", .{ file_name, err });
}

const BuildCommand = struct {
    input_path: []const u8,
    output_dir_path: []const u8,
    css: ?[]const u8,
    mode: Mode,

    const Mode = union(enum) { svg, html: []const u8 };
    const help =
        \\Usage: railroad build INPUT_ZIGGY_FILE [OPTIONS]
        \\
        \\Build SVG files from a Ziggy Document containing diagram
        \\definitions.
        \\
        \\Command specific options:
        \\  --output, -o DIR  Directory where to put the generated SVG
        \\                    files, defaults to 'diagrams/'.
        \\  --html[=NAME]     Output a single HTML file containing all
        \\                    diagrams as inlined SVG. NAME defaults
        \\                    to 'diagrams.html'.
        \\  --css PATH        Override the default CSS style. Run
        \\                    `railroad show-css` to see the default
        \\                    CSS style.
    ;

    fn init(args: []const []const u8) BuildCommand {
        var input_path: ?[]const u8 = null;
        var output_dir_path: ?[]const u8 = null;
        var css: ?[]const u8 = null;
        var mode: Mode = .svg;

        var i: usize = 0;

        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (startsWith(u8, arg, "--output=")) {
                if (input_path != null) fatalErr("more than one '--output' argument", .{});
                const val = arg["--output=".len..];
                if (val.len == 0) fatalErr("missing '--output' value", .{});
                output_dir_path = val;
            } else if (eql(u8, arg, "--output")) {
                if (input_path != null) fatalErr("more than one '--output' argument", .{});
                i += 1;
                if (i == args.len) fatalErr("missing '--output' value", .{});
                output_dir_path = args[i];
                // ---
            } else if (startsWith(u8, arg, "--css=")) {
                if (css != null) fatalErr("more than one '--css' argument", .{});
                const val = arg["--css=".len..];
                if (val.len == 0) fatalErr("missing '--css' value", .{});
                css = val;
            } else if (eql(u8, arg, "--css")) {
                if (css != null) fatalErr("more than one '--css' argument", .{});
                i += 1;
                if (i == args.len) fatalErr("missing '--css' value", .{});
                css = args[i];
                // ---
            } else if (startsWith(u8, arg, "--html=")) {
                if (mode == .html) fatalErr("more than one '--html' argument", .{});
                const val = arg["--html=".len..];
                if (val.len == 0) fatalErr("missing '--html' value", .{});
                mode = .{ .html = val };
            } else if (eql(u8, arg, "--html")) {
                if (mode == .html) fatalErr("more than one '--html' argument", .{});
                mode = .{ .html = "diagrams.html" };
                // ---
            } else if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) {
                std.process.fatal(help, .{});
            } else {
                if (input_path != null) fatalErr("more than one input file argument", .{});
                input_path = arg;
            }
        }

        return .{
            .mode = mode,
            .input_path = input_path orelse fatalErr("missing input file argument", .{}),
            .output_dir_path = output_dir_path orelse "diagrams",
            .css = css,
        };
    }
};

const LiveCommmand = struct {
    input_path: []const u8,
    css: ?[]const u8,
    browser: bool,
    host: []const u8,
    port: u16,

    const help =
        \\Usage: railroad live INPUT_ZIGGY_FILE [OPTIONS]
        \\
        \\Start a live server that displays the diagrams and listens to
        \\changes in input files.
        \\
        \\Any edit you make to the input Ziggy Document file (or the input
        \\CSS file if defined), will be reloaded instantly by the server
        \\on save.
        \\
        \\Command specific options:
        \\  --host HOST        Listening host (default 'localhost')
        \\  --port PORT        Listening port (default 1990)
        \\  --css PATH         Override the default CSS style. Run
        \\                     `railroad show-css` to see the default
        \\                     CSS style.
        \\  --no-browser       Disable automatic opening of a browser.
    ;

    fn init(args: []const []const u8) LiveCommmand {
        var input_path: ?[]const u8 = null;
        var css: ?[]const u8 = null;
        var browser = true;
        var host: ?[]const u8 = null;
        var port: ?u16 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.startsWith(u8, arg, "--host=")) {
                const suffix = arg["--host=".len..];
                host, const maybe_port = parseAddress(suffix);
                if (maybe_port) |p| port = p;
            } else if (std.mem.eql(u8, arg, "--host")) {
                i += 1;
                if (i >= args.len) fatalErr(
                    "error: missing argument to '--host'",
                    .{},
                );
                host, const maybe_port = parseAddress(args[i]);
                if (maybe_port) |p| port = p;
                // ---
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                const suffix = arg["--port=".len..];
                port = std.fmt.parseInt(u16, suffix, 10) catch |err| fatalErr(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "--port")) {
                i += 1;
                if (i >= args.len) fatalErr(
                    "error: missing argument to '--port'",
                    .{},
                );
                port = std.fmt.parseInt(u16, args[i], 10) catch |err| fatalErr(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
                // ---
            } else if (startsWith(u8, arg, "--css=")) {
                if (css != null) fatalErr("more than one '--css' argument", .{});
                const val = arg["--css=".len..];
                if (val.len == 0) fatalErr("missing '--css' value", .{});
                css = val;
            } else if (eql(u8, arg, "--css")) {
                if (css != null) fatalErr("more than one '--css' argument", .{});
                i += 1;
                if (i == args.len) fatalErr("missing '--css' value", .{});
                css = args[i];
                // ---
            } else if (eql(u8, arg, "--no-browser")) {
                if (!browser) fatalErr("more than one '--no-browser' argument", .{});
                browser = false;
                // ---
            } else if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) {
                std.process.fatal(help, .{});
            } else {
                if (input_path != null) fatalErr("more than one input file argument", .{});
                input_path = arg;
            }
        }

        return .{
            .input_path = input_path orelse fatalErr("missing input file argument", .{}),
            .css = css,
            .browser = browser,
            .host = host orelse "localhost",
            .port = port orelse 1990,
        };
    }

    fn parseAddress(arg: []const u8) struct { []const u8, ?u16 } {
        if (arg.len <= 0) {
            fatalErr(
                "error: missing argument to '--host='",
                .{},
            );
        }

        const host = if (arg[0] == '[') ipv6: {
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                if (arg[i] == ']') {
                    break :ipv6 arg[0 .. i + 1];
                }
            }
            fatalErr(
                "error: unmatched '[' in '--host='",
                .{},
            );
        } else arg[0 .. std.mem.indexOfScalar(u8, arg, ':') orelse arg.len];

        var port: ?u16 = null;
        const maybe_port = arg[host.len..];
        if (maybe_port.len > 0 and maybe_port[0] == ':') {
            port = std.fmt.parseInt(u16, maybe_port[1..], 10) catch |err| fatalErr(
                \\error: bad port in '{s}': {s}
                \\hint: if you meant to use IPv6, wrap it in square brackets, e.g. --host=[::1]
                \\
            ,
                .{ arg, @errorName(err) },
            );
        }

        return .{ host, port };
    }
};

const InstallSchemaCommand = struct {
    output_dir_path: []const u8,
    name: []const u8,

    const Mode = union(enum) { svg, html: ?[]const u8 };
    const help =
        \\Usage: railroad install-schema DIR [OPTIONS]
        \\
        \\Writes a copy of the Railroad Ziggy Schema into DIR.
        \\Overwrites any pre-existing file.
        \\
        \\The file will be named '.ziggy-schema' in order to be
        \\automatically picked up by the Ziggy Language Server for all
        \\Ziggy Documents in the directory subtree.
        \\
        \\The schema provides railroad-specific diagnostics, autocomplete
        \\and go to definition for your editor.
        \\
        \\Visit https://ziggy-lang.io for more info on Ziggy.
        \\
        \\Command specific options:
        \\  --name NAME    Override the default file name
        \\
    ;

    fn init(args: []const []const u8) InstallSchemaCommand {
        var output_dir_path: ?[]const u8 = null;
        var name: ?[]const u8 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (startsWith(u8, arg, "--name=")) {
                if (name != null) fatalErr("more than one '--name' argument", .{});
                const val = arg["--name=".len..];
                if (val.len == 0) fatalErr("missing '--name' value", .{});
                name = val;
            } else if (eql(u8, arg, "--name")) {
                if (name != null) fatalErr("more than one '--name' argument", .{});
                i += 1;
                if (i == args.len) fatalErr("missing '--name' value", .{});
                name = args[i];
                // ---
            } else if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) {
                std.process.fatal(help, .{});
            } else {
                if (output_dir_path != null) fatalErr("more than one input file argument", .{});
                output_dir_path = arg;
            }
        }

        return .{
            .name = name orelse ".ziggy-schema",
            .output_dir_path = output_dir_path orelse fatalErr(
                "missing output dir argument",
                .{},
            ),
        };
    }
};
