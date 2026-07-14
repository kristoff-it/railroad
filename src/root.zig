const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const ziggy = @import("ziggy");
const Tokenizer = ziggy.Tokenizer;
const Deserializer = ziggy.Deserializer;

// VS: 8, // minimum vertical separation between things. For a 3px stroke, must be at least 4
// AR: 10, // radius of arcs
const vs: f64 = 8;
const arc: f64 = 10;
const padding: f64 = 20;
const mch_extra_width = 30 + arc * 2 + 20;
const term_char_width = 8;
const comment_char_width = 7;

pub const RawItem = union(enum) {
    terminal: []const u8,
    reference: []const u8,
    external: []const u8,
    inline_comment: []const u8,
    skip,
    label: struct {
        label: []const u8,
        item: *Diagram.Item,
    },
    label_path: []const u8,
    group: struct {
        label: ?[]const u8 = null,
        item: *Diagram.Item,
    },
    sequence: []Diagram.Item,
    sequence_stack: []Diagram.Item,
    sequence_optional: []Diagram.Item,
    sequence_alternating: struct {
        first: *Diagram.Item,
        second: *Diagram.Item,
    },
    choice: []Diagram.Item,
    choice_middle: []Diagram.Item,
    choice_last: []Diagram.Item,
    choice_index: ChoiceIndex,
    choice_horizontal: []Diagram.Item,
    multiple_choice_any: ChoiceIndex,
    multiple_choice_all: ChoiceIndex,
    repeat: *Diagram.Item,
    repeat_separator: struct {
        item: *Diagram.Item,
        separator: ?*Diagram.Item = null,
    },

    const ChoiceIndex = struct {
        index: usize,
        items: []Diagram.Item = &.{},
    };
};

