const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const os = std.os;
const fs = std.fs;
const net = std.net;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const File = std.fs.File;

usingnamespace @import("xproto.zig");

pub const Display = struct {
    name: []u8,
};

pub const Connection = struct {
    allocator: *Allocator,
    file: File,
    setup_buffer: []u8,
    setup: Setup,
    status: Status,
    xid: Xid,
    formats: []Format,
    screens: []Screen,

    /// Setup contains the base and mask retrieved from XSetup
    pub const Setup = struct {
        base: u32,
        mask: u32,
    };

    /// Xid is used to determine the window id
    const Xid = struct {
        last: u32,
        max: u32,
        base: u32,
        inc: u32,

        fn init(connection: Connection) Xid {
            // we could use @setRuntimeSafety(false) in this case
            const inc: i32 = @bitCast(i32, connection.setup.mask) &
                -@bitCast(i32, connection.setup.mask);
            return Xid{
                .last = 0,
                .max = 0,
                .base = connection.setup.base,
                .inc = @bitCast(u32, inc),
            };
        }
    };

    /// Status represents the state of the connection
    pub const Status = enum {
        SetupFailed = 0,
        Ok = 1,
        Authenticate = 2,
    };

    /// Generates a new XID
    fn getNewXid(self: *Connection) !u32 {
        var ret: u32 = 0;
        if (self.status != .Ok) {
            return error.InvalidConnection;
        }
        var temp: u32 = undefined;
        if (@subWithOverflow(u32, self.xid.max, self.xid.inc, &temp)) {
            temp = 0;
        }
        if (self.xid.last >= temp) {
            if (self.xid.last == 0) {
                self.xid.max = self.setup.mask;
            } else {
                const xid_range_request = XIdRangeRequest{
                    .major_opcode = 136,
                    .minor_opcode = 1,
                    .length = 1,
                };
                var parts: [1]os.iovec_const = undefined;
                parts[0].iov_base = @ptrCast([*]const u8, &xid_range_request);
                parts[0].iov_len = @sizeOf(XIdRangeRequest);

                _ = try self.file.writev(parts[0..1]);
                const stream = self.file.reader();
                const reply = try stream.readStruct(XIdRangeReply);

                self.xid.last = reply.start_id;
                self.xid.max = reply.start_id + (reply.count - 1) * self.xid.inc;
            }
        } else {
            self.xid.last += self.xid.inc;
        }
        ret = self.xid.last | self.xid.base;
        return ret;
    }

    /// Disconnects from X and frees all memory
    pub fn disconnect(self: *Connection) void {
        self.allocator.free(self.setup_buffer);
        self.allocator.free(self.formats);
        self.allocator.free(self.screens);
        self.file.close();
        self.* = undefined;
    }
};

pub const Auth = struct {
    family: u16,
    address: []u8,
    number: []u8,
    name: []u8,
    data: []u8,

    fn deinit(self: *Auth, allocator: *Allocator) void {
        allocator.free(self.address);
        allocator.free(self.number);
        allocator.free(self.name);
        allocator.free(self.data);
        self.* = undefined;
    }
};

pub fn openDefaultDisplay(allocator: *Allocator) !Connection {
    const default_name = getDefaultDisplayName() orelse return error.UnknownDefaultDisplay;
    return openDisplay(allocator, default_name);
}

pub fn getDefaultDisplayName() ?[]const u8 {
    return os.getenv("DISPLAY");
}

pub fn createWindow(connection: *Connection, width: u16, height: u16) !void {
    var window: XWindow = try connection.getNewXid();
    const screen:Screen = connection.screens[0];

    const window_request = XCreateWindowRequest{
        .major_opcode = 1,
        .depth = 0,
        .length = @sizeOf(XCreateWindowRequest) / 4,
        .wid = window,
        .parent = screen.root,
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
        .border_width = 10,
        .class = 0,
        .visual = 0,
        .value_mask = 0,
    };
    var parts: [2]os.iovec_const = undefined;
    parts[0].iov_base = @ptrCast([*]const u8, &window_request);
    parts[0].iov_len = @sizeOf(XCreateWindowRequest);

    const map_request = XMapWindowRequest{
        .major_opcode = 8,
        .pad0 = 0,
        .length = @sizeOf(XMapWindowRequest) / 4,
        .window = window,
    };
    parts[1].iov_base = @ptrCast([*]const u8, &map_request);
    parts[1].iov_len = @sizeOf(XMapWindowRequest);

    _ = try connection.file.writev(parts[0..2]);
}

