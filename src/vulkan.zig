const std = @import("std");
const xcb = @import("xcb.zig");

const required_extensions = &[_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_xcb_surface",
};

const Surface = u64;
const XConnection = @OpaqueType();
const PfnCreateXcbSurfaceKHR = fn (
    instance: usize,
    p_create_info: *const XcbSurfaceCreateInfoKHR,
    p_allocator: ?*c_void,
    p_surface: *Surface,
) callconv(.C) c_int;
const XcbSurfaceCreateInfoKHR = extern struct {
    s_type: c_int = 1000005000,
    p_next: ?*const c_void = null,
    flags: u32 = 0,
    connection: *XConnection,
    window: u32,
};

/// Returns the required vulkan extensions needed to create a surface
pub fn getRequiredInstanceExtensions() []const [*:0]const u8 {
    return required_extensions;
}

/// Uses the given loader to retrieve Vulkan functions
/// `load_fn` should be `fn(comptime T: type, proc_name: [:0]const u8)?T`
pub fn VulkanLoader(comptime load_fn: var) type {
    return struct {
        const Self = @This();
        create_surface_fn: PfnCreateXcbSurfaceKHR,

        pub fn init() !Self {
            const fn_ptr = load_fn(
                PfnCreateXcbSurfaceKHR,
                "vkCreateXcbSurfaceKHR",
            ) orelse return error.CreateSurfaceMissing;

            return Self{
                .create_surface_fn = fn_ptr,
            };
        }

        pub fn createSurface(self: Self, instance: usize, window: xcb.Window, display: *xcb.Display) !Surface {
            const surface_info = XcbSurfaceCreateInfoKHR{
                .connection = @ptrCast(*XConnection, &display.connection),
                .window = window.handle,
            };

            std.debug.print("Handle: {}\n", .{surface_info.window});

            var surface: Surface = undefined;
            const result = self.create_surface_fn(instance, &surface_info, null, &surface);
            std.debug.print("Result: {}\n", .{result});
            if (result != 0) {
                return error.CreationFailed;
            }
            return surface;
        }
    };
}
