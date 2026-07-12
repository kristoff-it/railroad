const std = @import("std");
const Io = std.Io;
const ziggy = @import("ziggy");
const railroad = @import("railroad");

const html_css = @embedFile("html.css");
const live_js = @embedFile("main/live.js");

/// Don't forget to flush!
pub fn render(
    diagrams: *const ziggy.Dictionary(railroad.Diagram),
    css_src: []const u8,
    /// Whether to add live reloading JS code or not.
    live: bool,
    w: *Io.Writer,
) !void {
    try w.print(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<script>
        \\{s}
        \\</script>
        \\<style>
        \\{s}
        \\</style>
        \\<style id="__railroad_css">
        \\{s}
        \\</style>
        \\</head>
        \\<body>
    , .{
        if (live) live_js else "",
        html_css,
        css_src,
    });

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