pub const OpenDisplayError = error{
    OutOfMemory,
    InvalidDisplayFormat,
    UnableToConnectToServer,
    SetupFailed,
    AuthFileUnavailable,

    // TODO get rid of some of these
    FileDescriptorAlreadyPresentInSet,
    OperationCausesCircularLoop,
    FileDescriptorNotRegistered,
    SystemResources,
    UserResourceLimitReached,
    FileDescriptorIncompatibleWithEpoll,
    Unexpected,
    InputOutput,
    AccessDenied,
    EndOfStream,
    InvalidStatus,
};

pub fn openDisplay(allocator: *Allocator, name: []const u8) !Connection {
    const parsed = parseDisplay(name) catch |err| switch (err) {
        error.Overflow => return error.InvalidDisplayFormat,
        error.MissingColon => return error.InvalidDisplayFormat,
        error.MissingDisplayIndex => return error.InvalidDisplayFormat,
        error.InvalidCharacter => return error.InvalidDisplayFormat,
    };
    return try connectToDisplay(allocator, parsed, null);
}

pub const ParsedDisplay = struct {
    host: []const u8,
    protocol: []const u8,
    display: u32,
    screen: u32,
};

pub fn parseDisplay(name: []const u8) !ParsedDisplay {
    var result = ParsedDisplay{
        .host = undefined,
        .protocol = name[0..0],
        .display = undefined,
        .screen = undefined,
    };
    const after_prot = if (mem.lastIndexOfScalar(u8, name, '/')) |slash_pos| blk: {
        result.protocol = name[0..slash_pos];
        break :blk name[slash_pos..];
    } else name;

    const colon = mem.lastIndexOfScalar(u8, after_prot, ':') orelse return error.MissingColon;
    var it = mem.split(after_prot[colon + 1 ..], ".");
    result.display = try std.fmt.parseInt(u32, it.next() orelse return error.MissingDisplayIndex, 10);
    result.screen = if (it.next()) |s| try std.fmt.parseInt(u32, s, 10) else 0;
    result.host = after_prot[0..colon];
    return result;
}

pub fn open(host: []const u8, protocol: []const u8, display: u32) !File {
    if (protocol.len != 0 and !mem.eql(u8, protocol, "unix")) {
        return error.UnsupportedProtocol;
    }

    var path_buf: [fs.MAX_PATH_BYTES]u8 = undefined;
    const socket_path = std.fmt.bufPrint(path_buf[0..], "/tmp/.X11-unix/X{}", .{display}) catch unreachable;
    return net.connectUnixSocket(socket_path);
}

