const std = @import("std");
pub usingnamespace switch (std.builtin.os.tag) {
    .windows => @import("windows.zig"),
    .linux => @import("xcb.zig"),
    else => @compileError("Unsupported OS"),
};

pub const CreateWindowOptions = struct {
    width: u16,
    height: u16,
    title: [*:0]const u8,
    title_bar: bool = true,
};

pub const DisplayInfo = struct {
    width: u16,
    height: u16,

    handle: DisplayHandle,
};
