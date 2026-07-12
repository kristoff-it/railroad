const std = @import("std");
const assert = std.debug.assert;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const WebSocket = std.http.Server.WebSocket;
const nightwatch = @import("nightwatch");
const ziggy = @import("ziggy");
const railroad = @import("railroad");
const fatal = @import("../fatal.zig");
const html = @import("../html.zig");

const default_style = @embedFile("../default.css");
const schema = @embedFile(".ziggy-schema");
const ziggy_ziggy = @embedFile("ziggy.ziggy");

const help =
    \\Usage: railroad live INPUT_ZIGGY_FILE [OPTIONS]
    \\
    \\Start a live webserver that displays the diagrams and listens to
    \\changes in input files.
    \\
    \\Any edit you make to the input Ziggy Document file (or the input
    \\CSS file if defined), will be reloaded instantly by the server
    \\on save.
    \\
    \\Command specific options:
    \\  --host HOST[:PORT] Listening host (default 'localhost')
    \\  --port PORT        Listening port (default 1990)
    \\  --css PATH         Override the default CSS style. Run
    \\                     `railroad show-css` to see the default
    \\                     CSS style.
    \\  --no-browser       Disable automatic opening of a browser.
;

pub const Event = union(enum) {
    changed_css: [:0]const u8,
    changed_input: [:0]const u8,
    connect: WebSocket,
    disconnect: struct {
        conn: WebSocket,
        cleanup_signal: *Io.Queue(u32),
    },
};

pub fn run(io: Io, gpa: Allocator, args: []const []const u8) error{OutOfMemory}!void {
    const cmd: Command = .init(args);

    var channel_buf: [64]Event = undefined;
    var channel: Io.Queue(Event) = .init(&channel_buf);

    const url = try std.fmt.allocPrint(
        gpa,
        "http://{s}:{}/",
        .{ cmd.host.bytes, cmd.port },
    );
    defer gpa.free(url);

    var h: WatchHandler = .{ .io = io, .gpa = gpa, .channel = &channel };
    var watcher = nightwatch.Default.init(io, gpa, &h.handler) catch |err| {
        fatal.msg("unable to start file watcher: {t}", .{err});
    };
    defer watcher.deinit();

    const input_src = readOrInitFile(io, gpa, cmd.input_path, ziggy_ziggy);
    watcher.watch(cmd.input_path) catch |err| fatal.msg(
        "unable to watch '{s}': {t}",
        .{ cmd.input_path, err },
    );

    const css_src = if (cmd.css_path) |path| blk: {
        const src = readOrInitFile(io, gpa, path, default_style);
        watcher.watch(path) catch |err| fatal.msg(
            "unable to watch '{s}': {t}",
            .{ cmd.input_path, err },
        );
        break :blk src;
    } else default_style;

    var build_lock: Io.RwLock = .init;
    var build: Build = undefined;
    build.init(gpa, input_src, css_src);

    var server: Server = .initAndListen(
        io,
        gpa,
        &channel,
        &build,
        &build_lock,
        cmd.host,
        cmd.port,
    );

    var select_buf: [2]Task = undefined;
    var select = Io.Select(Task).init(io, &select_buf);
    defer select.cancelDiscard();

    select.concurrent(.server, Server.serve, .{&server}) catch |err| fatal.msg(
        "unable to spawn live server: {t}",
        .{err},
    );
    select.concurrent(.broadcast, broadcastWebsockets, .{
        io,
        gpa,
        &channel,
        &build,
        &build_lock,
    }) catch |err| fatal.msg(
        "unable to spawn live server broadcaster: {t}",
        .{err},
    );

    std.debug.print("listening at {s}\n", .{url});

    // Any task returning means we should exit.
    _ = select.await() catch {};
    std.process.cleanExit(io);
}

const Task = union(enum) {
    server,
    broadcast,
};