pub fn connectToDisplay(allocator: *Allocator, parsed: ParsedDisplay, optional_auth: ?Auth) !Connection {
    const file = open(parsed.host, parsed.protocol, parsed.display) catch return error.UnableToConnectToServer;
    errdefer file.close();

    var cleanup_auth = false;
    var auth = if (optional_auth) |a| a else blk: {
        cleanup_auth = true;
        break :blk getAuth(allocator, file, parsed.display) catch |e| switch (e) {
            error.WouldBlock => unreachable,
            error.OperationAborted => unreachable,
            error.ConnectionResetByPeer => return error.AuthFileUnavailable,
            error.IsDir => return error.AuthFileUnavailable,
            error.SharingViolation => return error.AuthFileUnavailable,
            error.PathAlreadyExists => return error.AuthFileUnavailable,
            error.FileNotFound => return error.AuthFileUnavailable,
            error.PipeBusy => return error.AuthFileUnavailable,
            error.NameTooLong => return error.AuthFileUnavailable,
            error.InvalidUtf8 => return error.AuthFileUnavailable,
            error.BadPathName => return error.AuthFileUnavailable,
            error.FileTooBig => return error.AuthFileUnavailable,
            error.SymLinkLoop => return error.AuthFileUnavailable,
            error.ProcessFdQuotaExceeded => return error.AuthFileUnavailable,
            error.NoDevice => return error.AuthFileUnavailable,
            error.NoSpaceLeft => return error.AuthFileUnavailable,
            error.EndOfStream => return error.AuthFileUnavailable,
            error.InputOutput => return error.AuthFileUnavailable,
            error.NotDir => return error.AuthFileUnavailable,
            error.AccessDenied => return error.AuthFileUnavailable,
            error.HomeDirectoryNotFound => return error.AuthFileUnavailable,
            error.BrokenPipe => return error.AuthFileUnavailable,
            error.DeviceBusy => return error.AuthFileUnavailable,
            error.PermissionDenied => return error.AuthFileUnavailable,
            error.ConnectionTimedOut => return error.AuthFileUnavailable,
            error.FileLocksNotSupported => return error.AuthFileUnavailable,

            error.Unexpected => return error.Unexpected,

            error.SystemFdQuotaExceeded => return error.SystemResources,
            error.SystemResources => return error.AuthFileUnavailable,

            error.OutOfMemory => return error.OutOfMemory,
        };
    };
    defer if (cleanup_auth) auth.deinit(allocator);

    return connectToFile(allocator, file, auth) catch |err| switch (err) {
        error.WouldBlock => unreachable,
        error.OperationAborted => unreachable,
        error.DiskQuota => unreachable,
        error.FileTooBig => unreachable,
        error.NoSpaceLeft => unreachable,
        error.IsDir => return error.UnableToConnectToServer,
        error.BrokenPipe => return error.UnableToConnectToServer,
        error.ConnectionResetByPeer => return error.UnableToConnectToServer,
        else => |e| return e,
    };
}

pub fn loop() bool {
    return true;
}

fn xpad(n: usize) usize {
    return @bitCast(usize, (-%@bitCast(isize, n)) & 3);
}

test "xpad" {
    assert(xpad(1) == 3);
    assert(xpad(2) == 2);
    assert(xpad(3) == 1);
    assert(xpad(4) == 0);
    assert(xpad(5) == 3);
    assert(xpad(6) == 2);
    assert(xpad(7) == 1);
    assert(xpad(8) == 0);
}

/// file must be `O_RDWR`.
/// `O_NONBLOCK` may be set if `std.event.Loop.instance != null`.
pub fn connectToFile(allocator: *Allocator, file: File, auth: ?Auth) !Connection {
    var conn = Connection{
        .allocator = allocator,
        .file = file,
        .setup = undefined,
        .setup_buffer = undefined,
        .status = undefined,
        .xid = undefined,
        .formats = undefined,
        .screens = undefined,
    };

    try writeSetup(file, auth);
    try readSetup(allocator, &conn);
    if (conn.status == .Ok) {
        conn.xid = Connection.Xid.init(conn);
    }

    return conn;
}

fn readSetup(allocator: *Allocator, conn: *Connection) !void {
    const stream = &conn.file.reader();

    const XSetupGeneric = extern struct {
        status: u8,
        pad0: [5]u8,
        length: u16,
    };
    const header = try stream.readStruct(XSetupGeneric);

    conn.setup_buffer = try allocator.alloc(u8, header.length * 4);
    errdefer allocator.free(conn.setup_buffer);

    try stream.readNoEof(conn.setup_buffer);

    conn.status = switch (header.status) {
        0 => Connection.Status.SetupFailed,
        1 => Connection.Status.Ok,
        2 => Connection.Status.Authenticate,
        else => return error.InvalidStatus,
    };

    if (conn.status == .Ok) {
        _ = try parseSetup(conn);
    }
}

/// Format represents support pixel formats
pub const Format = struct {
    depth: u32,
    bits_per_pixel: u8,
    scanline_pad: u8,
};

