pub const X_PROTOCOL = 11;
pub const X_PROTOCOL_REVISION = 0;
pub const XSetupRequest = extern struct {
    byte_order: u8,
    pad0: u8,
    protocol_major_version: u16,
    protocol_minor_version: u16,
    authorization_protocol_name_len: u16,
    authorization_protocol_data_len: u16,
    pad1: [2]u8,
};
pub const XSetup = extern struct {
    release_number: u32,
    resource_id_base: u32,
    resource_id_mask: u32,
    motion_buffer_size: u32,
    vendor_len: u16,
    maximum_request_length: u16,
    roots_len: u8,
    pixmap_formats_len: u8,
    image_byte_order: u8,
    bitmap_format_bit_order: u8,
    bitmap_format_scanline_unit: u8,
    bitmap_format_scanline_pad: u8,
    min_keycode: XKeycode,
    max_keycode: XKeycode,
    pad1: [4]u8,
};
pub const XIdRangeRequest = extern struct {
    major_opcode: u8,
    minor_opcode: u8,
    length: u16,
};
pub const XKeycode = u8;
pub const XVisualId = u32;
pub const XWindow = u32;
pub const XCreateWindowRequest = extern struct {
    major_opcode: u8,
    depth: u8,
    length: u16,
    wid: XWindow,
    parent: XWindow,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
    class: u16,
    visual: XVisualId,
    value_mask: u32,
};
pub const XAttributeRequest = extern struct {
    major_opcode: u8,
    pad0: u8,
    length: u16,
    window: XWindow,
};
pub const XMapWindowRequest = extern struct {
    major_opcode: u8,
    pad0: u8,
    length: u16,
    window: XWindow,
};
pub const XFormat = extern struct {
    depth: u8,
    bits_per_pixel: u8,
    scanline_pad: u8,
    pad0: [5]u8,
};
pub const XScreen = extern struct {
    root: XWindow,
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
    root_visual: XVisualId,
    backing_store: u8,
    save_unders: u8,
    root_depth: u8,
    allowed_depths_len: u8,
};
pub const XDepth = extern struct {
    depth: u8,
    pad0: u8,
    visuals_len: u16,
    pad1: [4]u8,
};
pub const XVisualType = extern struct {
    visual_id: XVisualId,
    class: u8,
    bits_per_rgb_value: u8,
    colormap_entries: u16,
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    pad0: [4]u8,
};
pub const XValueError = extern struct {
    response_type: u8,
    error_code: u8,
    sequence: u16,
    bad_value: u32,
    minor_opcode: u16,
    major_opcode: u8,
    pad0: u8,
};
pub const XIdRangeReply = extern struct {
    response_type: u8,
    pad0: u8,
    sequence: u16,
    length: u32,
    start_id: u32,
    count: u32,
    pad1: [16]u8,
};
