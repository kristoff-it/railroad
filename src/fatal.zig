const std = @import("std");
const panic = std.debug.panic;
const builtin = @import("builtin");

pub fn msg(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) panic("\n\n(debug stack trace)\n", .{});
    std.process.exit(1);
}

pub fn oom() noreturn {
    msg("oom\n", .{});
}

pub fn dir(path: []const u8, err: anyerror) noreturn {
    msg("error accessing dir '{s}': {t}\n", .{ path, err });
}

pub fn file(path: []const u8, err: anyerror) noreturn {
    msg("error accessing file '{s}': {t}\n", .{ path, err });
}

pub fn fileCreate(path: []const u8, err: anyerror) noreturn {
    msg("error creating file '{s}': {t}\n", .{ path, err });
}

pub fn fileOpen(path: []const u8, err: anyerror) noreturn {
    msg("error opening file '{s}': {t}\n", .{ path, err });
}

pub fn fileRead(path: []const u8, err: anyerror) noreturn {
    msg("error reading file '{s}': {t}\n", .{ path, err });
}

pub fn fileWrite(path: []const u8, err: anyerror) noreturn {
    msg("error writing file '{s}': {t}\n", .{ path, err });
}
