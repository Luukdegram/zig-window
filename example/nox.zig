const std = @import("std");
const window = @import("window");

pub const io_mode = .evented;

pub fn main() anyerror!void {
    var displays = try window.collectDisplays(std.heap.page_allocator);
    defer std.heap.page_allocator.free(displays);

    var display = try window.openDisplay(displays[0]);
    const win = try window.createWindow(&display, .{
        .width = 800,
        .height = 600,
        .title = "Zig window",
    });
    while (window.loop()) {}
}