/// Depth of screen buffer
pub const Depth = struct {
    depth: u8,
    visual_types: []VisualType,
};

/// Represents the type of the visuals on the screen
pub const VisualType = struct {
    id: u32,
    bits_per_rgb_value: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
};

/// Screen with its values, each screen has a root id
/// which is unique and is used to create windows on the screen
pub const Screen = struct {
    root: u32,
    default_colormap: u32,
    white_pixel: u32,
    black_pixel: u32,
    current_input_mask: u32,
    width_pixel: u16,
    height_pixel: u16,
    width_milimeter: u16,
    height_milimeter: u16,
    min_installed_maps: u16,
    max_installed_maps: u16,
    root_visual: u32,
    backing_store: u8,
    save_unders: u8,
    root_depth: u8,
    depths: []Depth
};

/// Parses the setup received from the connection into
/// seperate struct types
fn parseSetup(conn: *Connection) !void {
    var allocator = conn.allocator;

    var setup: XSetup = undefined;
    var index: usize = parseSetupType(&setup, conn.setup_buffer[0..]);
    
    conn.setup = Connection.Setup{
        .base = setup.resource_id_base,
        .mask = setup.resource_id_mask,
    };

    // ignore the vendor for now
    const vendor = conn.setup_buffer[index .. index + setup.vendor_len];
    index += vendor.len;

    var formats = std.ArrayList(Format).init(allocator);
    errdefer formats.deinit();
    var format_counter: usize = 0;
    while (format_counter < setup.pixmap_formats_len) : (format_counter += 1) {
        var format: XFormat = undefined;
        index += parseSetupType(&format, conn.setup_buffer[index..]);
        try formats.append(.{
            .depth = format.depth,
            .bits_per_pixel = format.bits_per_pixel,
            .scanline_pad = format.scanline_pad
        });
    }

    var screens = std.ArrayList(Screen).init(allocator);
    errdefer screens.deinit();
    var screen_counter: usize = 0;
    while (screen_counter < setup.roots_len) : (screen_counter += 1) {
        var screen: XScreen = undefined;
        index += parseSetupType(&screen, conn.setup_buffer[index..]);

        var depths = std.ArrayList(Depth).init(allocator);
        errdefer depths.deinit();
        var depth_counter: usize = 0;
        while (depth_counter < screen.allowed_depths_len) : (depth_counter += 1) {
            var depth: XDepth = undefined;
            index += parseSetupType(&depth, conn.setup_buffer[index..]);

            var visual_types = std.ArrayList(VisualType).init(allocator);
            errdefer visual_types.deinit();
            var visual_counter: usize = 0;
            while (visual_counter < depth.visuals_len) : (visual_counter += 1) {
                var visual_type: XVisualType = undefined;
                index += parseSetupType(&visual_type, conn.setup_buffer[index..]);
                try visual_types.append(.{
                    .id = visual_type.visual_id,
                    .bits_per_rgb_value = visual_type.bits_per_rgb_value,
                    .colormap_entries = visual_type.colormap_entries,
                    .red_mask = visual_type.red_mask,
                    .green_mask = visual_type.green_mask,
                    .blue_mask = visual_type.blue_mask,
                });
            }

            try depths.append(.{
                .depth = depth.depth,
                .visual_types = visual_types.toOwnedSlice()
            });
        }
        try screens.append(.{
            .root = screen.root,
            .default_colormap = screen.default_colormap,
            .white_pixel = screen.white_pixel,
            .black_pixel = screen.black_pixel,
            .current_input_mask = screen.current_input_mask,
            .width_pixel = screen.width_pixel,
            .height_pixel = screen.height_pixel,
            .width_milimeter = screen.width_milimeter,
            .height_milimeter = screen.height_milimeter,
            .min_installed_maps = screen.min_installed_maps,
            .max_installed_maps = screen.max_installed_maps,
            .root_visual = screen.root_visual,
            .backing_store = screen.backing_store,
            .save_unders = screen.save_unders,
            .root_depth = screen.root_depth,
            .depths = depths.toOwnedSlice()
        });
    }
    
    if (index != conn.setup_buffer.len) {
        return error.IncorrectSetup;
    }
    
    conn.formats = formats.toOwnedSlice();
    conn.screens = screens.toOwnedSlice();
}