fn broadcastWebsockets(
    io: Io,
    gpa: Allocator,
    channel: *Io.Queue(Event),
    build: *Build,
    build_lock: *Io.RwLock,
) void {
    var websockets: std.AutoArrayHashMapUnmanaged(
        [*]const u8,
        WebSocket,
    ) = .empty;

    while (true) {
        const event = channel.getOne(io) catch break;
        std.log.debug("new event: {s}", .{@tagName(event)});

        switch (event) {
            .changed_input => |src| {
                build_lock.lock(io) catch break;
                {
                    defer build_lock.unlock(io);
                    build.rebuildDiagrams(gpa, src);
                }

                for (websockets.values()) |*conn| {
                    conn.writeMessage("RELOAD\n", .text) catch |err| {
                        std.log.debug(
                            "error writing to ws: {s}",
                            .{@errorName(err)},
                        );
                    };
                }
            },
            .changed_css => |src| {
                build_lock.lock(io) catch break;
                {
                    defer build_lock.unlock(io);
                    build.swapCss(gpa, src);
                }

                for (websockets.entries.items(.value)) |*conn| {
                    var msg: [2][]const u8 = .{ "CSS\n", src };
                    conn.writeMessageVec(&msg, .text) catch |err| {
                        std.log.debug(
                            "error writing to ws: {s}",
                            .{@errorName(err)},
                        );
                    };
                }
            },
            .connect => |ws| {
                var conn = ws;
                _ = &conn;
                websockets.put(gpa, conn.key.ptr, conn) catch fatal.oom();
                // We don't lock the build because this thread is the only writer

                // for (build.mode.memory.errors.items) |build_err| {
                //     var aw: Writer.Allocating = .init(gpa);
                //     defer aw.deinit();

                //     aw.writer.print("{f}", .{
                //         std.json.fmt(.{
                //             .command = "build",
                //             .err = build_err.msg,
                //         }, .{}),
                //     }) catch return error.OutOfMemory;

                //     conn.writeMessage(aw.written(), .text) catch |err| {
                //         log.debug(
                //             "error writing to ws: {s}",
                //             .{@errorName(err)},
                //         );
                //     };
                // }
            },
            .disconnect => |disconnect| {
                // the server thread will take care of closing the connection
                // as the corresponding thread shuts down
                _ = websockets.swapRemove(disconnect.conn.key.ptr);
                disconnect.cleanup_signal.close(io);
            },
        }
    }
}

const Server = struct {
    io: Io,
    gpa: Allocator,
    build: *Build,
    build_lock: *Io.RwLock,
    channel: *Io.Queue(Event),
    tcp: Io.net.Server,

    fn initAndListen(
        io: Io,
        gpa: Allocator,
        channel: *Io.Queue(Event),
        build: *Build,
        build_lock: *Io.RwLock,
        host: Io.net.HostName,
        port: u16,
    ) Server {
        var addresses_buffer: [16]Io.net.HostName.LookupResult = undefined;
        var canon_name_buffer: [Io.net.HostName.max_len]u8 = undefined;
        var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&addresses_buffer);
        Io.net.HostName.lookup(host, io, &queue, .{
            .port = port,
            .canonical_name_buffer = &canon_name_buffer,
        }) catch |err| fatal.msg(
            "unable to resolve host '{s}': {t}",
            .{ host.bytes, err },
        );

        const address = addresses_buffer[0].address;

        return .{
            .io = io,
            .gpa = gpa,
            .channel = channel,
            .build = build,
            .build_lock = build_lock,
            .tcp = address.listen(io, .{ .reuse_address = true }) catch |err| fatal.msg(
                "error: unable to bind to '{any}': {s}",
                .{ address, @errorName(err) },
            ),
        };
    }

    fn serve(s: *Server) void {
        var clients: Io.Group = .init;
        while (true) {
            const stream = s.tcp.accept(s.io) catch |err| switch (err) {
                error.SystemResources,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.Unexpected,
                error.SocketNotListening,
                error.ProtocolFailure,
                error.BlockedByFirewall,
                error.WouldBlock,
                error.Canceled,
                => fatal.msg(
                    "error: critical failure while opening new live server tcp connection: {s}",
                    .{@errorName(err)},
                ),
                error.ConnectionAborted,
                error.NetworkDown,
                => {
                    std.log.debug("non-fatal tcp error: {s}", .{@errorName(err)});
                    continue;
                },
            };

            clients.concurrent(
                s.io,
                Server.handleConnection,
                .{ s, stream },
            ) catch |err| fatal.msg(
                "error: unable to spawn client connection task: {s}",
                .{@errorName(err)},
            );
        }
    }

    fn handleConnection(s: *Server, stream: Io.net.Stream) void {
        defer stream.close(s.io);

        var bufin: [4096 * 4]u8 = undefined;
        var in = stream.reader(s.io, &bufin);
        var bufout: [4096]u8 = undefined;
        var out = stream.writer(s.io, &bufout);
        var http_server = std.http.Server.init(&in.interface, &out.interface);

        while (true) {
            var request = http_server.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing) {
                    std.log.debug("connection error: {s}\n", .{@errorName(err)});
                }
                return;
            };

            std.log.debug("request: {s}", .{request.head.target});
            s.handleRequest(&request) catch |err| {
                if (err != error.Websocket) {
                    std.log.debug("failed request: {s}", .{@errorName(err)});
                }
                return;
            };
        }
    }

    fn handleRequest(s: *Server, req: *std.http.Server.Request) !void {
        const path = req.head.target;

        if (eql(u8, path, "/")) {
            // serve page
            try s.build_lock.lockShared(s.io);
            defer s.build_lock.unlockShared(s.io);

            var buf: [4096]u8 = undefined;
            var body_writer = try req.respondStreaming(&buf, .{
                .respond_options = .{
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/html" },
                    },
                },
            });

            try s.build.render(&body_writer.writer);
            try body_writer.end();
        } else if (eql(u8, path, "/ws")) {
            // handle websocket
            s.handleWebsocket(req);
            return error.Websocket;
        } else {
            // invalid path, redirect home
            try req.respond("404", .{
                .status = .see_other,
                .extra_headers = &.{.{ .name = "location", .value = "/" }},
            });
        }
    }

    fn handleWebsocket(s: *Server, req: *std.http.Server.Request) void {
        const up = req.upgradeRequested();
        const wsup = switch (up) {
            .none, .other => return req.respond("error: must request websocket upgrade", .{
                .status = .bad_request,
            }) catch {},

            .websocket => |wsup| wsup orelse "<no key provided>",
        };

        var ws = req.respondWebSocket(.{ .key = wsup }) catch return;
        ws.flush() catch return;

        s.channel.putOne(s.io, .{ .connect = ws }) catch return;

        var cleanup_silly_buf: [1]u32 = undefined;
        var cleanup_signal: Io.Queue(u32) = .init(&cleanup_silly_buf);
        while (true) {
            _ = ws.readSmallMessage() catch |err| {
                std.log.debug("readWs error: {s}", .{@errorName(err)});
                s.channel.putOne(s.io, .{
                    .disconnect = .{
                        .conn = ws,
                        .cleanup_signal = &cleanup_signal,
                    },
                }) catch return;
                _ = cleanup_signal.getOne(s.io) catch return;
            };
        }
    }
};

