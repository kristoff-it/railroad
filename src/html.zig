const std = @import("std");
const Io = std.Io;
const ziggy = @import("ziggy");
const railroad = @import("railroad");

const html_css = @embedFile("html.css");

/// Don't forget to flush!
pub fn render(
    diagrams: *const ziggy.Dictionary(railroad.Diagram),
    css_src: []const u8,
    w: *Io.Writer,
) !void {
    try w.print(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<style>
        \\{s}
        \\</style>
        \\<style>
        \\{s}
        \\</style>
        \\</head>
        \\<body>
    , .{
        html_css,
        css_src,
    });

    try renderBody(diagrams, w);

    try w.writeAll(
        \\</body>
        \\</html>
        \\
    );
}

/// Renders only the content that would go into the `<body>` element.
///
/// Don't forget to flush!
pub fn renderBody(
    diagrams: *const ziggy.Dictionary(railroad.Diagram),
    w: *Io.Writer,
) !void {
    for (diagrams.fields.keys(), diagrams.fields.values()) |k, *d| {
        try w.print(
            \\<div class="diagram-title-block">
            \\<span class="diagram-title">{s}</span>
            \\</span>
            \\</div>
            \\{f}
            \\
        , .{ k, d.fmt(null) });
    }
}
