const std = @import("std");
const window = @import("window");

pub const io_mode = .evented;

pub fn main() anyerror!void {
    var display = try window.openDefaultDisplay(std.heap.page_allocator);
    const win = try window.createWindow(&display, 800, 600);
    while (window.loop()) {
    }
}