pub const Diagram = struct {
    label: bool = false,
    alignment: Alignment = .center,
    delimiters: Delimiters = .directional,
    description: ?[]const u8 = null,
    body: []Item = &.{},

    name: []const u8 = undefined,
    up: f64 = 0,
    down: f64 = 0,
    height: f64 = 0,
    width: f64 = 0,

    loc: ziggy.Tokenizer.Token.Loc,

    pub const Alignment = enum { left, center, right };
    pub const Delimiters = enum { pipes, directional };

    pub const ziggy_options: ziggy.Options(Diagram) = .{
        .skip_fields = &.{ .up, .down, .height, .width, .loc, .name },
        .loc_field = .loc,
    };

    /// Will only contain valid data if the call to Diagram.layout failed.
    pub const LayoutDiagnostic = struct {
        loc: ziggy.Tokenizer.Token.Loc = undefined,
        kind: Kind = undefined,

        pub const Kind = enum {
            unknown_reference,
            sequence_empty,
            sequence_stack_empty,
            sequence_optional_two,
            choice_empty,
            choice_even,
            choice_index_oob,
            choice_horizontal_two,
            multiple_choice_index_oob,

            pub fn message(k: Kind) []const u8 {
                return switch (k) {
                    .unknown_reference => "reference not found",
                    .sequence_empty => "sequence cannot be empty",
                    .sequence_stack_empty => "stack cannot be empty",
                    .sequence_optional_two => "optional sequence requires at least 2 items",
                    .choice_empty => "choice cannot be empty",
                    .choice_even => "choice_middle requires an odd number of items",
                    .choice_index_oob => "choice index out of bounds",
                    .choice_horizontal_two => "choice_horizontal requires at least 2 items",
                    .multiple_choice_index_oob => "multiple_choice index out of bounds",
                };
            }
        };

        pub const Fmt = struct {
            d: LayoutDiagnostic,
            name: []const u8,
            ziggy_path: []const u8,
            ziggy_src: [:0]const u8,

            pub fn format(f: *const LayoutDiagnostic.Fmt, w: *Io.Writer) Io.Writer.Error!void {
                try f.d.render(f.name, f.ziggy_path, f.ziggy_src, w);
            }
        };

        pub fn fmt(
            d: LayoutDiagnostic,
            diagram_name: []const u8,
            ziggy_path: []const u8,
            ziggy_src: [:0]const u8,
        ) LayoutDiagnostic.Fmt {
            return .{
                .d = d,
                .name = diagram_name,
                .ziggy_path = ziggy_path,
                .ziggy_src = ziggy_src,
            };
        }

        pub fn render(
            d: LayoutDiagnostic,
            diagram_name: []const u8,
            ziggy_path: []const u8,
            ziggy_src: [:0]const u8,
            w: *Io.Writer,
        ) Io.Writer.Error!void {
            const sel = d.loc.getSelection(ziggy_src);
            const lp = ziggy.Deserializer.linePreview(ziggy_src, d.loc);
            try w.print("{s}:{}:{} (diagram '{s}'): {s}\n{f}\n", .{
                ziggy_path,
                sel.start.line,
                sel.start.col,
                diagram_name,
                d.kind.message(),
                lp,
            });
        }
    };

    pub fn layout(
        d: *Diagram,
        ds: *const ziggy.Dictionary(Diagram),
        name: []const u8,
        ld: *LayoutDiagnostic,
    ) error{Validation}!void {
        d.name = name;
        d.width = padding;
        d.up = 10;
        d.down = 10;
        for (d.body) |*n| {
            try n.layout(ds, ld);
            d.width += n.width;
            if (n.needs_space) d.width += padding;
            d.up = @max(d.up, n.up - d.height);
            d.height += n.height;
            d.down = @max(d.down - n.height, n.down);
        }

        if (d.label) {
            d.width += tof64(d.name.len) * term_char_width;
        }

        d.width += padding;
    }

    pub const Fmt = struct {
        css: ?[]const u8,
        d: *const Diagram,

        pub fn format(f: Fmt, w: *Io.Writer) Io.Writer.Error!void {
            try f.d.renderSvg(f.css, w);
        }
    };

    pub fn fmt(d: *const Diagram, embed_css: ?[]const u8) Fmt {
        return .{ .css = embed_css, .d = d };
    }

    pub fn renderSvg(d: *const Diagram, embed_css: ?[]const u8, w: *Io.Writer) Io.Writer.Error!void {
        // self.width + paddingLeft + paddingRight
        const view_box_w = d.width + padding + padding;
        //self.up + self.height + self.down + paddingTop + paddingBottom
        const view_box_h = d.up + d.height + d.down + padding + padding;

        const stroke_odd_pixel_length = true;
        const transform = if (stroke_odd_pixel_length) "translate(.5 .5)" else "";

        try w.print(
            \\<svg class="railroad-diagram" viewBox="0 0 {0} {1}" xmlns="http://www.w3.org/2000/svg">
            \\{2s}
            \\<g transform="{3s}">
            \\
        , .{ view_box_w, view_box_h, embed_css orelse "", transform });

        var x: f64 = padding;
        var y: f64 = padding;
        y += d.up;

        switch (d.delimiters) {
            .pipes => {
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
            },

            .directional => {
                try w.writeAll("<g>\n");
                try writePath(w, x, y, &.{.{ .h = 20 }});
                try writeCircle(w, x, y, 5);
                try w.writeAll("</g>\n");
                x += padding;
            },
        }
        if (d.label) {
            const l = d.name;
            const len = tof64(l.len) * term_char_width;
            const text_x = switch (d.delimiters) {
                .directional => padding - 5,
                .pipes => padding - 3,
            };
            try writeText(w, text_x, y - 11, l, .{ .style = "text-anchor:start" });
            try writePath(w, x, y, &.{.{ .h = len }});
            x += len;
        }

        for (d.body) |n| {
            if (n.needs_space) {
                try writePath(w, x, y, &.{
                    .{ .h = 10 },
                });
                x += 10;
            }
            try n.renderSvg(w, x, y, n.width, d.alignment);
            x += n.width;
            y += n.height;

            if (n.needs_space) {
                try writePath(w, x, y, &.{
                    .{ .h = 10 },
                });
                x += 10;
            }
        }

        switch (d.delimiters) {
            .pipes => {
                try w.print(
                    \\<path stroke="black" fill="none" d="M{} {} h 20 m -10 -10 v 20 m 10 -20 v 20" />
                    \\
                , .{ x, y });
            },
            .directional => {
                try w.print(
                    \\<path stroke="black" fill="none" d="M{} {} h 10"/>
                    \\<polygon points="{},{} {},{} {},{}"/>
                    \\
                , .{
                    x,      y,
                    x + 10, y - 5,
                    x + 10, y + 5,
                    x + 20, y,
                });
            },
        }

        try w.writeAll("</g></svg>\n\n");
    }

    pub const Item = struct {
        raw: RawItem,

        up: f64 = 0,
        down: f64 = 0,
        width: f64 = 0,
        height: f64 = 0,
        needs_space: bool = false,

        // used by a parent 'choice' element to store the separator
        // used by a parent 'horizontal choice' element to store the inner width
        separator: f64 = 0,
        loc: ziggy.Tokenizer.Token.Loc = undefined,

        pub const ziggy_options: ziggy.Options(Item) = .{
            .deserialize = deserialize,
            .roles = .{
                .container = .{
                    .@"union" = RawItem,
                },
            },
        };

        fn deserialize(
            d: *const Deserializer,
            first: Tokenizer.Token,
            top_lvl: bool,
        ) Deserializer.Error!Item {
            return .{
                .raw = try d.deserializeOne(RawItem, first, top_lvl),
                .loc = first.loc,
            };
        }

        fn layout(
            n: *Item,
            ds: *const ziggy.Dictionary(Diagram),
            ld: *LayoutDiagnostic,
        ) error{Validation}!void {
            alias: switch (n.raw) {
                .terminal, .reference, .external => |t| {
                    if (n.raw == .reference) {
                        if (!ds.fields.contains(t)) {
                            ld.* = .{ .loc = n.loc, .kind = .unknown_reference };
                            return error.Validation;
                        }
                    }
                    n.width = tof64(t.len * term_char_width) + padding;
                    n.up = 11;
                    n.down = 11;
                    n.needs_space = true;
                },
                .label => |l| {
                    const label_width = tof64(l.label.len * comment_char_width) + padding;
                    try l.item.layout(ds, ld);

                    n.width = l.item.width;
                    if (label_width > l.item.width + if (l.item.needs_space) padding else 0) {
                        n.width = label_width;
                    }

                    n.height = l.item.height;
                    n.up = l.item.height + 8 + vs * 2;
                    n.down = l.item.down;
                    n.needs_space = l.item.needs_space;
                },
                .inline_comment => |c| {
                    n.width = tof64(c.len * comment_char_width) + padding;
                    n.up = 8;
                    n.down = 8;
                    n.needs_space = true;
                },
                .skip => {
                    // n.needs_space = true;
                    // n.width = ar;
                },
                .label_path => |label| {
                    const label_width = tof64(label.len * comment_char_width) + padding;
                    n.width = label_width;
                },
                .sequence => |items| {
                    if (items.len == 0) {
                        ld.* = .{ .loc = n.loc, .kind = .sequence_empty };
                        return error.Validation;
                    }
                    n.needs_space = true;
                    for (items) |*item| {
                        try item.layout(ds, ld);
                        n.width += item.width + if (item.needs_space) tof64(20) else 0;
                        n.up = @max(n.up, item.up - n.height);
                        n.height += item.height;
                        n.down = @max(n.down - item.height, item.down);
                    }

                    if (items[0].needs_space) n.width -= 10;
                    if (items[items.len - 1].needs_space) n.width -= 10;
                },
                .sequence_stack => |items| {
                    if (items.len == 0) {
                        ld.* = .{ .loc = n.loc, .kind = .sequence_stack_empty };
                        return error.Validation;
                    }
                    for (items, 0..) |*item, idx| {
                        try item.layout(ds, ld);
                        n.width = @max(n.width, item.width + if (item.needs_space) padding else 0);
                        n.height += item.height;
                        if (idx > 0) {
                            n.height += @max(arc * 2, item.up + vs);
                        }
                        if (idx < items.len - 1) {
                            n.height += @max(arc * 2, item.down + vs);
                        }
                    }

                    if (items.len > 1) n.width += arc * 2;
                    n.needs_space = true;
                    n.up = items[0].up;
                    n.down = items[items.len - 1].down;
                },
                .sequence_optional => |items| {
                    if (items.len < 2) {
                        ld.* = .{ .loc = n.loc, .kind = .sequence_optional_two };
                        return error.Validation;
                    }

                    for (items) |*item| {
                        try item.layout(ds, ld);
                        n.height += item.height;
                    }

                    n.down = items[0].down;

                    var height_acc: f64 = 0;
                    for (items, 0..) |item, idx| {
                        n.up = @max(n.up, @max(arc * 2, item.up + vs) - height_acc);
                        height_acc += item.height;
                        if (idx > 0) {
                            n.down = @max(
                                n.height + n.down,
                                height_acc + @max(arc * 2, item.down + vs),
                            ) - n.height;
                        }
                        const item_width: f64 = item.width + if (item.needs_space) tof64(10) else 0;
                        if (idx == 0) {
                            n.width += arc + @max(item_width, arc);
                        } else {
                            n.width += arc * 2 + @max(item_width, arc) + arc;
                        }
                    }
                },
                .sequence_alternating => |alt| {
                    try alt.first.layout(ds, ld);
                    try alt.second.layout(ds, ld);
                    const arc_x: f64 = 1.0 / @sqrt(2.0) * arc * 2;
                    const arc_y: f64 = (1 - 1.0 / @sqrt(2.0)) * arc * 2;
                    const cross_y = @max(arc, vs);
                    const cross_x = (cross_y - arc_y) + arc_x;

                    const first_out = @max(arc + arc, cross_y / 2 + arc + arc, cross_y / 2 + vs + alt.first.down);
                    n.up = first_out + alt.first.height + alt.first.up;

                    const second_in = @max(arc + arc, cross_y / 2 + arc + arc, cross_y / 2 + vs + alt.second.up);
                    n.down = second_in + alt.second.height + alt.second.down;

                    const first_width = 2 * (if (alt.first.needs_space) tof64(10) else 0) + alt.first.width;
                    const second_width = 2 * (if (alt.second.needs_space) tof64(10) else 0) + alt.second.width;
                    n.width = 2 * arc + @max(first_width, cross_x, second_width) + 2 * arc;
                },
                .choice => |items| {
                    if (items.len == 0) {
                        ld.* = .{ .loc = n.loc, .kind = .choice_empty };
                        return error.Validation;
                    }
                    continue :alias .{
                        .choice_index = .{
                            .index = 0,
                            .items = items,
                        },
                    };
                },
                .choice_middle => |items| {
                    if (items.len % 2 == 0) {
                        ld.* = .{ .loc = n.loc, .kind = .choice_even };
                        return error.Validation;
                    }
                    continue :alias .{
                        .choice_index = .{
                            .index = @divExact(items.len - 1, 2),
                            .items = items,
                        },
                    };
                },
                .choice_last => |items| {
                    if (items.len == 0) {
                        ld.* = .{ .loc = n.loc, .kind = .choice_empty };
                        return error.Validation;
                    }
                    continue :alias .{
                        .choice_index = .{ .index = items.len - 1, .items = items },
                    };
                },
                .choice_index => |ch| {
                    if (ch.index >= ch.items.len) {
                        ld.* = .{ .loc = n.loc, .kind = .choice_index_oob };
                        return error.Validation;
                    }

                    for (ch.items) |*item| {
                        try item.layout(ds, ld);
                        n.width = @max(n.width, item.width);
                    }

                    n.width += arc * 4;

                    var arcs = arc * 2;
                    var i: isize = @intCast(ch.index);
                    i -= 1;
                    while (i >= 0) : (i -= 1) {
                        const item = &ch.items[@intCast(i)];
                        const lower_item = &ch.items[@intCast(i + 1)];

                        const entry_delta = lower_item.up + vs + item.down + item.height;
                        const exit_delta = lower_item.height + lower_item.up + vs + item.down;

                        item.separator = vs + if (exit_delta < arcs or entry_delta < arcs)
                            @max(arcs - entry_delta, arcs - exit_delta)
                        else
                            0;

                        n.up += lower_item.up + item.separator + item.down + item.height;
                        arcs = arc;
                    }

                    n.up += ch.items[0].up;
                    n.height = ch.items[ch.index].height;

                    arcs = arc * 2;
                    i = @intCast(ch.index + 1);
                    while (i < ch.items.len) : (i += 1) {
                        const item = &ch.items[@intCast(i)];
                        const upper_item = &ch.items[@intCast(i - 1)];

                        const entry_delta = upper_item.height + upper_item.down + vs + item.up;
                        const exit_delta = upper_item.down + vs + item.up + item.height;

                        upper_item.separator = vs + if (exit_delta < arcs or entry_delta < arcs)
                            @max(arcs - entry_delta, arcs - exit_delta)
                        else
                            0;

                        n.down += upper_item.down + upper_item.separator + item.up + item.height;
                        arcs = arc;
                    }

                    n.down += ch.items[ch.items.len - 1].down;
                },

                .multiple_choice_any, .multiple_choice_all => |mch| {
                    if (mch.index >= mch.items.len) {
                        ld.* = .{ .loc = n.loc, .kind = .multiple_choice_index_oob };
                        return error.Validation;
                    }

                    for (mch.items, 0..) |*item, idx| {
                        try item.layout(ds, ld);
                        n.width = @max(n.width, item.width);

                        const min: f64 = arc + if (idx == mch.index - 1 or idx == mch.index + 1) @as(f64, 10) else 0;
                        if (idx < mch.index) {
                            const next = mch.items[idx + 1];
                            n.up += @max(min, item.height + item.down + vs + next.up);
                        } else if (idx > mch.index) {
                            const prev = mch.items[idx - 1];
                            n.down += @max(min, item.up + vs + prev.down + prev.height);
                        }
                    }

                    const middle = mch.items[mch.index];

                    n.needs_space = true;
                    n.width += mch_extra_width;
                    n.height = middle.height;
                    n.up += mch.items[0].up;
                    n.down += mch.items[mch.items.len - 1].down - middle.height;
                },
                .choice_horizontal => |items| {
                    if (items.len < 2) {
                        ld.* = .{ .loc = n.loc, .kind = .choice_horizontal_two };
                        return error.Validation;
                    }

                    const first = &items[0];
                    const last = &items[items.len - 1];

                    n.width = arc; // starting track
                    n.width += arc * 2 * tof64(items.len - 1); // inbetween tracks
                    for (items) |*item| {
                        try item.layout(ds, ld);
                        n.width += item.width;
                        if (item.needs_space) n.width += padding;
                    }
                    if (last.height > 0) n.width += arc; // needs space to curve up
                    n.width += arc; //ending track

                    // Always exits at entrance height
                    n.height = 0;

                    // All but the last have a track running above them
                    const all_but_last_max_up = blk: {
                        var ablu: f64 = 0;
                        for (items[0 .. items.len - 1]) |i| ablu = @max(ablu, i.up);
                        break :blk ablu;
                    };

                    const upper_track = @max(arc * 2, vs, all_but_last_max_up + vs);
                    n.up = @max(upper_track, last.up);

                    // All but the first have a track running below them
                    // Last either straight-lines or curves up, so has different calculation
                    const middles_max = blk: {
                        var mm: f64 = 0;
                        for (items[1 .. items.len - 1]) |i| {
                            mm = @max(mm, i.height + @max(i.down + vs, arc * 2));
                        }
                        break :blk mm;
                    };

                    const lower_track = blk: {
                        var lt = @max(
                            vs,
                            middles_max,
                            last.height + last.down + vs,
                        );
                        // Make sure there's at least 2*AR room between first exit and lower track
                        if (first.height < lt) lt = @max(lt, first.height + arc * 2);
                        break :blk lt;
                    };

                    n.down = @max(lower_track, first.height + first.down);
                },
                .repeat => |item| continue :alias .{
                    .repeat_separator = .{
                        .item = item,
                        .separator = null,
                    },
                },
                .repeat_separator => |rs| {
                    try rs.item.layout(ds, ld);

                    var skip: Item = .{ .raw = .skip };
                    const rep = rs.separator orelse &skip;
                    try rep.layout(ds, ld);

                    n.needs_space = true;
                    n.width = @max(rs.item.width, rep.width) + arc * 2;
                    n.height = rs.item.height;
                    n.up = rs.item.up;
                    n.down = @max(arc * 2, rs.item.down + vs +
                        rep.up + rep.height + rep.down);
                },
                .group => |g| {
                    try g.item.layout(ds, ld);

                    const label: ?Item = if (g.label) |l| blk: {
                        var temp: Item = .{ .raw = .{ .inline_comment = l } };
                        try temp.layout(ds, ld);
                        break :blk temp;
                    } else null;

                    n.width = @max(
                        g.item.width + if (g.item.needs_space) padding else 0,
                        if (label) |l| l.width else 0,
                        arc * 2,
                    );

                    n.needs_space = true;
                    n.height = g.item.height;
                    n.down = @max(g.item.down + vs, arc);
                    n.up = @max(g.item.up + vs, arc);
                    if (label) |l| {
                        n.up += l.up + l.height + l.down;
                    }
                },
            }
        }

        fn renderSvg(
            n: *const Item,
            w: *Io.Writer,
            orig_x: f64,
            orig_y: f64,
            width: f64,
            alignment: Alignment,
        ) Io.Writer.Error!void {
            alias: switch (n.raw) {
                .repeat => |item| continue :alias .{
                    .repeat_separator = .{ .item = item, .separator = null },
                },
                .choice => |items| continue :alias .{
                    .choice_index = .{ .index = 0, .items = items },
                },
                .choice_middle => |items| continue :alias .{
                    .choice_index = .{ .index = @divExact(items.len - 1, 2), .items = items },
                },
                .choice_last => |items| continue :alias .{
                    .choice_index = .{ .index = items.len - 1, .items = items },
                },
                .terminal, .reference, .external => |text| {
                    try w.print(
                        \\<g class="{s}">
                        \\
                    , .{@tagName(n.raw)});
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{
                        .{ .h = gaps[0] },
                    });
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y, &.{
                        .{ .h = gaps[1] },
                    });
                    try writeRect(
                        w,
                        orig_x + gaps[0],
                        orig_y - 11,
                        n.width,
                        n.up + n.down,
                        if (n.raw == .terminal) 10 else 0,
                        if (n.raw == .terminal) 10 else 0,
                        .{},
                    );

                    try writeText(w, orig_x + gaps[0] + n.width / 2.0, orig_y + 4, text, .{});
                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .skip => {
                    try writePath(w, orig_x, orig_y, &.{
                        .{ .right = width },
                    });
                },
                .label => |l| {
                    try w.writeAll(
                        \\<g>
                        \\
                    );

                    const label_width = tof64(l.label.len * comment_char_width) + padding;
                    const gaps = determineGaps(width, label_width, .center);

                    const inner_width = @max(n.width, width);
                    try l.item.renderSvg(w, orig_x, orig_y, inner_width, alignment);

                    try writeText(
                        w,
                        orig_x + gaps[0] + label_width / 2.0,
                        orig_y - l.item.up - vs + 2,
                        l.label,
                        .{
                            .class = "comment",
                        },
                    );

                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .label_path => |label| {
                    try w.writeAll(
                        \\<g>
                        \\
                    );

                    const label_width = tof64(label.len * comment_char_width) + padding;
                    const gaps = determineGaps(width, label_width, .center);

                    const inner_width = @max(n.width, width);

                    // skip
                    try writePath(w, orig_x, orig_y, &.{
                        .{ .right = inner_width },
                    });

                    // comment
                    try writeText(
                        w,
                        orig_x + gaps[0] + label_width / 2.0,
                        orig_y - vs + 2,
                        label,
                        .{
                            .class = "comment",
                        },
                    );

                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .inline_comment => |text| {
                    try w.writeAll(
                        \\<g class="comment">
                        \\
                    );
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{
                        .{ .h = gaps[0] },
                    });
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .h = gaps[1] },
                    });
                    try writeText(w, orig_x + gaps[0] + n.width / 2.0, orig_y + 5, text, .{
                        .class = "comment",
                    });
                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .sequence => |items| {
                    try w.writeAll(
                        \\<g>
                        \\
                    );
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .h = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .h = gaps[1] },
                    });
                    var x = orig_x + gaps[0];
                    var y = orig_y;
                    for (items, 0..) |item, idx| {
                        if (item.needs_space and idx > 0) {
                            try writePath(w, x, y, &.{.{ .h = 10 }});
                            x += 10;
                        }

                        try item.renderSvg(w, x, y, item.width, alignment);

                        x += item.width;
                        y += item.height;
                        if (item.needs_space and idx < items.len - 1) {
                            try writePath(w, x, y, &.{.{ .h = 10 }});
                            x += 10;
                        }
                    }
                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .sequence_stack => |items| {
                    try w.writeAll(
                        \\<g>
                        \\
                    );
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .h = gaps[0] }});
                    var x = orig_x + gaps[0];

                    if (items.len > 1) {
                        try writePath(w, x, orig_y, &.{.{ .h = arc }});
                        x += arc;
                    }

                    const inner_width: f64 = n.width - if (items.len > 1) arc * 2 else 0.0;
                    var y = orig_y;
                    for (items, 0..) |item, idx| {
                        try item.renderSvg(w, x, y, inner_width, alignment);
                        x += inner_width;
                        y += item.height;

                        if (idx < items.len - 1) {
                            try writePath(w, x, y, &.{
                                .{ .arc = .{ .n, .e } }, .{ .down = @max(0, item.down + vs - arc * 2) },
                                .{ .arc = .{ .e, .s } }, .{ .left = inner_width },
                                .{ .arc = .{ .n, .w } }, .{ .down = @max(0, items[idx + 1].up + vs - arc * 2) },
                                .{ .arc = .{ .w, .s } },
                            });

                            y += @max(item.down + vs, arc * 2) + @max(items[idx + 1].up + vs, arc * 2);
                            x = orig_x + gaps[0] + arc;
                        }
                    }

                    if (items.len > 1) {
                        try writePath(w, x, y, &.{.{ .h = arc }});
                        x += arc;
                    }

                    try writePath(w, x, y, &.{.{ .h = gaps[1] }});

                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .sequence_optional => |items| {
                    try w.writeAll(
                        \\<g>
                        \\
                    );
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .right = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .right = gaps[1] },
                    });

                    const upper_line_y = orig_y - n.up;
                    var x = orig_x + gaps[0];
                    var y = orig_y;

                    // first item
                    {
                        const item = items[0];
                        const item_space: f64 = if (item.needs_space) tof64(10) else 0;
                        const item_width = item.width + item_space;
                        // Upper skip
                        try writePath(w, x, y, &.{
                            .{ .arc = .{ .s, .e } },
                            .{ .up = y - upper_line_y - arc * 2 },
                            .{ .arc = .{ .w, .n } },
                            .{ .right = item_width - arc },

                            .{ .arc = .{ .n, .e } },
                            .{ .down = y + item.height - upper_line_y - arc * 2 },
                            .{ .arc = .{ .w, .s } },
                        });

                        // Straight line
                        try writePath(w, x, y, &.{.{ .right = item_space + arc }});

                        try item.renderSvg(w, x + item_space + arc, y, item.width, alignment);
                        x += item_width + arc;
                        y += item.height;
                        // x ends on the far side of the first element,
                        // where the next element's skip needs to begin
                    }

                    // middle items
                    for (items[1 .. items.len - 1]) |item| {
                        const item_space: f64 = if (item.needs_space) tof64(10) else 0;
                        const item_width = item.width + item_space;

                        // Upper skip
                        try writePath(w, x, upper_line_y, &.{
                            .{ .right = arc * 2 + @max(item_width, arc) + arc },
                            .{ .arc = .{ .n, .e } },
                            .{ .down = y - upper_line_y + item.height - arc * 2 },
                            .{ .arc = .{ .w, .s } },
                        });

                        // Straight line
                        try writePath(w, x, y, &.{.{ .right = arc * 2 }});
                        try item.renderSvg(w, x + arc * 2, y, item.width, alignment);
                        try writePath(w, x + item.width + arc * 2, y + item.height, &.{
                            .{ .right = item_space + arc },
                        });

                        // Lower skip
                        try writePath(w, x, y, &.{
                            .{ .arc = .{ .n, .e } },
                            .{ .down = item.height + @max(item.down + vs, arc * 2) - arc * 2 },
                            .{ .arc = .{ .w, .s } },
                            .{ .right = item_width - arc },
                            .{ .arc = .{ .s, .e } },
                            .{ .up = item.down + vs - arc * 2 },
                            .{ .arc = .{ .w, .n } },
                        });

                        x += arc * 2 + @max(item_width, arc) + arc;
                        y += item.height;
                    }

                    // last item
                    {
                        assert(items.len >= 2);

                        const item = items[items.len - 1];
                        const item_space: f64 = if (item.needs_space) tof64(10) else 0;
                        const item_width = item.width + item_space;

                        // Straight line
                        try writePath(w, x, y, &.{.{ .right = arc * 2 }});
                        try item.renderSvg(w, x + arc * 2, y, item.width, alignment);
                        try writePath(w, x + arc * 2 + item.width, y + item.height, &.{
                            .{ .right = item_space + arc },
                        });

                        // Lower skip
                        try writePath(w, x, y, &.{
                            .{ .arc = .{ .n, .e } },
                            .{ .down = item.height + @max(item.down + vs, arc * 2) - arc * 2 },
                            .{ .arc = .{ .w, .s } },
                            .{ .right = item_width - arc },
                            .{ .arc = .{ .s, .e } },
                            .{ .up = item.down + vs - arc * 2 },
                            .{ .arc = .{ .w, .n } },
                        });
                    }

                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
                .sequence_alternating => |alt| {
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .right = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y, &.{
                        .{ .right = gaps[1] },
                    });

                    const x = orig_x + gaps[0];

                    // top
                    const first_in = n.up - alt.first.up;
                    const first_out = n.up - alt.first.up - alt.first.height;
                    try writePath(w, x, orig_y, &.{
                        .{ .arc = .{ .s, .e } },
                        .{ .up = first_in - 2 * arc },
                        .{ .arc = .{ .w, .n } },
                    });

                    try alt.first.renderSvg(w, x + 2 * arc, orig_y - first_in, n.width - 4 * arc, alignment);
                    try writePath(w, x + n.width - 2 * arc, orig_y - first_out, &.{
                        .{ .arc = .{ .n, .e } },
                        .{ .down = first_out - 2 * arc },
                        .{ .arc = .{ .w, .s } },
                    });

                    // bottom
                    const second_in = n.down - alt.second.down - alt.second.height;
                    const second_out = n.down - alt.second.down;
                    try writePath(w, x, orig_y, &.{
                        .{ .arc = .{ .n, .e } },
                        .{ .down = second_in - 2 * arc },
                        .{ .arc = .{ .w, .s } },
                    });

                    try alt.second.renderSvg(w, x + 2 * arc, orig_y + second_in, n.width - 4 * arc, alignment);
                    try writePath(w, x + n.width - 2 * arc, orig_y + second_out, &.{
                        .{ .arc = .{ .s, .e } },
                        .{ .up = second_out - 2 * arc },
                        .{ .arc = .{ .w, .n } },
                    });

                    // crossover
                    const arc_x: f64 = 1.0 / @sqrt(2.0) * arc * 2;
                    const arc_y: f64 = (1 - 1.0 / @sqrt(2.0)) * arc * 2;
                    const cross_y = @max(arc, vs);
                    const cross_x = (cross_y - arc_y) + arc_x;
                    const cross_bar = (n.width - 4 * arc - cross_x) / 2;
                    try writePath(w, x + arc, orig_y - cross_y / 2 - arc, &.{
                        .{ .arc = .{ .w, .s } },
                        .{ .right = cross_bar },
                        .{ .arc8 = .{ .start = .n, .dir = .cw } },
                        .{ .l = .{ .x = cross_x - arc_x, .y = cross_y - arc_y } },
                        .{ .arc8 = .{ .start = .sw, .dir = .ccw } },
                        .{ .right = cross_bar },
                        .{ .arc = .{ .n, .e } },
                    });

                    try writePath(w, x + arc, orig_y + cross_y / 2 + arc, &.{
                        .{ .arc = .{ .w, .n } },
                        .{ .right = cross_bar },
                        .{ .arc8 = .{ .start = .s, .dir = .ccw } },
                        .{ .l = .{ .x = cross_x - arc_x, .y = -(cross_y - arc_y) } },
                        .{ .arc8 = .{ .start = .nw, .dir = .cw } },
                        .{ .right = cross_bar },
                        .{ .arc = .{ .s, .e } },
                    });
                },
                .choice_index => |ch| {
                    try w.writeAll(
                        \\<g>
                        \\
                    );
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .h = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .h = gaps[1] },
                    });

                    const x = orig_x + gaps[0];
                    const inner_width = n.width - arc * 4;

                    // Curve above elements
                    var y_distance: f64 = 0;
                    var i: isize = @intCast(ch.index);
                    i -= 1;

                    while (i >= 0) : (i -= 1) {
                        const item = ch.items[@intCast(i)];
                        const lower_item = ch.items[@intCast(i + 1)];
                        y_distance += lower_item.up + item.separator + item.down + item.height;

                        try writePath(w, x, orig_y, &.{
                            .{ .arc = .{ .s, .e } },
                            .{ .up = y_distance - arc * 2 },
                            .{ .arc = .{ .w, .n } },
                        });

                        try item.renderSvg(w, x + arc * 2, orig_y - y_distance, inner_width, alignment);

                        try writePath(
                            w,
                            x + arc * 2 + inner_width,
                            orig_y - y_distance + item.height,
                            &.{
                                .{ .arc = .{ .n, .e } },
                                .{ .down = y_distance - item.height + n.height - arc * 2 },
                                .{ .arc = .{ .w, .s } },
                            },
                        );
                    }

                    // straight line path
                    try writePath(w, x, orig_y, &.{.{ .right = arc * 2 }});
                    try ch.items[ch.index].renderSvg(w, x + arc * 2, orig_y, inner_width, alignment);
                    try writePath(w, x + arc * 2 + inner_width, orig_y + n.height, &.{
                        .{ .right = arc * 2 },
                    });

                    y_distance = 0;
                    i = @intCast(ch.index + 1);
                    while (i < ch.items.len) : (i += 1) {
                        const item = ch.items[@intCast(i)];
                        const upper_item = ch.items[@intCast(i - 1)];
                        y_distance += upper_item.height + upper_item.down + upper_item.separator + item.up;
                        try writePath(w, x, orig_y, &.{
                            .{ .arc = .{ .n, .e } },
                            .{ .down = y_distance - arc * 2 },
                            .{ .arc = .{ .w, .s } },
                        });

                        try item.renderSvg(w, x + arc * 2, orig_y + y_distance, inner_width, alignment);

                        try writePath(
                            w,
                            x + arc * 2 + inner_width,
                            orig_y + y_distance + item.height,
                            &.{
                                .{ .arc = .{ .s, .e } },
                                .{ .up = y_distance - arc * 2 + item.height - n.height },
                                .{ .arc = .{ .w, .n } },
                            },
                        );
                    }

                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },

                .multiple_choice_any, .multiple_choice_all => |mch| {
                    try w.writeAll("<g>");
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .h = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .h = gaps[1] },
                    });

                    const x = orig_x + gaps[0];

                    const middle = mch.items[mch.index];
                    const inner_width = n.width - mch_extra_width;

                    var y_distance: f64 = 0;
                    var i: isize = @intCast(mch.index);
                    i -= 1;
                    while (i >= 0) : (i -= 1) {
                        const item = mch.items[@intCast(i)];

                        if (i == mch.index - 1) {
                            y_distance = @max(10 + arc, middle.up + vs + item.down + item.height);
                        }

                        try writePath(w, x + 30, orig_y, &.{
                            .{ .up = y_distance - arc },
                            .{ .arc = .{ .w, .n } },
                        });

                        try item.renderSvg(w, x + 30 + arc, orig_y - y_distance, inner_width, alignment);

                        try writePath(
                            w,
                            x + 30 + arc + inner_width,
                            orig_y - y_distance + item.height,
                            &.{
                                .{ .arc = .{ .n, .e } },
                                .{ .down = y_distance - item.height + n.height - arc - 10 },
                            },
                        );

                        if (i != 0) {
                            const prev = mch.items[@intCast(i - 1)];
                            y_distance += @max(arc, item.up + vs + prev.down + prev.height);
                        }
                    }

                    try writePath(w, x + 30, orig_y, &.{.{ .right = arc }});
                    try middle.renderSvg(w, x + 30 + arc, orig_y, inner_width, alignment);
                    try writePath(
                        w,
                        x + 30 + arc + inner_width,
                        orig_y + n.height,
                        &.{.{ .right = arc }},
                    );

                    y_distance = @max(10 + arc, middle.height + middle.down + vs + mch.items[mch.index - 1].up);
                    i = @intCast(mch.index + 1);
                    while (i < mch.items.len) : (i += 1) {
                        const item = mch.items[@intCast(i)];
                        try writePath(w, x + 30, orig_y, &.{
                            .{ .down = y_distance - arc },
                            .{ .arc = .{ .w, .s } },
                        });

                        try item.renderSvg(w, x + 30 + arc, orig_y + y_distance, inner_width, alignment);

                        try writePath(
                            w,
                            x + 30 + arc + inner_width,
                            orig_y + y_distance + item.height,
                            &.{
                                .{ .arc = .{ .s, .e } },
                                .{ .up = y_distance - arc + item.height - middle.height },
                            },
                        );

                        if (i < mch.items.len - 1) {
                            const next = mch.items[@intCast(i + 1)];
                            y_distance += @max(arc, item.height + item.down + vs + next.up);
                        }
                    }

                    const title = switch (n.raw) {
                        .multiple_choice_any => "take one or more brances in any order, the same branch cannot be taken more than once",
                        .multiple_choice_all => "take all branches in any order, the same branch cannot be taken more than once",
                        else => unreachable,
                    };
                    const text = switch (n.raw) {
                        .multiple_choice_any => "1+",
                        .multiple_choice_all => "all",
                        else => unreachable,
                    };
                    try w.print(
                        \\<g class="diagram-text">
                        \\<title>{s}</title>
                        \\<path stroke="black" fill="none" d="M {} {} h -26 a 4 4 0 0 0 -4 4 v 12 a 4 4 0 0 0 4 4 h 26 z" class="diagram-text"/>
                        \\<text x="{}" y="{}" class="diagram-text">{s}</text>
                        \\<path stroke="black" fill="none" d="M {} {} h 16 a 4 4 0 0 1 4 4 v 12 a 4 4 0 0 1 -4 4 h -16 z" class="diagram-text"/>
                        \\<path stroke="black" fill="none" d="M {} {} a 4 4 0 1 0 6 -1 m 2.75 -1 h -4 v 4 m 0 -3 h 2" style="stroke-width: 1.75"/>
                        \\</g>
                    , .{
                        title,            x + 30,
                        orig_y - 10,      orig_x + 15,
                        orig_y + 4,       text,
                        x + n.width - 20, orig_y - 10,
                        x + n.width - 13, orig_y - 2,
                    });

                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },

                .choice_horizontal => |items| {
                    // Hook up the two sides if this is narrower than its stated width.
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .h = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .h = gaps[1] },
                    });

                    var x = orig_x + gaps[0];
                    const first = items[0];
                    const last = items[items.len - 1];

                    // upper track
                    const all_but_last_max_up = blk: {
                        var ablu: f64 = 0;
                        for (items[0 .. items.len - 1]) |i| ablu = @max(ablu, i.up);
                        break :blk ablu;
                    };
                    const upper_track = @max(arc * 2, vs, all_but_last_max_up + vs);

                    const upper_span = tof64(items.len - 2) * arc * 2 - arc + blk: {
                        var us: f64 = 0;
                        for (items[0 .. items.len - 1]) |i| {
                            us += i.width;
                            if (i.needs_space) us += 20;
                        }
                        break :blk us;
                    };

                    try writePath(w, x, orig_y, &.{
                        .{ .arc = .{ .s, .e } },
                        .{ .v = -(upper_track - arc * 2) },
                        .{ .arc = .{ .w, .n } },
                        .{ .h = upper_span },
                    });

                    // lower track
                    const middles_max = blk: {
                        var mm: f64 = 0;
                        for (items[1 .. items.len - 1]) |i| {
                            mm = @max(mm, i.height + @max(i.down + vs, arc * 2));
                        }
                        break :blk mm;
                    };
                    const lower_track = blk: {
                        var lt = @max(
                            vs,
                            middles_max,
                            last.height + last.down + vs,
                        );
                        // Make sure there's at least 2*AR room between first exit and lower track
                        if (first.height >= lt) lt = @max(lt, first.height + arc * 2);
                        break :blk lt;
                    };
                    const lower_span = tof64(items.len - 2) * arc * 2 - arc + blk: {
                        var us: f64 = 0;
                        for (items[1..]) |i| {
                            us += i.width;
                            if (i.needs_space) us += 20;
                        }
                        break :blk us;
                    } + if (last.height > 0) arc else 0;

                    const lower_start = x + arc + first.width + arc * 2 + if (first.needs_space) tof64(20) else 0;

                    try writePath(w, lower_start, orig_y + lower_track, &.{
                        .{ .h = lower_span },
                        .{ .arc = .{ .s, .e } },
                        .{ .v = -(lower_track - arc * 2) },
                        .{ .arc = .{ .w, .n } },
                    });

                    // items
                    for (items, 0..) |item, idx| {
                        // input track
                        if (idx == 0) {
                            try writePath(w, x, orig_y, &.{.{ .h = arc }});
                            x += arc;
                        } else if (items[idx - 1].raw == .skip) {
                            try writePath(w, x, orig_y, &.{.{ .h = arc * 2 }});
                            x += arc * 2;
                        } else if (idx == items.len - 1 and item.raw == .skip) {
                            try writePath(w, x, orig_y - upper_track, &.{
                                .{ .arc = .{ .n, .e } },
                                .{ .v = upper_track - arc * 2 },
                                .{ .arc = .{ .w, .s } },
                            });
                            x += arc * 2;
                        } else {
                            try writePath(w, x, orig_y - upper_track, &.{
                                .{ .arc = .{ .n, .e } },
                                .{ .v = upper_track - arc * 2 },
                                .{ .arc = .{ .w, .s } },
                            });
                            x += arc * 2;
                        }

                        const item_width = item.width + if (item.needs_space) tof64(20) else 0;
                        try item.renderSvg(w, x, orig_y, item_width, alignment);
                        x += item_width;

                        // output track
                        if (idx == items.len - 1) {
                            if (item.height == 0) {
                                try writePath(w, x, orig_y, &.{.{ .h = arc }});
                            } else {
                                try writePath(w, x, orig_y + item.height, &.{.{ .arc = .{ .s, .e } }});
                            }
                        } else if (idx == 0 and item.height > lower_track) {
                            // Needs to arc up to meet the lower track, not down.
                            if (item.height - lower_track >= arc * 2) {
                                try writePath(w, x, orig_y + item.height, &.{
                                    .{ .arc = .{ .s, .e } },
                                    .{ .v = lower_track - item.height + arc * 2 },
                                    .{ .arc = .{ .w, .n } },
                                });
                            } else {
                                // Not enough space to fit two arcs
                                // so just bail and draw a straight line for now.
                                try writePath(w, x, orig_y + item.height, &.{
                                    .{
                                        .l = .{
                                            .x = arc * 2,
                                            .y = lower_track - item.height,
                                        },
                                    },
                                });
                            }
                        } else if (idx == 0 and item.raw == .skip) {
                            try writePath(w, x - arc, orig_y + item.height, &.{
                                .{ .arc = .{ .n, .e } },
                                .{ .v = lower_track - item.height - arc * 2 },
                                .{ .arc = .{ .w, .s } },
                                .{ .h = arc },
                            });
                        } else {
                            try writePath(w, x, orig_y + item.height, &.{
                                .{ .arc = .{ .n, .e } },
                                .{ .v = lower_track - item.height - arc * 2 },
                                .{ .arc = .{ .w, .s } },
                            });
                        }
                    }
                },

                .repeat_separator => |rs| {
                    var skip: Item = .{ .raw = .skip };
                    const rep = rs.separator orelse &skip;

                    // Hook up the two sides if this is narrower than its stated width.
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .h = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .h = gaps[1] },
                    });

                    const x = orig_x + gaps[0];

                    // Draw item
                    try writePath(w, x, orig_y, &.{
                        .{ .right = arc },
                    });
                    try rs.item.renderSvg(w, x + arc, orig_y, n.width - arc * 2, alignment);
                    try writePath(w, x + n.width - arc, orig_y + n.height, &.{
                        .{ .right = arc },
                    });

                    // Draw repeat arc
                    const y_distance = @max(arc * 2, rs.item.height + rs.item.down + vs + rep.up);
                    try writePath(w, x + arc, orig_y, &.{
                        .{ .arc = .{ .n, .w } },
                        .{ .down = y_distance - arc * 2 },
                        .{ .arc = .{ .w, .s } },
                    });

                    try rep.renderSvg(w, x + arc, orig_y + y_distance, n.width - arc * 2, alignment);
                    try writePath(w, x + n.width - arc, orig_y + y_distance + rep.height, &.{
                        .{ .arc = .{ .s, .e } },
                        .{ .up = y_distance - arc * 2 + rep.height - rs.item.height },
                        .{ .arc = .{ .e, .n } },
                    });
                },

                .group => |g| {
                    try w.writeAll("<g>");
                    const gaps = determineGaps(width, n.width, alignment);
                    try writePath(w, orig_x, orig_y, &.{.{ .h = gaps[0] }});
                    try writePath(w, orig_x + gaps[0] + n.width, orig_y + n.height, &.{
                        .{ .h = gaps[1] },
                    });

                    const x = orig_x + gaps[0];

                    try g.item.renderSvg(w, x, orig_y, n.width, alignment);

                    const box_up = @max(g.item.up + vs, arc);
                    const x_delta = switch (alignment) {
                        .left => -padding / 2,
                        .center => 0,
                        .right => padding / 2,
                    };

                    try writeRect(
                        w,
                        x + x_delta,
                        orig_y - box_up,
                        n.width,
                        box_up + n.height + n.down,
                        arc,
                        arc,
                        .{
                            .class = "group-box",
                        },
                    );

                    if (g.label) |l| {
                        var label: Item = .{ .raw = .{ .inline_comment = l } };
                        label.layout(undefined, undefined) catch unreachable;
                        try label.renderSvg(
                            w,
                            x,
                            orig_y - (box_up + label.down + label.height) - 2,
                            label.width,
                            alignment,
                        );
                    }

                    try w.writeAll(
                        \\</g>
                        \\
                    );
                },
            }
        }

        fn determineGaps(outer: f64, inner: f64, alignment: Alignment) [2]f64 {
            const diff = outer - inner;
            switch (alignment) {
                .left => return .{ 0, diff },
                .right => return .{ diff, 0 },
                .center => return .{ diff / 2.0, diff / 2.0 },
            }
        }
    };
};