/// Retrieves the wanted type from the buffer and returns its size
fn parseSetupType(wanted: var, buffer: []u8) usize {
    assert(@typeInfo(@TypeOf(wanted)) == .Pointer);
    const size = @sizeOf(@TypeOf(wanted.*));
    wanted.* = std.mem.bytesToValue(@TypeOf(wanted.*), buffer[0..size]);
    return size;
}

fn writeSetup(file: File, auth: ?Auth) !void {
    const pad = [3]u8{ 0, 0, 0 };
    var parts: [6]os.iovec_const = undefined;
    var parts_index: usize = 0;
    var setup_req = XSetupRequest{
        .byte_order = if (builtin.endian == builtin.Endian.Big) 0x42 else 0x6c,
        .pad0 = 0,
        .protocol_major_version = X_PROTOCOL,
        .protocol_minor_version = X_PROTOCOL_REVISION,
        .authorization_protocol_name_len = 0,
        .authorization_protocol_data_len = 0,
        .pad1 = [2]u8{ 0, 0 },
    };
    parts[parts_index].iov_len = @sizeOf(XSetupRequest);
    parts[parts_index].iov_base = @ptrCast([*]const u8, &setup_req);
    parts_index += 1;
    comptime assert(xpad(@sizeOf(XSetupRequest)) == 0);

    if (auth) |a| {
        setup_req.authorization_protocol_name_len = @intCast(u16, a.name.len);
        parts[parts_index].iov_len = a.name.len;
        parts[parts_index].iov_base = a.name.ptr;
        parts_index += 1;
        parts[parts_index].iov_len = xpad(a.name.len);
        parts[parts_index].iov_base = &pad;
        parts_index += 1;

        setup_req.authorization_protocol_data_len = @intCast(u16, a.data.len);
        parts[parts_index].iov_len = a.data.len;
        parts[parts_index].iov_base = a.data.ptr;
        parts_index += 1;
        parts[parts_index].iov_len = xpad(a.data.len);
        parts[parts_index].iov_base = &pad;
        parts_index += 1;
    }

    assert(parts_index <= parts.len);

    _ = try file.writev(parts[0..parts_index]);
}

pub fn getAuth(allocator: *Allocator, sock: File, display: u32) !Auth {
    const xau_file = if (os.getenv("XAUTHORITY")) |xau_file_name| blk: {
        break :blk try fs.openFileAbsolute(xau_file_name, .{});
    } else blk: {
        const home = os.getenv("HOME") orelse return error.HomeDirectoryNotFound;
        var dir = try fs.cwd().openDir(home, .{});
        defer dir.close();

        break :blk try dir.openFile(".Xauthority", .{});
    };
    defer xau_file.close();

    const stream = &xau_file.reader();

    var hostname_buf: [os.HOST_NAME_MAX]u8 = undefined;
    const hostname = try os.gethostname(&hostname_buf);

    while (true) {
        var auth = blk: {
            const family = try stream.readIntBig(u16);
            const address = try readCountedString(allocator, stream);
            errdefer allocator.free(address);
            const number = try readCountedString(allocator, stream);
            errdefer allocator.free(number);
            const name = try readCountedString(allocator, stream);
            errdefer allocator.free(name);
            const data = try readCountedString(allocator, stream);
            errdefer allocator.free(data);

            break :blk Auth{
                .family = family,
                .address = address,
                .number = number,
                .name = name,
                .data = data,
            };
        };
        if (mem.eql(u8, hostname, auth.address)) {
            return auth;
        } else {
            auth.deinit(allocator);
            continue;
        }
    }

    return error.AuthNotFound;
}

fn readCountedString(allocator: *Allocator, stream: var) ![]u8 {
    const len = try stream.readIntBig(u16);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);

    try stream.readNoEof(buf);
    return buf;
}
