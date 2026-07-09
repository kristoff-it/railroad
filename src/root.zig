const std = @import("std");
const Io = std.Io;
const ziggy = @import("ziggy");
const Tokenizer = ziggy.Tokenizer;
const Deserializer = ziggy.Deserializer;

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
        d.width = 20;
        d.up = 10;
        d.down = 10;
        for (d.body) |*n| {
            n.layout();
            d.width += n.width;
            if (n.needs_space) d.width += 20;
            d.up = @max(d.up, n.up - d.height);
            d.height += n.height;
            d.down = @max(d.down - n.height, n.down);
        }

        d.width += 20;
    }

    pub fn format(d: *const Diagram, w: *Io.Writer) Io.Writer.Error!void {
        // self.width + paddingLeft + paddingRight
        const view_box_w = d.width + 20 + 20; // + paddingleft + paddingright;
        //self.up + self.height + self.down + paddingTop + paddingBottom
        const view_box_h = d.up + d.height + d.down + 20 + 20; // + paddingtop + paddingbottom

        const stroke_odd_pixel_length = true;
        const transform = if (stroke_odd_pixel_length) "translate(.5 .5)" else "";

        try w.print(
            \\<svg class="railroad-diagram" width={0} height={1} viewBox="0 0 {0} {1}">
            \\<g transform="{2s}">
            \\
        , .{ view_box_w, view_box_h, transform });

        var x: f64 = 20;
        var y: f64 = 20;
        y += d.up;
        {
            try w.writeAll("<g>\n");
            try writePath(w, x, y - 10, &.{
                .{ .down = 20 },
                .{ .m = .{ .x = 10, .y = -20 } },
                .{ .down = 20 },
                .{ .m = .{ .x = -10, .y = -10 } },
                .{ .right = 20 }, // todo
            });
            try w.writeAll("</g>\n");
            x += 20; // todo
        }

        for (d.body) |n| {
            if (n.needs_space) {
                try writePath(w, x, y, &.{
                    .{ .h = 10 },
                });
                x += 10;
            }
            try n.renderSvg(w, x, y);
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
            const char_width = 8;
            switch (n.raw) {
                .terminal => |t| {
                    const flen: f64 = @floatFromInt(t.len);
                    n.width = (flen * char_width) + 20.0;
                    n.up = 11;
                    n.down = 11;
                    n.needs_space = true;
                },
            }
        }

        fn renderSvg(n: *const Node, w: *Io.Writer, x: f64, y: f64) Io.Writer.Error!void {
            switch (n.raw) {
                .terminal => |text| {
                    try w.writeAll(
                        \\<g class="terminal">
                        \\
                    );
                    const gaps = determineGaps(n.width, n.width);
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
                        10,
                        10,
                    );

                    try writeText(w, x + gaps[0] + n.width / 2.0, y + 4, text);
                    try w.writeAll(
                        \\</g>
                        \\
                    );
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
};

const PathCmd = union(enum) {
    h: f64,
    m: struct { x: f64, y: f64 },
    right: f64,
    down: f64,
};
fn writePath(w: *Io.Writer, x: f64, y: f64, cmds: []const PathCmd) Io.Writer.Error!void {
    try w.print(
        \\<path d="M{} {}
    , .{ x, y });

    for (cmds) |cmd| switch (cmd) {
        .h => |h| try w.print(" h{}", .{h}),
        .m => |m| try w.print(" m{} {}", .{ m.x, m.y }),
        .right => |r| try w.print("h{}", .{@max(0, r)}),
        .down => |d| try w.print("v{}", .{@max(0, d)}),
    };

    try w.writeAll(
        \\"/>
        \\
    );
}

fn writeText(w: *Io.Writer, x: f64, y: f64, text: []const u8) Io.Writer.Error!void {
    try w.print(
        \\<text x="{}" y="{}">{s}</text>
        \\
    , .{ x, y, text });
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