const PathCmd = union(enum) {
    h: f64,
    v: f64,
    l: struct { x: f64, y: f64 },
    m: struct { x: f64, y: f64 },
    right: f64,
    left: f64,
    down: f64,
    up: f64,
    arc: [2]Sweep,
    arc8: packed struct(u16) {
        start: enum(u8) { n, ne, nw, s, se, sw, e, w },
        dir: enum(u8) { cw, ccw },
    },

    pub const Sweep = enum { n, s, w, e };
};

fn eq(lhs: [2]PathCmd.Sweep, rhs: [2]PathCmd.Sweep) bool {
    return lhs[0] == rhs[0] and lhs[1] == rhs[1];
}

fn writePath(w: *Io.Writer, x: f64, y: f64, cmds: []const PathCmd) Io.Writer.Error!void {
    try w.print(
        \\<path stroke="black" fill="none" d="M{} {}
    , .{ x, y });

    for (cmds) |cmd| switch (cmd) {
        .h => |h| try w.print(" h{}", .{h}),
        .v => |v| try w.print("v{}", .{v}),
        .m => |m| try w.print(" m{} {}", .{ m.x, m.y }),
        .l => |l| try w.print(" l{} {}", .{ l.x, l.y }),
        .right => |r| try w.print("h{}", .{@max(0, r)}),
        .left => |l| try w.print("h{}", .{-@max(0, l)}),
        .down => |d| try w.print("v{}", .{@max(0, d)}),
        .up => |u| try w.print("v{}", .{-@max(0, u)}),
        .arc => |sweep| {
            const arc_x: f64 = if (sweep[0] == .e or sweep[1] == .w) -arc else arc;
            const arc_y: f64 = if (sweep[0] == .s or sweep[1] == .n) -arc else arc;

            const cw: u8 = @intFromBool(
                eq(sweep, .{ .n, .e }) or
                    eq(sweep, .{ .e, .s }) or
                    eq(sweep, .{ .s, .w }) or
                    eq(sweep, .{ .w, .n }),
            );

            try w.print("a {} {} 0 0 {} {} {}", .{
                arc, arc, cw, arc_x, arc_y,
            });
        },
        .arc8 => |cs| {
            // 1/8 of a circle
            const s2 = 1.0 / @sqrt(2.0) * arc;
            const s2inv = (arc - s2);

            try w.print("a {} {} 0 0 {s} ", .{ arc, arc, if (cs.dir == .cw) "1" else "0" });
            const offset: [2]f64 = switch (cs) {
                //sd == 'ncw'   ? [s2, s2inv] :
                .{ .start = .n, .dir = .cw } => .{ s2, s2inv },
                // sd == 'necw'  ? [s2inv, s2] :
                .{ .start = .ne, .dir = .cw } => .{ s2inv, s2 },
                // sd == 'ecw'   ? [-s2inv, s2] :
                .{ .start = .e, .dir = .cw } => .{ -s2inv, s2 },
                // sd == 'secw'  ? [-s2, s2inv] :
                .{ .start = .se, .dir = .cw } => .{ -s2, s2inv },
                // sd == 'scw'   ? [-s2, -s2inv] :
                .{ .start = .s, .dir = .cw } => .{ -s2, -s2inv },
                // sd == 'swcw'  ? [-s2inv, -s2] :
                .{ .start = .sw, .dir = .cw } => .{ -s2inv, -s2 },
                // sd == 'wcw'   ? [s2inv, -s2] :
                .{ .start = .w, .dir = .cw } => .{ s2inv, -s2 },
                // sd == 'nwcw'  ? [s2, -s2inv] :
                .{ .start = .nw, .dir = .cw } => .{ s2, -s2inv },
                // sd == 'nccw'  ? [-s2, s2inv] :
                .{ .start = .n, .dir = .ccw } => .{ -s2, s2inv },
                // sd == 'nwccw' ? [-s2inv, s2] :
                .{ .start = .nw, .dir = .ccw } => .{ -s2inv, s2 },
                // sd == 'wccw'  ? [s2inv, s2] :
                .{ .start = .w, .dir = .ccw } => .{ s2inv, s2 },
                // sd == 'swccw' ? [s2, s2inv] :
                .{ .start = .sw, .dir = .ccw } => .{ s2, s2inv },
                // sd == 'sccw'  ? [s2, -s2inv] :
                .{ .start = .s, .dir = .ccw } => .{ s2, -s2inv },
                // sd == 'seccw' ? [s2inv, -s2] :
                .{ .start = .se, .dir = .ccw } => .{ s2inv, -s2 },
                // sd == 'eccw'  ? [-s2inv, -s2] :
                .{ .start = .e, .dir = .ccw } => .{ -s2inv, -s2 },
                // sd == 'neccw' ? [-s2, -s2inv] : null
                .{ .start = .ne, .dir = .ccw } => .{ -s2, -s2inv },
                else => unreachable,
            };

            try w.print("{} {}", .{ offset[0], offset[1] });
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
        style: ?[]const u8 = null,
    },
) Io.Writer.Error!void {
    try w.print(
        \\<text text-anchor="middle" x="{}" y="{}"
    , .{ x, y });
    if (opts.class) |c| {
        try w.print(
            \\ class="{s}"
        , .{c});
    }
    if (opts.style) |c| {
        try w.print(
            \\ style="{s}"
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
    opts: struct {
        class: ?[]const u8 = null,
    },
) Io.Writer.Error!void {
    try w.print(
        \\<rect stroke="black" fill="none" x="{}" y="{}" width="{}" height="{}" rx="{}" ry="{}"
    , .{
        x,     y,
        width, height,
        rx,    ry,
    });

    if (opts.class) |cl| {
        try w.print(
            \\ class="{s}"
        , .{cl});
    }

    try w.writeAll(
        \\/>
        \\
    );
}

fn writeCircle(
    w: *Io.Writer,
    cx: f64,
    cy: f64,
    r: f64,
) Io.Writer.Error!void {
    try w.print(
        \\<circle cx="{}" cy="{}" r="{}" />
        \\
    , .{ cx, cy, r });
}

fn tof64(int: anytype) f64 {
    return @floatFromInt(int);
}
