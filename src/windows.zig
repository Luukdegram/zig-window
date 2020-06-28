const std = @import("std");

usingnamespace std.os.windows.user32;
const GetModuleHandleA = std.os.windows.kernel32.GetModuleHandleA;
const HDC = std.os.windows.HDC;
const HWND = std.os.windows.HWND;
const HINSTANCE = std.os.windows.HINSTANCE;
const LPARAM = std.os.windows.LPARAM;
const LRESULT = std.os.windows.LRESULT;

const Rect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const Point = extern struct {
    x: i32,
    y: i32,
};

const MonitorInfoEx = extern struct {
    cbSize: u32 = @sizeOf(MonitorInfoEx),
    /// Full area of the monitor
    rcMonitor: Rect,
    /// Work area, the portion of the screen not obscured by the system taskbar or by application desktop toolbars.
    rcWork: Rect,
    dwFlags: u32,
    szDevice: [32]u8,
};

const PaintStruct = extern struct {
    hdc: HDC,
    fErase: bool,
    rcPaint: Rect,
    fRestore: bool,
    fIncUpdate: bool,
    rgbReserved: [32]u8,
};

const MONITOR_DEFAULTTOPRIMARY = 0x01;
const HMONITOR = *@OpaqueType();

extern "user32" fn MonitorFromPoint(pt: Point, dwFlags: u32) callconv(.Stdcall) ?HMONITOR;
extern "user32" fn GetMonitorInfoA(monitor: HMONITOR, lpmi: *MonitorInfoEx) bool;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PaintStruct) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PaintStruct) bool;

pub const Display = struct {
    handle: HMONITOR,
    area: Rect,
    work_area: Rect,
    device_name_mem: [32]u8,

    pub fn deviceName(self: Display) []const u8 {
        return std.mem.spanZ(@ptrCast([*:0]const u8, &self.device_name_mem));
    }
};

pub fn openDefaultDisplay(allocator: *std.mem.Allocator) !Display {
    const monitor_handle = MonitorFromPoint(.{ .x = 0, .y = 0 }, MONITOR_DEFAULTTOPRIMARY).?;
    var monitor_info: MonitorInfoEx = undefined;
    monitor_info.cbSize = @sizeOf(MonitorInfoEx);

    if (!GetMonitorInfoA(monitor_handle, &monitor_info)) {
        return error.InvalidDisplayInfo;
    }

    return Display{
        .handle = monitor_handle,
        .area = monitor_info.rcMonitor,
        .work_area = monitor_info.rcWork,
        .device_name_mem = monitor_info.szDevice,
    };
}

pub const Window = struct {
    handle: HWND,
};

fn wndProc(handle: HWND, msg: c_uint, wParam: usize, lParam: LPARAM) callconv(.Stdcall) LRESULT {
    switch (msg) {
        WM_DESTROY => {
            PostQuitMessage(0);
            return null;
        },
        WM_PAINT => {
            var ps: PaintStruct = undefined;
            const hdc = BeginPaint(handle, &ps);
            _ = EndPaint(handle, &ps);
            return null;
        },
        else => return DefWindowProcA(handle, msg, wParam, lParam),
    }
}

// pub fn createWindow(connection: *Connection) !xcb_window_t {
pub fn createWindow(display: *Display, width: u16, height: u16) !Window {
    const hInstance = @ptrCast(HINSTANCE, GetModuleHandleA(null).?);

    // zeroInit with the values we need doesnt work for some reason.
    var wnd_class = std.mem.zeroes(WNDCLASSEXA);
    wnd_class.cbSize = @sizeOf(WNDCLASSEXA);
    wnd_class.lpfnWndProc = wndProc;
    wnd_class.hInstance = hInstance;
    wnd_class.lpszClassName = "zig-window";

    const class_id = RegisterClassExA(&wnd_class);

    const x = @divTrunc(display.work_area.right - display.work_area.left, 2) - @intCast(i32, width / 2);
    const y = @divTrunc(display.work_area.bottom - display.work_area.top, 2) - @intCast(i32, height / 2);
    if (CreateWindowExA(
        0,
        "zig-window",
        "Zig window",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        x,
        y,
        width,
        height,
        null,
        null,
        hInstance,
        null,
    )) |handle| {
        _ = ShowWindow(handle, SW_SHOW);
        return Window{ .handle = handle };
    } else {
        return error.CreateWindowFailed;
    }
}

pub fn loop() bool {
    var msg: MSG = undefined;
    const ret = GetMessageA(&msg, null, 0, 0);
    if (!ret) return false;
    _ = TranslateMessage(&msg);
    _ = DispatchMessageA(&msg);
    return true;
}
