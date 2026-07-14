const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ziggy = @import("ziggy");
const railroad = @import("railroad");

const html_css = @embedFile("html.css");
const html_js = @embedFile("html.js");

/// Don't forget to flush!
pub fn render(
    arena: Allocator,
    diagrams: *const ziggy.Dictionary(railroad.Diagram),
    css_src: []const u8,
    ziggy_src: [:0]const u8,
    w: *Io.Writer,
) !void {
    try w.print(
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<style>
        \\{s}
        \\</style>
        \\<style id="__railroad_css">
        \\{s}
        \\</style>
        \\<script>
        \\
        \\{s}
        \\
        \\window.onload = activate;
        \\</script>
        \\</head>
        \\<body>
    , .{
        html_css,
        css_src,
        html_js,
    });

    try renderBody(arena, diagrams, ziggy_src, w);

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
    arena: Allocator,
    diagrams: *const ziggy.Dictionary(railroad.Diagram),
    ziggy_src: [:0]const u8,
    w: *Io.Writer,
) !void {
    for (diagrams.fields.keys(), diagrams.fields.values()) |k, *d| {
        // I really don't want to copy this string :^)
        var src: []u8 = @constCast(d.loc.slice(ziggy_src)[2..]);
        const orig = src[src.len - 1];
        src[src.len - 1] = 0;
        defer src[src.len - 1] = orig;
        const d_src = src[0 .. src.len - 1 :0];

        const ziggy_ast = try ziggy.Ast.init(arena, d_src, .{});

        try w.print(
            \\<div class="tabbed-content">
            \\<ul class="tabs" role="tablist">
            \\<li role="tab" aria-selected="true" class="active">Diagram</li>
            \\<li role="tab" aria-selected="false">Ziggy Source</li>
            \\
            \\<div class="actions">
            \\<li class="copy-svg">
            \\<svg aria-hidden="true" focusable="false" viewBox="0 0 16 16" width="16" height="16" fill="currentColor" display="inline-block" overflow="visible" style="vertical-align:text-bottom">
            \\<path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 14.25Z"/>
            \\<path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z"/>
            \\</svg>
            \\<div class="tooltip">copied</div>
            \\<div>svg</div>
            \\</li>
            \\<li class="copy-ziggy">
            \\<svg aria-hidden="true" focusable="false" viewBox="0 0 16 16" width="16" height="16" fill="currentColor" display="inline-block" overflow="visible" style="vertical-align:text-bottom">
            \\<path d="M0 6.75C0 5.784.784 5 1.75 5h1.5a.75.75 0 0 1 0 1.5h-1.5a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 9.25 16h-7.5A1.75 1.75 0 0 1 0 14.25Z"/>
            \\<path d="M5 1.75C5 .784 5.784 0 6.75 0h7.5C15.216 0 16 .784 16 1.75v7.5A1.75 1.75 0 0 1 14.25 11h-7.5A1.75 1.75 0 0 1 5 9.25Zm1.75-.25a.25.25 0 0 0-.25.25v7.5c0 .138.112.25.25.25h7.5a.25.25 0 0 0 .25-.25v-7.5a.25.25 0 0 0-.25-.25Z"/>
            \\</svg>
            \\<div class="tooltip">copied</div>
            \\<div>ziggy</div>
            \\</li>
            \\<li class="save-svg">
            \\<svg aria-hidden="true" focusable="false" viewBox="0 0 16 16" width="16" height="16" fill="currentColor" display="inline-block" overflow="visible" style="vertical-align:text-bottom">
            \\<path d="M2.75 14A1.75 1.75 0 0 1 1 12.25v-2.5a.75.75 0 0 1 1.5 0v2.5c0 .138.112.25.25.25h10.5a.25.25 0 0 0 .25-.25v-2.5a.75.75 0 0 1 1.5 0v2.5A1.75 1.75 0 0 1 13.25 14Z"/>
            \\<path d="M7.25 7.689V2a.75.75 0 0 1 1.5 0v5.689l1.97-1.969a.749.749 0 1 1 1.06 1.06l-3.25 3.25a.749.749 0 0 1-1.06 0L4.22 6.78a.749.749 0 1 1 1.06-1.06l1.97 1.969Z"/>
            \\</svg>
            \\<div>svg+css</div>
            \\</li>
            \\<div>
            \\</ul>
            \\
            \\<div class="content">
            \\
            \\<div class="diagram show">
            \\<h2 class="diagram-name">{s}</h2>
            \\<div class="diagram-description">{s}</div>
            \\{f}
            \\</div>
            \\
            \\<div class="code">
            \\<pre>
            \\<code type="application/ziggy">
            \\{f}
            \\</code>
            \\</pre>
            \\</div>
            \\
            \\</div>
            \\</div>
            \\
        , .{
            k,
            d.description orelse "",
            d.fmt(null),
            ziggy_ast.fmt(d_src, .html),
        });
    }
}
