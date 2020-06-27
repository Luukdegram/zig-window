const std = @import("std");
pub usingnamespace switch (std.builtin.os.tag) {
    .windows => @import("windows.zig"),
    .linux => @import("xcb.zig"),
    else => @compileError("Unsupported OS"),
};
