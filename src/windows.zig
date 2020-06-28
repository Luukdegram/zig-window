const std = @import("std");

usingnamespace @import("main.zig");

usingnamespace std.os.windows.user32;
const GetModuleHandleA = std.os.windows.kernel32.GetModuleHandleA;
const WS_POPUP = 0x80000000;
const WS_BORDER = 0x00800000;
const LPCSTR = std.os.windows.LPCSTR;
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

const MonitorEnumProc = fn (arg1: HMONITOR, arg2: ?HDC, arg3: ?*const Rect, arg4: LPARAM) callconv(.Stdcall) void;
extern "user32" fn MonitorFromPoint(pt: Point, dwFlags: u32) callconv(.Stdcall) ?HMONITOR;
extern "user32" fn GetMonitorInfoA(monitor: HMONITOR, lpmi: *MonitorInfoEx) bool;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PaintStruct) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PaintStruct) bool;
extern "user32" fn EnumDisplayMonitors(hdc: ?HDC, lprcClip: ?*const Rect, lpfnEnum: MonitorEnumProc, dwData: LPARAM) bool;

pub const DisplayHandle = HMONITOR;

pub const Display = struct {
    handle: HMONITOR,
    area: Rect,
    work_area: Rect,
};

fn openDisplayFromHandle(handle: HMONITOR) !Display {
    var monitor_info: MonitorInfoEx = undefined;
    monitor_info.cbSize = @sizeOf(MonitorInfoEx);

    if (!GetMonitorInfoA(handle, &monitor_info)) {
        return error.InvalidDisplayInfo;
    }

    return Display{
        .handle = handle,
        .area = monitor_info.rcMonitor,
        .work_area = monitor_info.rcWork,
    };
}

pub fn openDefaultDisplay(allocator: *std.mem.Allocator) !Display {
    const monitor_handle = MonitorFromPoint(.{ .x = 0, .y = 0 }, MONITOR_DEFAULTTOPRIMARY).?;
    return try openDisplayFromHandle(monitor_handle);
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

var class_id: ?LPCSTR = null;

pub fn createWindow(display: *Display, options: CreateWindowOptions) !Window {
    const hInstance = @ptrCast(HINSTANCE, GetModuleHandleA(null).?);

    if (class_id == null) {
        // zeroInit with the values we need doesnt work for some reason.
        var wnd_class = std.mem.zeroes(WNDCLASSEXA);
        wnd_class.cbSize = @sizeOf(WNDCLASSEXA);
        wnd_class.lpfnWndProc = wndProc;
        wnd_class.hInstance = hInstance;
        wnd_class.lpszClassName = "zig-window";

        const class_atom = RegisterClassExA(&wnd_class);
        class_id = @intToPtr(LPCSTR, @as(usize, class_atom));
    }

    const x = @divTrunc(display.work_area.right - display.work_area.left, 2) - @intCast(i32, options.width / 2);
    const y = @divTrunc(display.work_area.bottom - display.work_area.top, 2) - @intCast(i32, options.height / 2);
    const style: u32 = if (options.title_bar) WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX else WS_POPUP | WS_BORDER;
    if (CreateWindowExA(0, class_id.?, options.title, style, x, y, options.width, options.height, null, null, hInstance, null)) |handle| {
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

const GetInfoListError = error{
    InvalidDisplayInfo,
    OutOfMemory,
};

const MonitorEnumData = struct {
    list: std.ArrayList(Display),
    err: ?GetInfoListError,
};

fn monitorEnum(handle: HMONITOR, hdc: ?HDC, rect: ?*const Rect, param: LPARAM) callconv(.Stdcall) void {
    var data = @ptrCast(*MonitorEnumData, @alignCast(@alignOf(MonitorEnumData), param.?));
    data.list.append(openDisplayFromHandle(handle) catch |err| {
        data.err = err;
        return;
    }) catch {
        data.err = error.OutOfMemory;
        return;
    };
}

pub fn getDisplayList(allocator: *std.mem.Allocator) ![]Display {
    var data = MonitorEnumData{
        .list = std.ArrayList(Display).init(allocator),
        .err = null,
    };
    if (EnumDisplayMonitors(null, null, monitorEnum, @ptrCast(LPARAM, &data))) {
        return error.EnumDisplayMonitorsFailed;
    }
    if (data.err) |err| return err;
    return data.list.toOwnedSlice();
}
