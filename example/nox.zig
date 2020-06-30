const std = @import("std");
const window = @import("window");

pub const io_mode = .evented;

pub fn main() anyerror!void {
    var displays = try window.getDisplayList(std.heap.page_allocator);
    defer std.heap.page_allocator.free(displays);

    const win = try displays[0].createWindow(.{
        .width = 800,
        .height = 600,
        .title = "Zig window",
    });

    const ctx = try win.makeGLContext(3, 1);

    while (window.loop()) {}
}
