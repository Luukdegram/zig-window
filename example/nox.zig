const std = @import("std");
const window = @import("window");

pub const io_mode = .evented;

pub fn main() !void {
    const loop = std.event.Loop.instance.?;
    try loop.initSingleThreaded(std.heap.direct_allocator);
    defer loop.deinit();

    var result: @typeOf(asyncMain).ReturnType.ErrorSet!void = undefined;
    var frame: @Frame(asyncMain) = undefined;
    _ = @asyncCall(&frame, &result, asyncMain, loop);
    loop.run();
    return result;
}

async fn asyncMain(loop: *std.event.Loop) !void {
    loop.beginOneEvent();
    defer loop.finishOneEvent();

    const conn = try window.openDefaultDisplay(std.heap.direct_allocator);
    switch (conn.status) {
        .Ok => {},
        else => std.debug.warn("unable to open default display: {}\n", conn.setup),
    }
    std.debug.warn("OK\n");
}