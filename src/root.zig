const std = @import("std");
const Io = std.Io;
const ziggy = @import("ziggy");
const Tokenizer = ziggy.Tokenizer;
const Deserializer = ziggy.Deserializer;

// VS: 8, // minimum vertical separation between things. For a 3px stroke, must be at least 4
// AR: 10, // radius of arcs
const vs: f64 = 8;
const ar: f64 = 10;
const padding: f64 = 20;

pub const Diagram = struct {
    body: []Node,

    up: f64 = 0,
    down: f64 = 0,
    height: f64 = 0,
    width: f64 = 0,

    pub const ziggy_options: ziggy.Options(Diagram) = .{
        .skip_fields = &.{ .up, .down, .height, .width },
    };

    pub fn layout(d: *Diagram) void {
        d.width = padding;
        d.up = 10;
        d.down = 10;
        for (d.body) |*n| {
            n.layout();
            d.width += n.width;
            if (n.needs_space) d.width += padding;
            d.up = @max(d.up, n.up - d.height);
            d.height += n.height;
            d.down = @max(d.down - n.height, n.down);
        }

        d.width += padding;
    }

    pub fn format(d: *const Diagram, w: *Io.Writer) Io.Writer.Error!void {
        // self.width + paddingLeft + paddingRight
        const view_box_w = d.width + padding + padding;
        //self.up + self.height + self.down + paddingTop + paddingBottom
        const view_box_h = d.up + d.height + d.down + padding + padding;

        const stroke_odd_pixel_length = true;
        const transform = if (stroke_odd_pixel_length) "translate(.5 .5)" else "";

        try w.print(
            \\<svg class="railroad-diagram" width={0} height={1} viewBox="0 0 {0} {1}">
            \\<g transform="{2s}">
            \\
        , .{ view_box_w, view_box_h, transform });

        var x: f64 = padding;
        var y: f64 = padding;
        y += d.up;
        {
            try w.writeAll("<g>\n");
            try writePath(w, x, y - 10, &.{
                .{ .down = 20 },
                .{ .m = .{ .x = 10, .y = -20 } },
                .{ .down = 20 },
                .{ .m = .{ .x = -10, .y = -10 } },
                .{ .right = padding },
            });
            try w.writeAll("</g>\n");
            x += padding;
        }

        for (d.body) |n| {
            if (n.needs_space) {
                try writePath(w, x, y, &.{
                    .{ .h = 10 },
                });
                x += 10;
            }
            try n.renderSvg(w, x, y, n.width);
            x += n.width;
            y += n.height;

            if (n.needs_space) {
                try writePath(w, x, y, &.{
                    .{ .h = 10 },
                });
                x += 10;
            }
        }
        try w.print(
            \\<path d="M{} {} h 20 m -10 -10 v 20 m 10 -20 v 20'" />
            \\
        , .{ x, y });

        try w.writeAll("</g></svg>\n\n");
    }

    pub const Node = struct {
        raw: RawNode,

        up: f64 = 0,
        down: f64 = 0,
        width: f64 = 0,
        height: f64 = 0,
        needs_space: bool = false,

        fn layout(n: *Node) void {
            const term_char_width = 8;
            const comment_char_width = 7;
            switch (n.raw) {
                .terminal, .non_terminal => |t| {
                    const flen: f64 = @floatFromInt(t.len);
                    n.width = (flen * term_char_width) + padding;
                    n.up = 11;
                    n.down = 11;
                    n.needs_space = true;
                },
                .comment => |c| {
                    const flen: f64 = @floatFromInt(c.len);
                    n.width = (flen * comment_char_width) + padding;
                    n.up = 8;
                    n.down = 8;
                    n.needs_space = true;
                },
                .skip => {},
                .stack => |items| {
                    for (items, 0..) |*item, idx| {
                        item.layout();
                        n.width = @max(n.width, item.width + if (item.needs_space) padding else 0);
                        n.height += item.height;
                        if (idx > 0) {
                            n.height += @max(ar * 2, item.up + vs);
                        }
                        if (idx < items.len - 1) {
                            n.height += @max(ar * 2, item.down + vs);
                        }
                    }

                    n.needs_space = true;
                    n.up = items[0].up;
                    n.down = items[items.len - 1].down;
                },
            }
        }

        fn renderSvg(n: *const Node, w: *Io.Writer, x: f64, y: f64, width: f64) Io.Writer.Error!void {
            switch (n.raw) {
                .terminal, .non_terminal => |text| {
                    try w.writeAll(
                        \\<g class="terminal">
                        \\
                    );
                    const gaps = determineGaps(width, n.width);
                    try writePath(w, x, y, &.{
                        .{ .h = gaps[0] },
                    });
                    try writePath(w, x + gaps[0] + n.width, y, &.{
                        .{ .h = gaps[1] },
                    });
                    try writeRect(
                        w,
                        x + gaps[0],
                        y - 11,
                        n.width,
                        n.up + n.down,
                        if (n.raw == .terminal) 10 else 0,
                        if (n.raw == .terminal) 10 else 0,
                    );

                    try writeText(w, x + gaps[0] + n.width / 2.0, y + 4, text, .{});
                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .comment => |text| {
                    try w.writeAll(
                        \\<g class="comment">
                        \\
                    );
                    const gaps = determineGaps(width, n.width);
                    try writePath(w, x, y, &.{
                        .{ .h = gaps[0] },
                    });
                    try writePath(w, x + gaps[0] + n.width, y + n.height, &.{
                        .{ .h = gaps[1] },
                    });
                    try writeText(w, x + n.width / 2.0, y + 5, text, .{
                        .class = "comment",
                    });
                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .skip => {
                    try writePath(w, x, y, &.{
                        .{ .right = n.width },
                    });
                },
                .stack => |items| {
                    try w.writeAll("<g>");
                    const gaps = determineGaps(width, n.width);
                    try writePath(w, x, y, &.{.{ .h = gaps[0] }});
                    var mut_x = x;
                    mut_x += gaps[0];
                    if (items.len > 1) {
                        try writePath(w, mut_x, y, &.{.{ .h = ar }});
                        mut_x += ar;
                    }

                    var mut_y = y;
                    for (items, 0..) |item, idx| {
                        const inner_width: f64 = n.width - if (items.len > 1) ar * 2 else 0.0;
                        try item.renderSvg(w, mut_x, mut_y, inner_width);
                        mut_x += inner_width;
                        mut_y += item.height;

                        if (idx < items.len - 1) {
                            try writePath(w, mut_x, mut_y, &.{
                                .{ .arc = .{ .n, .e } }, .{ .down = @max(0, item.down + vs - ar * 2) },
                                .{ .arc = .{ .e, .s } }, .{ .left = inner_width },
                                .{ .arc = .{ .n, .w } }, .{ .down = @max(0, items[idx + 1].up + vs - ar * 2) },
                                .{ .arc = .{ .w, .s } },
                            });

                            mut_y += @max(item.down + vs, ar * 2) + @max(items[idx + 1].up + vs, ar * 2);
                            mut_x = x + ar;
                        }
                    }

                    if (items.len > 1) {
                        try writePath(w, mut_x, mut_y, &.{.{ .h = ar }});
                    }

                    try w.writeAll("</g>");
                },
            }
        }

        fn determineGaps(outer: f64, inner: f64) [2]f64 {
            const diff = outer - inner;

            const internal_alignment = .center;
            switch (internal_alignment) {
                .left => return .{ 0, diff },
                .right => return .{ diff, 0 },
                .center => return .{ diff / 2.0, diff / 2.0 },
                else => unreachable,
            }
        }

        pub const ziggy_options: ziggy.Options(Node) = .{
            .deserialize = deserialize,
        };

        fn deserialize(
            d: *const Deserializer,
            first: Tokenizer.Token,
            top_lvl: bool,
        ) Deserializer.Error!Node {
            return .{
                .raw = try d.deserializeOne(RawNode, first, top_lvl),
            };
        }
    };
};

pub const RawNode = union(enum) {
    terminal: []const u8,
    non_terminal: []const u8,
    comment: []const u8,
    skip,
    stack: []Diagram.Node,
};

const PathCmd = union(enum) {
    h: f64,
    m: struct { x: f64, y: f64 },
    right: f64,
    left: f64,
    down: f64,
    up: f64,
    arc: [2]Sweep,

    pub const Sweep = enum { n, s, w, e };
};

fn eq(lhs: [2]PathCmd.Sweep, rhs: [2]PathCmd.Sweep) bool {
    return lhs[0] == rhs[0] and lhs[1] == rhs[1];
}

fn writePath(w: *Io.Writer, x: f64, y: f64, cmds: []const PathCmd) Io.Writer.Error!void {
    try w.print(
        \\<path d="M{} {}
    , .{ x, y });

    for (cmds) |cmd| switch (cmd) {
        .h => |h| try w.print(" h{}", .{h}),
        .m => |m| try w.print(" m{} {}", .{ m.x, m.y }),
        .right => |r| try w.print("h{}", .{@max(0, r)}),
        .left => |l| try w.print("h{}", .{-@max(0, l)}),
        .down => |d| try w.print("v{}", .{@max(0, d)}),
        .up => |u| try w.print("v{}", .{-@max(0, u)}),
        .arc => |sweep| {
            const arc_x: f64 = if (sweep[0] == .e or sweep[1] == .w) -ar else ar;
            const arc_y: f64 = if (sweep[0] == .s or sweep[1] == .n) -ar else ar;

            const cw: u8 = @intFromBool(
                eq(sweep, .{ .n, .e }) or
                    eq(sweep, .{ .e, .s }) or
                    eq(sweep, .{ .s, .w }) or
                    eq(sweep, .{ .w, .n }),
            );

            try w.print("a {} {} 0 0 {} {} {}", .{
                ar, ar, cw, arc_x, arc_y,
            });
        },
    };

    try w.writeAll(
        \\"/>
        \\
    );
}

fn writeText(
    w: *Io.Writer,
    x: f64,
    y: f64,
    text: []const u8,
    opts: struct {
        class: ?[]const u8 = null,
    },
) Io.Writer.Error!void {
    try w.print(
        \\<text x="{}" y="{}"
    , .{ x, y });
    if (opts.class) |c| {
        try w.print(
            \\ class="{s}"
        , .{c});
    }
    try w.print(
        \\>{s}</text>
        \\
    , .{text});
}

fn writeRect(
    w: *Io.Writer,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    rx: f64,
    ry: f64,
) Io.Writer.Error!void {
    try w.print(
        \\<rect x="{}" y="{}" width="{}" height="{}" rx="{}" ry="{}" />
        \\
    , .{
        x,     y,
        width, height,
        rx,    ry,
    });
}