const Build = struct {
    css_src: []const u8,
    input_src: [:0]const u8,
    meta: ziggy.Deserializer.Meta,
    diagrams: ziggy.Deserializer.Error!ziggy.Deserializer.Value(
        ziggy.Dictionary(railroad.Diagram),
    ),

    fn init(b: *Build, gpa: Allocator, input_src: [:0]const u8, css_src: []const u8) void {
        b.css_src = css_src;
        b.input_src = input_src;
        b.meta = .init;
        b.diagrams = ziggy.deserialize(
            ziggy.Dictionary(railroad.Diagram),
            gpa,
            input_src,
            &b.meta,
            .{},
        );

        if (b.diagrams) |*ds| {
            for (ds.value.fields.values()) |*d| d.layout() catch @panic("TODO: handle layout");
        } else |_| {}
    }

    fn swapCss(b: *Build, gpa: Allocator, src: [:0]const u8) void {
        if (b.css_src.ptr != default_style) {
            gpa.free(b.css_src);
        }
        b.css_src = src;
    }

    fn rebuildDiagrams(b: *Build, gpa: Allocator, src: [:0]const u8) void {
        if (b.input_src.ptr != ziggy_ziggy) {
            gpa.free(b.input_src);
        }

        if (b.diagrams) |d| d.deinit() else |_| {}

        b.input_src = src;
        b.meta = .init;
        b.diagrams = ziggy.deserialize(
            ziggy.Dictionary(railroad.Diagram),
            gpa,
            src,
            &b.meta,
            .{},
        );

        if (b.diagrams) |*ds| {
            for (ds.value.fields.values()) |*d| d.layout() catch @panic("TODO: handle layout");
        } else |_| {}
    }

    fn render(b: *Build, w: *Io.Writer) !void {
        if (b.diagrams) |*ds| try html.render(&ds.value, b.css_src, true, w) else |err| {
            // error
            std.debug.panic("TODO: handle diagram errors {t}", .{err});
        }
    }
};

fn readFile(io: Io, gpa: Allocator, path: []const u8) [:0]const u8 {
    return Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(ziggy.max_size),
        .of(u8),
        0,
    ) catch |err| fatal.fileRead(path, err);
}

fn readOrInitFile(io: Io, gpa: Allocator, path: []const u8, default: [:0]const u8) [:0]const u8 {
    return Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(ziggy.max_size),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print(
                "File '{s}' does not exist, initializing with sample content.\n",
                .{path},
            );

            const file = Io.Dir.cwd().createFile(
                io,
                path,
                .{ .truncate = true },
            ) catch |create_err| fatal.fileCreate(path, create_err);
            defer file.close(io);

            file.writePositionalAll(io, default, 0) catch |write_err|
                fatal.fileWrite(path, write_err);

            return default;
        },
        else => fatal.fileRead(path, err),
    };
}

