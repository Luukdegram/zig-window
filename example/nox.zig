const std = @import("std");
const window = @import("window");

pub const io_mode = .evented;

pub fn main() !void {
    var conn = try window.openDefaultDisplay(std.heap.page_allocator);
    switch (conn.status) {
        .Ok => {},
        else => {
            std.debug.print("unable to open default display: {}\n", .{conn.setup});
            std.process.exit(1);
        },
    }

    try window.createWindow(&conn, 0, 0, 500, 500);

    std.debug.warn("OK\n", .{});

    //display screen
    while (true) {}
}
