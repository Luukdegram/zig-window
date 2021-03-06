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
usingnamespace @import("main.zig");
usingnamespace @import("event.zig");

pub const Display = struct {
    connection: Connection,
    handle: Screen,

    /// Creates a new window on this display
    pub fn createWindow(self: *Display, options: CreateWindowOptions) !Window {
        const connection = &self.connection;
        const screen: Screen = self.handle;
        const xid = try connection.getNewXid();
        const event_mask: u32 = X_BUTTON_PRESS | X_BUTTON_RELEASE | X_KEY_PRESS |
            X_KEY_RELEASE;

        const window_request = XCreateWindowRequest{
            .length = @sizeOf(XCreateWindowRequest) / 4 + 2,
            .wid = xid,
            .parent = screen.root,
            .width = options.width,
            .height = options.height,
            .visual = screen.root_visual,
            .value_mask = X_BACK_PIXEL | X_EVENT_MASK,
        };
        var parts: [4]os.iovec_const = undefined;
        parts[0].iov_base = @ptrCast([*]const u8, &window_request);
        parts[0].iov_len = @sizeOf(XCreateWindowRequest);
        parts[1].iov_base = @ptrCast([*]const u8, &screen.black_pixel);
        parts[1].iov_len = 4;
        parts[2].iov_base = @ptrCast([*]const u8, &event_mask);
        parts[2].iov_len = 4;

        const map_request = XMapWindowRequest{
            .length = @sizeOf(XMapWindowRequest) / 4,
            .window = xid,
        };
        parts[3].iov_base = @ptrCast([*]const u8, &map_request);
        parts[3].iov_len = @sizeOf(XMapWindowRequest);

        try connection.file.writevAll(&parts);

        const window = Window{ .handle = xid };

        try changeWindowProperty(connection, window, .Replace, 39, 31, .{ .string = std.mem.span(options.title) });
        return window;
    }
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
                if (!try supportsExtension(self, "XC-MISC")) {
                    return error.MiscUnsupported;
                }

                const xid_range_request = XIdRangeRequest{};
                var parts: [1]os.iovec_const = undefined;
                parts[0].iov_base = @ptrCast([*]const u8, &xid_range_request);
                parts[0].iov_len = @sizeOf(XIdRangeRequest);

                _ = try self.file.writev(&parts);
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

/// Makes a connection with the X11 server and returns a list
/// of displays.
pub fn getDisplayList(allocator: *Allocator) ![]Display {
    var connection = try getDefaultDisplay(allocator);

    var display_list = std.ArrayList(Display).init(allocator);
    errdefer display_list.deinit();

    for (connection.screens) |screen| {
        try display_list.append(.{
            .connection = connection,
            .handle = screen,
        });
    }
    return display_list.toOwnedSlice();
}

pub fn getDefaultDisplay(allocator: *Allocator) !Connection {
    const default_name = getDefaultDisplayName() orelse return error.UnknownDefaultDisplay;
    return openDisplay(allocator, default_name);
}

pub fn getDefaultDisplayName() ?[]const u8 {
    return os.getenv("DISPLAY");
}

pub const Window = struct {
    handle: u32,
};

/// Creates a new context and returns its id
fn createContext(connection: *Connection, root: u32, mask: u32, values: []u32) !u32 {
    const xid = try connection.getNewXid();

    const request = XCreateGCRequest{
        .length = @sizeOf(XCreateGCRequest) / 4 + @intCast(u16, values.len),
        .cid = xid,
        .drawable = root,
        .mask = mask,
    };

    var parts = std.ArrayList(os.iovec_const).init(connection.allocator);
    errdefer parts.deinit();

    try parts.append(.{
        .iov_base = @ptrCast([*]const u8, &request),
        .iov_len = @sizeOf(XCreateGCRequest),
    });

    for (values) |val| {
        try parts.append(.{
            .iov_base = @ptrCast([*]const u8, &val),
            .iov_len = 4,
        });
    }

    try connection.file.writevAll(parts.toOwnedSlice());

    return xid;
}

/// Checks if the X11 server supports the given extension or not
fn supportsExtension(connection: *Connection, ext_name: []const u8) !bool {
    const request = XQueryExtensionRequest{
        .length = @intCast(u16, @sizeOf(XQueryExtensionRequest) + ext_name.len + xpad(ext_name.len)) / 4,
        .name_len = @intCast(u16, ext_name.len),
    };
    var parts: [3]os.iovec_const = undefined;
    parts[0].iov_base = @ptrCast([*]const u8, &request);
    parts[0].iov_len = @sizeOf(XQueryExtensionRequest);
    parts[1].iov_base = ext_name.ptr;
    parts[1].iov_len = ext_name.len;
    parts[2].iov_base = &request.pad1;
    parts[2].iov_len = xpad(ext_name.len);

    try connection.file.writevAll(&parts);
    const reply = try connection.file.reader().readStruct(XQueryExtensionReply);

    return reply.present != 0;
}

/// Waits for an event to occur. This function is blocking
fn waitForEvent(connection: *Connection) !Event {
    var event: ?Event = null;
    while (event == null) {
        var bytes: [32]u8 = undefined;
        const length = try connection.file.reader().readAll(&bytes);

        // assure the reply we receive is an event
        if (bytes[0] == 2) {
            event = Event.fromBytes(bytes) catch |err| switch (err) {
                error.NotAnEvent => continue,
                else => return err,
            };
        }
    }

    return event.?;
}

/// The mode you want to change the window property
/// For example, to append to the window title you use .Append
pub const PropertyMode = enum(u8) {
    Replace,
    Prepend,
    Append,
};

/// Property is a union which can be used to change
/// a window property
/// TODO: Add more properties that can be modified. For now it's only
/// `STRING` and `INTEGER`.
const Property = union(enum) {
    int: u32,
    string: []const u8,

    /// Returns a pointer to the underlaying data
    /// Note that for union Int it first converts it to a byte slice,
    /// and then returns to pointer to that slice
    fn ptr(self: Property) [*]const u8 {
        return switch (self) {
            .int => |int| @ptrCast([*]const u8, &std.mem.toBytes(int)),
            .string => |array| array.ptr,
        };
    }

    /// Returns the length of the underlaying data,
    /// Note that for union Int it first converts it to a byte slice,
    /// and then returns the length of that
    fn len(self: Property) u32 {
        return switch (self) {
            .int => |int| std.mem.toBytes(int).len,
            .string => |array| @intCast(u32, array.len),
        };
    }
};

/// Allows to change a window property using the given parameters
/// such as the window title
fn changeWindowProperty(
    connection: *Connection,
    window: Window,
    mode: PropertyMode,
    property: u32,
    prop_type: u32,
    data: Property,
) !void {
    const pad = [3]u8{ 0, 0, 0 };
    const data_ptr = data.ptr();
    const data_len = data.len();
    const total_length: u16 = @intCast(u16, @sizeOf(XChangePropertyRequest) + data_len + xpad(data_len)) / 4;

    const request = XChangePropertyRequest{
        .mode = @enumToInt(mode),
        .length = total_length,
        .window = window.handle,
        .property = property,
        .prop_type = prop_type,
        .pad0 = pad,
        .data_len = data_len,
    };

    var parts: [3]os.iovec_const = undefined;
    parts[0].iov_base = @ptrCast([*]const u8, &request);
    parts[0].iov_len = @sizeOf(XChangePropertyRequest);
    parts[1].iov_base = data_ptr;
    parts[1].iov_len = data_len;
    parts[2].iov_base = &pad;
    parts[2].iov_len = xpad(data_len);

    try connection.file.writevAll(&parts);
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

    if (host.len != 0) {
        const port: u16 = 6000 + @intCast(u16, display);
        const address = try std.net.Address.parseIp(host, port);
        return std.net.tcpConnectToAddress(address);
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
    depths: []Depth,
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
            .scanline_pad = format.scanline_pad,
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
                .visual_types = visual_types.toOwnedSlice(),
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
            .depths = depths.toOwnedSlice(),
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

    return file.writevAll(parts[0..parts_index]);
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