const WatchHandler = struct {
    io: Io,
    gpa: Allocator,
    channel: *Io.Queue(Event),
    handler: nightwatch.Default.Handler = .{
        .vtable = &.{
            .change = change,
            .rename = rename,
        },
    },

    fn change(h: *nightwatch.Default.Handler, path: []const u8, event: nightwatch.EventType, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.log.debug("{s}  {s}\n", .{ @tagName(event), path });

        const self: *WatchHandler = @fieldParentPtr("handler", h);

        switch (event) {
            .closed => {},
            .deleted => fatal.msg("file '{s}' deleted, exiting", .{
                std.fs.path.basename(path),
            }),
            .created, .modified => {
                const src = readFile(self.io, self.gpa, path);
                if (std.mem.endsWith(u8, path, ".ziggy")) {
                    self.channel.putOneUncancelable(self.io, .{ .changed_input = src }) catch {};
                } else {
                    assert(std.mem.endsWith(u8, path, ".css"));
                    self.channel.putOneUncancelable(self.io, .{ .changed_css = src }) catch {};
                }
            },
        }
    }

    fn rename(_: *nightwatch.Default.Handler, src: []const u8, dst: []const u8, _: nightwatch.ObjectType) error{HandlerFailed}!void {
        std.debug.print("rename  {s}  ->  {s}\n", .{ src, dst });
    }
};

const Command = struct {
    input_path: []const u8,
    css_path: ?[]const u8,
    browser: bool,
    host: Io.net.HostName,
    port: u16,

    fn init(args: []const []const u8) Command {
        var input_path: ?[]const u8 = null;
        var css_path: ?[]const u8 = null;
        var browser = true;
        var maybe_host: ?[]const u8 = null;
        var port: ?u16 = null;

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.startsWith(u8, arg, "--host=")) {
                const suffix = arg["--host=".len..];
                maybe_host, const maybe_port = parseAddress(suffix);
                if (maybe_port) |p| port = p;
            } else if (std.mem.eql(u8, arg, "--host")) {
                i += 1;
                if (i >= args.len) fatal.msg(
                    "error: missing argument to '--host'",
                    .{},
                );
                maybe_host, const maybe_port = parseAddress(args[i]);
                if (maybe_port) |p| port = p;
                // ---
            } else if (std.mem.startsWith(u8, arg, "--port=")) {
                const suffix = arg["--port=".len..];
                port = std.fmt.parseInt(u16, suffix, 10) catch |err| fatal.msg(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
            } else if (std.mem.eql(u8, arg, "--port")) {
                i += 1;
                if (i >= args.len) fatal.msg(
                    "error: missing argument to '--port'",
                    .{},
                );
                port = std.fmt.parseInt(u16, args[i], 10) catch |err| fatal.msg(
                    "error: bad port value '{s}': {s}",
                    .{ arg, @errorName(err) },
                );
                // ---
            } else if (startsWith(u8, arg, "--css=")) {
                if (css_path != null) fatal.msg("more than one '--css' argument", .{});
                const val = arg["--css=".len..];
                if (val.len == 0) fatal.msg("missing '--css' value", .{});
                css_path = val;
            } else if (eql(u8, arg, "--css")) {
                if (css_path != null) fatal.msg("more than one '--css' argument", .{});
                i += 1;
                if (i == args.len) fatal.msg("missing '--css' value", .{});
                css_path = args[i];
                // ---
            } else if (eql(u8, arg, "--no-browser")) {
                if (!browser) fatal.msg("more than one '--no-browser' argument", .{});
                browser = false;
                // ---
            } else if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) {
                std.process.fatal(help, .{});
            } else {
                if (input_path != null) fatal.msg("more than one input file argument", .{});
                input_path = arg;
            }
        }

        const host = maybe_host orelse "localhost";
        return .{
            .input_path = input_path orelse fatal.msg("missing input file argument", .{}),
            .css_path = css_path,
            .browser = browser,
            .port = port orelse 1991,
            .host = Io.net.HostName.init(host) catch |err| fatal.msg(
                "invalid host '{s}': {t}",
                .{ host, err },
            ),
        };
    }

    fn parseAddress(arg: []const u8) struct { []const u8, ?u16 } {
        if (arg.len <= 0) {
            fatal.msg(
                "error: missing argument to '--host='",
                .{},
            );
        }

        const host = if (arg[0] == '[') ipv6: {
            var i: usize = 1;
            while (i < arg.len) : (i += 1) {
                if (arg[i] == ']') {
                    break :ipv6 arg[1..i];
                }
            }
            fatal.msg(
                "error: unmatched '[' in '--host='",
                .{},
            );
        } else arg[0 .. std.mem.indexOfScalar(u8, arg, ':') orelse arg.len];

        var port: ?u16 = null;
        const maybe_port = arg[host.len..];
        if (maybe_port.len > 0 and maybe_port[0] == ':') {
            port = std.fmt.parseInt(u16, maybe_port[1..], 10) catch |err| fatal.msg(
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
