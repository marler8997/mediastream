const builtin = @import("builtin");
const std = @import("std");
const os = std.os;
const x = @import("x");
const common = @import("common.zig");
const video4linux2 = @import("video4linux2.zig");
const Memfd = x.Memfd;
const ContiguousReadBuffer = x.ContiguousReadBuffer;
const convert = @import("convert.zig");

const global = struct {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    pub const arena = arena_instance.allocator();
    var gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    pub const gpa = gpa_instance.allocator();
};

const window_width = 800;
const window_height = 400;

const Key = union(enum) {
    text: u8, // the ascii code
    enter: void,
    escape: void,
};

pub const Ids = struct {
    base: u32,
    pub fn window(self: Ids) u32 { return self.base; }
    pub fn bg_gc(self: Ids) u32 { return self.base + 1; }
    pub fn fg_gc(self: Ids) u32 { return self.base + 2; }
    pub fn backbuffer(self: Ids) u32 { return self.base + 3; }
};
const Dbe = struct { opcode: u8 };

fn addKeysymText(map: *std.AutoHashMapUnmanaged(x.charset.Combined, Key), c: x.charset.Latin1) !void {
    try map.put(global.gpa, c.toCombined(), .{ .text = @enumToInt(c) });
}

pub fn main() !u8 {
    const conn = try common.connect(global.arena);
    defer os.shutdown(conn.sock, .both) catch {};

    var keycode_map = std.AutoHashMapUnmanaged(u8, Key){};
    {
        var keysyms_of_interest = std.AutoHashMapUnmanaged(x.charset.Combined, Key){};
        defer keysyms_of_interest.deinit(global.gpa);
        try addKeysymText(&keysyms_of_interest, .space);
        {
            var c = x.charset.Latin1.a;
            while (true) : (c = c.next()) {
                try addKeysymText(&keysyms_of_interest, c);
                if (c == x.charset.Latin1.z) break;
            }
        }
        {
            var c = x.charset.Latin1.digit_zero;
            while (true) : (c = c.next()) {
                try addKeysymText(&keysyms_of_interest, c);
                if (c == x.charset.Latin1.digit_nine) break;
            }
        }
        try keysyms_of_interest.put(global.gpa, x.charset.Keyboard.return_enter.toCombined(), Key.enter);
        try keysyms_of_interest.put(global.gpa, x.charset.Keyboard.escape.toCombined(), Key.escape);

        const keymap = try x.keymap.request(global.gpa, conn.sock, conn.setup.fixed().*);
        defer keymap.deinit(global.gpa);
        std.log.info("Keymap: syms_per_code={} total_syms={}", .{keymap.syms_per_code, keymap.syms.len});
        {
            var i: usize = 0;
            var sym_offset: usize = 0;
            while (i < keymap.keycode_count) : (i += 1) {
                const keycode = @intCast(u8, conn.setup.fixed().min_keycode + i);

                // for now we'll just look at the first keysym,
                // the others I believe are modifiers for things like shift
                const first_sym_u32 = keymap.syms[sym_offset];
                if ((first_sym_u32 & 0xffff0000) == 0) {
                    const first_sym = @intToEnum(x.charset.Combined, first_sym_u32);
                    //std.log.info("keycode {} first_sym is 0x{x}", .{keycode, first_sym});
                    if (keysyms_of_interest.get(first_sym)) |key| {
                        std.log.info("keycode {} maps to {s}", .{keycode, @tagName(first_sym)});
                        try keycode_map.put(global.arena, keycode, key);
                    } else {
                        std.log.info("keycode {} maps to non-interested sym {}", .{keycode, first_sym});
                    }
                }
//                var j: usize = 0;
//                while (j < keymap.syms_per_code) : (j += 1) {
//                    const sym = keymap.syms[sym_offset];
//                    if (sym_key_map.get(sym)) |key| {
//                        try keycode_map.put(allocator, keycode, key);
//                    }
//                    sym_offset += 1;
//                }
                sym_offset += 7;
            }
            std.debug.assert(sym_offset == keymap.syms.len);
        }
    }

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{ field.name, @field(fixed, field.name) });
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{ format_list_offset, format_list_limit });
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{ i, format.depth, format.bits_per_pixel, format.scanline_pad });
        }
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{ field.name, @field(screen, field.name) });
        }
        break :blk screen;
    };

    // TODO: maybe need to call conn.setup.verify or something?

    const ids = Ids{ .base = conn.setup.fixed().resource_id_base };
    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = ids.window(),
            .parent_window_id = screen.root,
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
            //            .bg_pixmap = .copy_from_parent,
            //.bg_pixel = 0xaabbccdd,
            .bg_pixel = 0x333333,
            //            //.border_pixmap =
            //            .border_pixel = 0x01fa8ec9,
            //            .bit_gravity = .north_west,
            //            .win_gravity = .east,
            //            .backing_store = .when_mapped,
            //            .backing_planes = 0x1234,
            //            .backing_pixel = 0xbbeeeeff,
            //            .override_redirect = true,
            //            .save_under = true,
            .event_mask = x.event.key_press | x.event.key_release | x.event.button_press | x.event.button_release | x.event.enter_window | x.event.leave_window | x.event.pointer_motion
            //                | x.event.pointer_motion_hint WHAT THIS DO?
            //                | x.event.button1_motion  WHAT THIS DO?
            //                | x.event.button2_motion  WHAT THIS DO?
            //                | x.event.button3_motion  WHAT THIS DO?
            //                | x.event.button4_motion  WHAT THIS DO?
            //                | x.event.button5_motion  WHAT THIS DO?
            //                | x.event.button_motion  WHAT THIS DO?
            | x.event.keymap_state | x.event.exposure,
            //            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    const bg_color = 0x333333;

    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.bg_gc(),
            .drawable_id = screen.root,
       }, .{
            .foreground = bg_color,
        });
        try conn.send(msg_buf[0..len]);
    }


    {
        var msg_buf: [x.create_gc.max_len]u8 = undefined;
        const len = x.create_gc.serialize(&msg_buf, .{
            .gc_id = ids.fg_gc(),
            .drawable_id = screen.root,
        }, .{
            //.background = screen.black_pixel,
            .background = bg_color,
            //.foreground = 0xffaadd,
            .foreground = 0xcccccc,
        });
        try conn.send(msg_buf[0..len]);
    }

    const buf_memfd = try Memfd.init("ZigX11DoubleBuffer");
    // no need to deinit
    const buffer_capacity = std.mem.alignForward(1000, std.mem.page_size);
    std.log.info("buffer capacity is {}", .{buffer_capacity});
    var buf = ContiguousReadBuffer{ .double_buffer_ptr = try buf_memfd.toDoubleBuffer(buffer_capacity), .half_size = buffer_capacity };

    {
        var msg: [x.query_extension.getLen(x.dbe.name.len)]u8 = undefined;
        x.query_extension.serialize(&msg, x.dbe.name);
        try conn.send(&msg);
    }
    var optional_dbe: ?Dbe = null;
    {
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.ServerMsg.QueryExtension, msg_reply);
                if (msg.present == 0) {
                    std.log.info("'{s}' extension is NOT present", .{x.dbe.name.nativeSlice()});
                } else {
                    std.log.info("'{s}' extension is present", .{x.dbe.name.nativeSlice()});
                    optional_dbe = Dbe{ .opcode = msg.major_opcode };
                }
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    }

    if (optional_dbe) |dbe| {
        {
            var msg: [x.dbe.get_version.len]u8 = undefined;
            x.dbe.get_version.serialize(&msg, .{
                .ext_opcode = dbe.opcode,
                .wanted_major_version = 1,
                .wanted_minor_version = 0,
            });
            try conn.send(&msg);
        }
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.dbe.get_version.Reply, msg_reply);
                if (msg.major_version != 1) {
                    std.log.info("the '{s}' extension is too new (need 1 got {})", .{x.dbe.name.nativeSlice(), msg.major_version});
                    optional_dbe = null;
                } else {
                    std.log.info("'{s}' extension is at version {}.{}", .{x.dbe.name.nativeSlice(), msg.major_version, msg.minor_version});
                }
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    }

    if (optional_dbe) |dbe| {
        var msg: [x.dbe.allocate.len]u8 = undefined;
        x.dbe.allocate.serialize(&msg, .{
            .ext_opcode = dbe.opcode,
            .window = ids.window(),
            .backbuffer = ids.backbuffer(),
            .swapaction = .dontcare,
        });
        try conn.send(&msg);
    }



    // get some font information
    {
        const text_literal = [_]u16{'m'};
        const text = x.Slice(u16, [*]const u16){ .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, ids.fg_gc(), text);
        try conn.send(&msg);
    }
    const font_dims: FontDims = blk: {
        _ = try x.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x.ServerMsg.QueryTextExtents, msg_reply);
                break :blk .{
                    .width = @intCast(u8, msg.overall_width),
                    .height = @intCast(u8, msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(i16, msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    };

    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, ids.window());
        try conn.send(&msg);
    }

    var state = State{
        .cmd = .{},
        .main = .{
            .show_devices = .{
                .video_devs = try getVideoDevs(global.gpa),
            },
        },
    };

    const max_request_len = @intCast(u18, conn.setup.fixed().max_request_len) * 4;
    std.log.info("maximum request length is {} bytes", .{max_request_len});
    while (true) {
        var poll_fd_buf: [2]os.pollfd = undefined;
        poll_fd_buf[0] = .{
            .fd = conn.sock,
            .events = os.POLL.IN,
            .revents = undefined,
        };
        var poll_fd_count: usize = 1;

        const optional_video: ?struct { capture: Capture, opt_frame_ref: *?CapturedRgbFrame } = switch (state.main) {
            .show_devices => null,
            .device => |*dev| if (dev.capture) |c| .{
                .capture = c, .opt_frame_ref = &dev.last_frame
            } else null,
        };
        if (optional_video) |video| {
            poll_fd_buf[poll_fd_count] = .{
                .fd = video.capture.fd,
                .events = os.POLL.IN,
                .revents = undefined,
            };
            poll_fd_count += 1;
        }

        const fd_ready = try os.poll(poll_fd_buf[0 .. poll_fd_count], -1);

        var fd_processed: usize = 0;

        // NOTE: we check the video device before the x11 socket because
        //       it changes less state and is less likely to invalidate
        //       the x11 read.  If we did the X11 read first it could close
        //       the capture.
        if (optional_video) |video| {
            if (fd_processed < fd_ready and poll_fd_buf[1].revents != 0) {
                switch (try onVideo(video.capture, video.opt_frame_ref)) {
                    .no_frame => {},
                    .got_frame => {
                        try render(conn.sock, max_request_len, ids, optional_dbe, font_dims, &state);
                    },
                }
                fd_processed += 1;
            }
        }

        if (fd_processed < fd_ready and poll_fd_buf[0].revents != 0) {
            try onX11Read(conn.sock, keycode_map, ids, max_request_len, &buf, optional_dbe, font_dims, &state);
            fd_processed += 1;
        }

        std.debug.assert(fd_ready == fd_processed);
    }
}

fn onVideo(capture: Capture, opt_frame_ref: *?CapturedRgbFrame) !enum { got_frame, no_frame } {
    var buf = std.mem.zeroes(video4linux2.Buffer);
    {
        buf.buf_type = .video_capture;
        buf.memory = .mmap;
        switch (os.errno(video4linux2.ioctl.dqbuf(capture.fd, &buf))) {
            .SUCCESS => {},
            .AGAIN => return .no_frame,
            // TODO: handle errors?
            else => |errno| std.debug.panic("VIDIOC_DQBUF failed, error={}", .{errno}),
        }
    }

    // we currently only use 1 buffer which will always be index 0
    std.debug.assert(buf.index == 0);

    //std.log.info("got frame!", .{});
    const mem = capture.mmaps[buf.index];
    std.debug.assert(buf.length == mem.len);


    const rgb_len = capture.width * capture.height * 4;
    if (opt_frame_ref.*) |frame| {
        if (frame.mem.len != buf.length) {
            global.gpa.free(frame.mem);
            opt_frame_ref.* = null;
        }
    }
    if (opt_frame_ref.* == null) {
        opt_frame_ref.* = .{
            .width = capture.width,
            .height = capture.height,
            .mem = try global.gpa.alloc(u8, rgb_len),
        };
    }

    switch (capture.format) {
        .yuyv => convert.yuyvToRgb(
            opt_frame_ref.*.?.mem.ptr,
            capture.width * 4,
            mem.ptr,
            capture.stride,
            capture.width,
            capture.height),
        .unknown =>
            // just copy it in there as is, we'll see "something"
            @memcpy(opt_frame_ref.*.?.mem.ptr, mem.ptr, std.math.min(mem.len, rgb_len)),
    }


    try v4l2QueueBuf(capture.fd, buf.index);
    return .got_frame;
}

fn onX11Read(
    sock: os.socket_t,
    keycode_map: std.AutoHashMapUnmanaged(u8, Key),
    ids: Ids,
    max_request_len: u18,
    buf: *ContiguousReadBuffer,
    optional_dbe: ?Dbe,
    font_dims: FontDims,
    state: *State,
) !void {
    {
        const recv_buf = buf.nextReadBuffer();
        if (recv_buf.len == 0) {
            std.debug.panic("buffer size {} not big enough!", .{buf.half_size});
        }
        const len = try os.recv(sock, recv_buf, 0);
        if (len == 0) {
            std.log.info("X server connection closed", .{});
            os.exit(0);
        }
        buf.reserve(len);
    }
    while (true) {
        const data = buf.nextReservedBuffer();
        const msg_len = x.parseMsgLen(@alignCast(4, data));
        if (msg_len == 0)
            break;
        buf.release(msg_len);
        //buf.resetIfEmpty();
        switch (x.serverMsgTaggedUnion(@alignCast(4, data.ptr))) {
            .err => |msg| {
                std.debug.panic("{}", .{msg});
            },
            .reply => |msg| {
                std.log.info("todo: handle a reply message {}", .{msg});
                return error.TodoHandleReplyMessage;
            },
            .key_press => |msg| {
                if (keycode_map.get(msg.keycode)) |key| switch (key) {
                    .text => |ascii| {
                        std.log.info("key_press: ascii '{c}' ({0})", .{ascii});
                        if (state.cmd.append(ascii)) {
                            try render(sock, max_request_len, ids, optional_dbe, font_dims, state);
                        } else {
                            // TODO: show something on the UI
                            std.log.warn("command buffer is full", .{});
                        }
                    },
                    .enter => {
                        const cmd = state.cmd.slice();
                        if (std.mem.eql(u8, cmd, "r")) {
                            try handleRCommand(state);
                        } else if (std.mem.eql(u8, cmd, "b")) {
                            try handleBCommand(state);
                        } else if (std.mem.eql(u8, cmd, "p")) {
                            try handlePCommand(state);
                        } else if (std.fmt.parseInt(u32, cmd, 10)) |int| {
                            try handleIntegerCommand(state, int);
                        } else |_| {
                            // TODO: show something in the UI
                            std.log.info("unknown command '{s}'", .{cmd});
                        }
                        state.cmd.len = 0;
                        try render(sock, max_request_len, ids, optional_dbe, font_dims, state);
                    },
                    .escape => {
                        std.log.info("quitting from ESC", .{});
                        std.os.exit(0);
                    },
                } else {
                    std.log.info("key_press: unhandled keycode {}", .{msg.keycode});
                }
            },
            .key_release => |msg| {
                _ = msg;
                //std.log.info("key_release: {}", .{msg.keycode});
            },
            .button_press => |msg| {
                std.log.info("button_press: {}", .{msg});
            },
            .button_release => |msg| {
                std.log.info("button_release: {}", .{msg});
            },
            .enter_notify => |msg| {
                std.log.info("enter_window: {}", .{msg});
            },
            .leave_notify => |msg| {
                std.log.info("leave_window: {}", .{msg});
            },
            .motion_notify => |msg| {
                // too much logging
                _ = msg;
                //std.log.info("pointer_motion: {}", .{msg});
            },
            .keymap_notify => |msg| {
                std.log.info("keymap_state: {}", .{msg});
            },
            .expose => |msg| {
                std.log.info("expose: {}", .{msg});
                try render(sock, max_request_len, ids, optional_dbe, font_dims, state);
            },
            .unhandled => |msg| {
                std.log.info("todo: server msg {}", .{msg});
                return error.UnhandledServerMsg;
            },
        }
    }
}

fn handleRCommand(state: *State) !void {
    switch(state.main) {
        .show_devices => |*show| {
            std.log.info("refreshing video dev list...", .{});
            const new_video_devs = try getVideoDevs(global.gpa);
            for (show.video_devs.items) |*video_dev| {
                video_dev.deinit(global.gpa);
            }
            show.video_devs.deinit(global.gpa);
            show.video_devs = new_video_devs;
        },
        .device => {
            // TODO: show error to user
            std.log.err("the 'r' command does nothing in this state", .{});
        },
    }
}
fn handleBCommand(state: *State) !void {
    switch(state.main) {
        .show_devices => {
            // TODO: show error to user
            std.log.err("the 'b' command does nothing in this state", .{});
        },
        .device => |*dev| {
            if (dev.last_frame) |last_frame| {
                last_frame.deinit();
            }
            if (dev.capture) |capture| {
                capture.deinit();
            }
            state.main = .{ .show_devices = .{
                .video_devs = dev.video_devs,
            }};
        },
    }
}
fn handlePCommand(state: *State) !void {
    switch(state.main) {
        .show_devices => {
            // TODO: show error to user
            std.log.err("the 'p' command does nothing in this state", .{});
        },
        .device => |*dev| {
            if (dev.capture) |_| {
                // TODO: show error to user
                std.log.err("it seems we are already capturing?", .{});
                return;
            }
            dev.capture = startPreview(dev.video_devs.items[dev.device_index]) catch |err| switch (err) {
                error.Reported => return,
                else => |e| return e,
            };
        },
    }
}

fn handleIntegerCommand(state: *State, int: u32) !void {
    switch(state.main) {
        .show_devices => |*show| {
            for (show.video_devs.items) |*video_dev, video_dev_index| {
                if (video_dev.minor == int) {
                    if (!video_dev.mightHaveCapture()) {
                        // TODO: show this error to the user
                        std.log.err("video device does not support capture", .{});
                        return;
                    }

                    state.main = .{ .device = .{
                        .video_devs = show.video_devs,
                        .device_index = video_dev_index,
                        .capture = null,
                        .last_frame = null,
                    }};
                    return;
                }
            }
            // TODO: update the UI state to show this error
            std.log.info("device '{}' does not exist", .{int});
        },
        .device => {
            // TODO update UI state to show this error
            std.log.err("integer command '{}' does nothing in this state", .{int});
        },
    }
}

fn startPreview(video_dev: VideoDev) !Capture {
    const dev_path = video_dev.optional_device_path orelse {
        // TODO: show error to user
        std.log.err("video4linux2 device with minor {} has no device file", .{video_dev.minor});
        return error.Reported;
    };
    const cap = switch (video_dev.cap) {
        .fail => |e| {
            // TODO: show error to user
            std.log.err("video4linux2 device with minor {} had a querycap error {}", .{video_dev.minor, e});
            return error.Reported;
        },
        .success => |*cap| cap,
    };
    var fd = try os.openZ(dev_path, os.O.RDWR | os.O.NONBLOCK | os.O.CLOEXEC, 0);
    defer if (fd != -1) os.close(fd);

    std.log.warn("TODO! verify the device file we just opened is still what we expect", .{});
    _ = cap;

    var format: video4linux2.Format = undefined;
    format.buf_type = .video_capture;
    switch (os.errno(video4linux2.ioctl.g_fmt(fd, &format))) {
        .SUCCESS => {},
        else => |errno| {
            // TODO: show error to user
            std.log.err("failed to get device format, error={}", .{errno});
            return error.Reported;
        },
    }
    const fourcc = FourCC.initRef(&format.fmt.pix.pixelformat);
    std.log.info("format is '{s}' {}", .{fourcc.chars, format.fmt.pix});
    const cap_format: CaptureFormat = blk: {
        if (fourcc.val == FourCC.initCt("YUYV").val)
            break :blk .yuyv;

        // TODO: show error to user
        std.log.info("format '{s}' is not supported yet", .{fourcc.chars});
        break :blk .unknown;
    };

    // call S_FMT so we *might* get ownership?
    switch (os.errno(video4linux2.ioctl.s_fmt(fd, &format))) {
        .SUCCESS => {},
        .BUSY => {
            // TODO: show error to user
            std.log.err("device is busy (on VIDIOC_S_FMT)", .{});
            return error.Reported;
        },
        else => |errno| {
            // TODO: show error to user
            std.log.err("failed to set device format, error={}", .{errno});
            return error.Reported;
        },
    }

    // TODO: verify the device capabilities include streaming?
    {
        var req = video4linux2.Requestbuffers{
            .count = 1,
            .buf_type = .video_capture,
            .memory = .mmap,
            .capabilities = 0,
            .flags = 0,
        };
        switch (os.errno(video4linux2.ioctl.reqbufs(fd, &req))) {
            .SUCCESS => {},
            .BUSY => {
                // TODO: show error to user
                std.log.err("device is busy (on VIDIOC_REQBUFS)", .{});
                return error.Reported;
            },
            else => |errno| {
                // TODO: show error to user
                std.log.err("VIDIOC_REQBUFS failed, error={}", .{errno});
                return error.Reported;
            },
        }
        if (req.count != 1) {
            // TODO: show error to user
            std.log.err("VIDIOC_REQBUFS returned no buffers", .{});
            return error.Reported;
        }
    }

    var buf = std.mem.zeroes(video4linux2.Buffer);
    buf.buf_type = .video_capture;
    buf.memory = .mmap;
    switch (os.errno(video4linux2.ioctl.querybuf(fd, &buf))) {
        .SUCCESS => {},
        .BUSY => {
            // TODO: show error to user
            std.log.err("device is busy (on VIDIOC_QUERYBUF)", .{});
            return error.Reported;
        },
        else => |errno| {
            // TODO: show error to user
            std.log.err("VIDIOC_QUERYBUF failed, error={}", .{errno});
            return error.Reported;
        },
    }
    std.log.info("buffer len={} offset={}", .{buf.length, buf.m.offset});
    errdefer v4l2ReleaseBuffers(fd);

    const ptr = os.mmap(
        null,
        buf.length,
        os.PROT.READ | os.PROT.WRITE,
        os.MAP.SHARED,
        fd,
        buf.m.offset,
    ) catch |err| {
        // TODO: show error to user
        std.log.err("mmap video buffer failed, error={s}", .{@errorName(err)});
        return error.Reported;
    };
    errdefer os.munmap(ptr[0..buf.length]);

    v4l2QueueBuf(fd, 0) catch |err| switch (err) {
        error.DeviceBusy => {
            // TODO: show error to user
            std.log.err("device is busy (on VIDIOC_QBUF)", .{});
            return error.Reported;
        },
    };

    {
        const buf_type = video4linux2.BufType.video_capture;
        switch (os.errno(video4linux2.ioctl.streamon(fd, &buf_type))) {
            .SUCCESS => {},
            .BUSY => {
                // TODO: show error to user
                std.log.err("device is busy (on VIDIOC_STREAMON)", .{});
                return error.Reported;
            },
            else => |errno| {
                // TODO: show error to user
                std.log.err("VIDIOC_STREAMON failed, error={}", .{errno});
                return error.Reported;
            },
        }
    }

    const capture_fd = fd;
    fd = -1; // transferring ownership to return value
    return Capture{
        .fd = capture_fd,
        .width = format.fmt.pix.width,
        .height = format.fmt.pix.height,
        .stride = format.fmt.pix.bytesperline,
        .format = cap_format,
        .mmaps = [capture_buf_count][]u8 {
            ptr[0 .. buf.length],
        },
    };
}

fn v4l2QueueBuf(fd: os.fd_t, index: u32) error{DeviceBusy}!void {
    var buf = std.mem.zeroes(video4linux2.Buffer);
    buf.buf_type = .video_capture;
    buf.memory = .mmap;
    buf.index = index;
    switch (os.errno(video4linux2.ioctl.qbuf(fd, &buf))) {
        .SUCCESS => {},
        .BUSY => return error.DeviceBusy,
        // TODO: what other kinds of error can happen? for now just panic
        else => |errno|
            std.debug.panic("VIDIOC_QBUF failed, error={}", .{errno}),
    }
}

fn v4l2ReleaseBuffers(fd: os.fd_t) void {
    var req = video4linux2.Requestbuffers{
        .count = 0,
        .buf_type = .video_capture,
        .memory = .mmap,
        .capabilities = 0,
        .flags = 0,
    };
    switch (os.errno(video4linux2.ioctl.reqbufs(fd, &req))) {
        .SUCCESS => {},
        else => |errno|
            // not sure if this is OK or not, panic for now until
            // I see this happen and find out what to do here
            std.debug.panic("VIDIOC_REQBUFS for release failed, error={}", .{errno}),
    }
}

fn ZStringFixedCap(comptime capacity: comptime_int) type {
    return struct {
        pub const Len = std.math.IntFittingRange(0, capacity);

        buf: [capacity + 1]u8 = [1]u8 { 0 } ++ ([1]u8 { undefined } ** capacity),
        len: Len = 0,

        const Self = @This();
        pub fn init(src: [capacity]u8) Self {
            var result = Self{
                .buf = undefined,
                .len = @intCast(Len, std.mem.indexOfScalar(u8, &src, 0) orelse capacity),
            };
            @memcpy(&result.buf, &src, result.len);
            result.buf[result.len] = 0;
            return result;
        }
        pub fn slice(self: *Self) [:0]u8 {
            return self.buf[0 .. self.len :0];
        }
        pub fn sliceConst(self: *const Self) [:0]const u8 {
            return self.buf[0 .. self.len :0];
        }
    };
}

const FourCC = extern union {
    chars: [4]u8,
    val: u32,

    comptime {
        std.debug.assert(@sizeOf(FourCC) == 4);
    }
    pub fn initCt(comptime s: *const [4]u8) FourCC {
        return .{ .chars = s.* };
    }
    pub fn initRef(u32_ref: *const u32) *const FourCC {
        comptime std.debug.assert(@alignOf(FourCC) <= @alignOf(u32));
        return @ptrCast(*const FourCC, u32_ref);
    }
};

const VideoDev = struct {
    minor: u32,
    optional_device_path: ?[:0]const u8,
    cap: union(enum) {
        fail: struct {
            errno: os.E,
        },
        success: struct {
            card: ZStringFixedCap(32),
            bus_info: ZStringFixedCap(32),
            enum_format_errno: ?os.E,
            formats: []const FourCC,
        },
    },
    pub fn deinit(self: VideoDev, allocator: std.mem.Allocator) void {
        if (self.optional_device_path) |path| {
            allocator.free(path);
        }
        switch (self.cap) {
            .success => |*cap| {
                allocator.free(cap.formats);
            },
            .fail => {},
        }
    }
    pub fn mightHaveCapture(self: VideoDev) bool {
        switch (self.cap) {
            .fail => return true,
            .success => |*cap| {
                if (cap.formats.len > 0) return true;
                if (cap.enum_format_errno != null) return true;
                return false;
            },
        }
    }
    pub fn lessThan(context: void, lhs: VideoDev, rhs: VideoDev) bool {
        _ = context;
        return lhs.minor < rhs.minor;
    }
};

fn createVideoDev(allocator: std.mem.Allocator, entry: video4linux2.DeviceFiles.Entry) !VideoDev {
    const path = try entry.allocPathZ(allocator);
    errdefer allocator.free(path);

    const fd = try os.openZ(path, os.O.RDONLY, 0);
    defer os.close(fd);

    var capability: video4linux2.Capability = undefined;
    switch (os.errno(video4linux2.ioctl.querycap(fd, &capability))) {
        .SUCCESS => {},
        os.E.NODEV => return error.NoDevice,
        else => |e| return VideoDev{
            .minor = entry.minor,
            .optional_device_path = path,
            .cap = .{ .fail = .{ .errno = e } },
        },
    }

    var formats = std.ArrayListUnmanaged(FourCC){ };
    errdefer formats.deinit(allocator);

    var enum_format_errno: ?os.E = null;
    {
        var format_index: u32 = 0;
        format_loop: while (true) : (format_index += 1) {
            var format: video4linux2.Fmtdesc = undefined;
            format.buf_type = .video_capture;
            format.index = format_index;
            switch (os.errno(video4linux2.ioctl.enum_fmt(fd, &format))) {
                .SUCCESS => {
                    const fourcc_ptr = FourCC.initRef(&format.pixelformat);
                    try formats.append(allocator, fourcc_ptr.*);
                },
                os.E.INVAL => break :format_loop,
                else => |e| {
                    enum_format_errno = e;
                    break :format_loop;
                },
            }
        }
    }

    return VideoDev{
        .minor = entry.minor,
        .optional_device_path = path,
        .cap = .{ .success = .{
            .card = ZStringFixedCap(32).init(capability.card),
            .bus_info = ZStringFixedCap(32).init(capability.bus_info),
            .enum_format_errno = enum_format_errno,
            .formats = formats.toOwnedSlice(allocator),
        }},
    };
}

fn getVideoDevs(allocator: std.mem.Allocator) !std.ArrayListUnmanaged(VideoDev) {
    var devices = std.ArrayListUnmanaged(VideoDev){ };
    errdefer {
        for (devices.items) |*device| {
            device.deinit(allocator);
        }
        devices.deinit(allocator);
    }

    {
        var device_files = try video4linux2.DeviceFiles.open();
        defer device_files.close();
        var it = device_files.iterate();
        while (try it.next()) |entry| {
            //std.log.info("/dev/{s}: minor={}", .{ entry.base_name, entry.minor });
            const video_dev = createVideoDev(allocator, entry) catch |err| switch (err) {
                error.FileNotFound => continue,
                error.NoDevice => {
                    std.log.info("/dev/{s} has no underlying device", .{entry.base_name});
                    continue;
                },
                else => |e| return e,
            };

            // I believe the minor number could be used to correletate the entry
            // with the sysfs entry reported by the kernel
            try devices.append(allocator, video_dev);
        }
    }

    // add any video4linux2 devices reported by the kernel that
    // we couldn't find device files for
    {
        var kernel_devices = try video4linux2.KernelDevices.init();
        defer kernel_devices.deinit();
        var it = kernel_devices.iterate();
        while (try it.next()) |num| {
            var found = false;
            for (devices.items) |dev| {
                if (dev.minor == num) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                std.log.info("kernel reports video4linux2 device 'video{}' but it has no device file", .{num});
                try devices.append(allocator, VideoDev{
                    .minor = num,
                    .optional_device_path = null, // no device file
                    .cap = .{ .fail = .{ .errno = os.E.NOENT } },
                });
            }
        }
    }

    std.sort.sort(VideoDev, devices.items, {}, VideoDev.lessThan);

    return devices;
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

const capture_buf_count = 1;
const CaptureFormat = enum {
    yuyv,
    unknown,
};
const Capture = struct {
    fd: os.fd_t,
    width: u32,
    height: u32,
    stride: u32,
    format: CaptureFormat,
    mmaps: [capture_buf_count][]align(std.mem.page_size) u8,
    pub fn deinit(self: Capture) void {
        for (self.mmaps) |mmap| {
            os.munmap(mmap);
        }
    }
};

const CapturedRgbFrame = struct {
    mem: []u8,
    width: u32,
    height: u32,
    pub fn deinit(self: CapturedRgbFrame) void {
        global.gpa.free(self.mem);
    }
};

const State = struct {
    cmd: Cmd,
    main: union(enum) {
        show_devices: struct {
            video_devs: std.ArrayListUnmanaged(VideoDev),
        },
        device: struct {
            video_devs: std.ArrayListUnmanaged(VideoDev),
            device_index: usize,
            capture: ?Capture,
            last_frame: ?CapturedRgbFrame,
        },
    },

    pub const Cmd = struct {
        const buf_len = 100;
        const Len = std.math.IntFittingRange(0, buf_len);
        buf: [100]u8 = undefined,
        len: Len = 0,
        pub fn slice(self: *Cmd) []u8 {
            return self.buf[0 .. self.len];
        }
        pub fn append(self: *Cmd, ascii: u8) bool {
            if (self.len == self.buf.len) return false;
            self.buf[self.len] = ascii;
            self.len += 1;
            return true;
        }
    };
};

fn render(
    sock: os.socket_t,
    max_request_len: u18,
    ids: Ids,
    optional_dbe: ?Dbe,
    font_dims: FontDims,
    state: *State,
) !void {

    const drawable = blk: {
        if (optional_dbe) |_| {
            var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
            x.poly_fill_rectangle.serialize(&msg, .{
                .drawable_id = ids.backbuffer(),
                .gc_id = ids.bg_gc(),
            }, &[1]x.Rectangle {.{
                .x = 0, .y = 0,
                .width = window_width,
                .height = window_height,
            }});
            try common.send(sock, &msg);
            break :blk ids.backbuffer();
        }

        var msg: [x.clear_area.len]u8 = undefined;
        x.clear_area.serialize(&msg, false, ids.window(), .{
            .x = 0,
            .y = 0,
            .width = window_width,
            .height = window_height,
        });
        try common.send(sock, &msg);
        break :blk ids.window();
    };

    _ = max_request_len;
//    {
//        const width = 256;
//        const height = 256;
//        const bytes_per_pixel = 4;
//        const data_u8_len = width * height * bytes_per_pixel;
//        var data_u32: [width * height]u32 = undefined;
//        {
//            var data_offset: usize = 0;
//            var row: usize = 0;
//            while (row < height) : (row += 1) {
//                var col: usize = 0;
//                while (col < width) : (col += 1) {
//                    data_u32[data_offset] =
//                        @intCast(u32, ((row & 0xff) << 8) | (0xff & col));
//                    data_offset += 1;
//                }
//            }
//        }
//        const data_u8_ptr = @ptrCast([*]u8, &data_u32);
//        try sendImage(
//            sock,
//            max_request_len,
//            drawable,
//            ids.fg_gc(),
//            20,
//            20,
//            width,
//            height,
//            width * 4,
//            data_u8_ptr[0..data_u8_len],
//        );
//        {
//            var data_offset: usize = 0;
//            var row: usize = 0;
//            while (row < height) : (row += 1) {
//                var col: usize = 0;
//                while (col < width) : (col += 1) {
//                    data_u32[data_offset] =
//                        @intCast(u32, ((col & 0xff) << 16) | ((row & 0xff) << 8));
//                    data_offset += 1;
//                }
//            }
//        }
//        try sendImage(
//            sock,
//            max_request_len,
//            drawable,
//            ids.fg_gc(),
//            20 + 260,
//            20,
//            width,
//            height,
//            width * 4,
//            data_u8_ptr[0..data_u8_len],
//        );
//    }

    switch (state.main) {
        .show_devices => |*show| {
            var y_pos = 10 + font_dims.font_ascent;
            for (show.video_devs.items) |*video_dev| {
                if (!video_dev.mightHaveCapture()) {
                    // TODO: make an option to show all video devs maybe?
                    continue;
                }
                try renderVideoDev(sock, drawable, ids.fg_gc(), font_dims, y_pos, video_dev.*);
                y_pos += font_dims.height + 4;
            }
        },
        .device => |*dev| {
            const device = &dev.video_devs.items[dev.device_index];
            const text_y = 10 + font_dims.font_ascent;
            try renderVideoDev(sock, drawable, ids.fg_gc(), font_dims, text_y, device.*);
            if (dev.last_frame) |frame| {
                try sendImage(
                    sock,
                    max_request_len,
                    drawable,
                    ids.fg_gc(),
                    10,
                    text_y + 10,
                    frame.width,
                    frame.height,
                    frame.width * 4,
                    frame.mem,
                );
            }
        },
    }

    const text_spacing_y = 4;
    const text_bottom_y = window_height - 10 - font_dims.font_ascent;
    {
        _ = try renderString(sock, drawable, ids.fg_gc(), 10, text_bottom_y - 1 * (font_dims.height + text_spacing_y), "ESC: quit", .{});
        switch (state.main) {
            .show_devices => {
                _ = try renderString(sock, drawable, ids.fg_gc(), 10, text_bottom_y - 2 * (font_dims.height + text_spacing_y), "r: refresh", .{});
            },
            .device => |*dev| {
                if (dev.capture) |*cap| {
                    _ = try renderString(sock, drawable, ids.fg_gc(), 10, text_bottom_y - 4 * (font_dims.height + text_spacing_y), "video format: {s}", .{@tagName(cap.format)});
                }
                _ = try renderString(sock, drawable, ids.fg_gc(), 10, text_bottom_y - 3 * (font_dims.height + text_spacing_y), "p: show preview", .{});
                _ = try renderString(sock, drawable, ids.fg_gc(), 10, text_bottom_y - 2 * (font_dims.height + text_spacing_y), "b: back to device list", .{});
            },
        }

    }
    {
        // TODO: draw a background behind the command (maybe black?)
        const cmd = state.cmd.slice();
        if (cmd.len > 0) {
            _ = try renderString(sock, drawable, ids.fg_gc(), 10, text_bottom_y, "{s}", .{ state.cmd.slice() });
        }
    }

    if (optional_dbe) |dbe| {
        var msg: [x.dbe.swap.getLen(1)]u8 = undefined;
        const swap_infos_arr = [1]x.dbe.SwapInfo{
            .{ .window = ids.window(), .action = .dontcare },
        };
        const swap_infos = x.Slice(u32, [*]const x.dbe.SwapInfo){ .ptr = &swap_infos_arr, .len = swap_infos_arr.len };
        x.dbe.swap.serialize(&msg, swap_infos, .{ .ext_opcode = dbe.opcode });
        try common.send(sock, &msg);
    }
}

fn renderVideoDev(
    sock: os.socket_t,
    drawable_id: u32,
    gc_id: u32,
    font_dims: FontDims,
    y_pos: i16,
    video_dev: VideoDev,
) !void {
    const path: []const u8 = if (video_dev.optional_device_path) |p| p else "<no-device-file>";
    switch (video_dev.cap) {
        .fail => |*cap| {
            _ = try renderString(sock, drawable_id, gc_id, 10, y_pos, "{}: {s} (failed to get cap with E{s})", .{
                video_dev.minor,
                path,
                @tagName(cap.errno),
            });
        },
        .success => |*cap| {
            var enum_fmt_error_buf: [60]u8 = undefined;
            const enum_fmt_err: []u8 = blk: {
                if (cap.enum_format_errno) |errno| {
                    break :blk try std.fmt.bufPrint(&enum_fmt_error_buf, " (ENUM_FMT errno={})", .{errno});
                }
                break :blk "";
            };
            var x_pos: i16 = 10;
            const len = try renderString(sock, drawable_id, gc_id, x_pos, y_pos, "{}: {s} \"{s}\" ({s}){s}", .{
                video_dev.minor,
                path,
                cap.card.sliceConst(),
                cap.bus_info.sliceConst(),
                enum_fmt_err,
            });
            x_pos += @intCast(i16, len) * @intCast(i16, font_dims.width);
            for (cap.formats) |fmt| {
                const fmt_len = try renderString(sock, drawable_id, gc_id, x_pos, y_pos, " {s}", .{fmt.chars});
                x_pos += fmt_len * @as(i16, font_dims.width);
            }
        },
    }
}

fn renderString(
    sock: os.socket_t,
    drawable_id: u32,
    gc_id: u32,
    pos_x: i16,
    pos_y: i16,
    comptime fmt: []const u8,
    args: anytype,
) !u8 {
    var msg: [x.image_text8.max_len]u8 = undefined;
    const text_buf = msg[x.image_text8.text_offset .. x.image_text8.text_offset + 0xff];
    const text_len = @intCast(u8, (std.fmt.bufPrint(text_buf, fmt, args) catch @panic("string too long")).len);
    x.image_text8.serializeNoTextCopy(&msg, text_len, .{
        .drawable_id = drawable_id,
        .gc_id = gc_id,
        .x = pos_x,
        .y = pos_y,
    });
    try common.send(sock, msg[0 .. x.image_text8.getLen(text_len)]);
    return text_len;
}

fn sendImage(
    sock: os.socket_t,
    max_request_len: u18,
    drawable_id: u32,
    gc_id: u32,
    x_loc: i16,
    y: i16,
    width: u32,
    height: u32,
    stride: u32,
    data: []const u8,
) !void {
    std.debug.assert(height > 0);
    const max_image_len = max_request_len - x.put_image.data_offset;

    // TODO: is this division going to hurt performance?
    const max_lines_per_msg = @divTrunc(max_image_len, stride);
    if (max_lines_per_msg == 0) {
        // in this case we would have to split up each line of the image as well, but
        // this is *unlikely* to ever happen right?
        std.debug.panic("TODO: 1 line is to long!?! max_image_len={}, stride={}", .{max_image_len, stride});
    }

    var lines_sent: u32 = 0;
    var data_offset: usize = 0;
    while (true) {
        const lines_remaining = height - lines_sent;
        var next_msg_line_count = std.math.min(lines_remaining, max_lines_per_msg);
        var data_len = stride * next_msg_line_count;
        try sendPutImage(
            sock,
            drawable_id,
            gc_id,
            x_loc,
            // TODO: is this cast ok?
            y + @intCast(i16, lines_sent),
            width,
            next_msg_line_count,
            x.Slice(u18, [*]const u8) {
                .ptr = data.ptr + data_offset,
                .len = @intCast(u18, data_len),
            },
        );
        lines_sent += next_msg_line_count;
        if (lines_sent == height) break;
        data_offset += data_len;
    }
}

fn sendPutImage(
    sock: os.socket_t,
    drawable_id: u32,
    gc_id: u32,
    x_loc: i16,
    y: i16,
    width: u32,
    height: u32,
    data: x.Slice(u18, [*]const u8),
) !void {
    var msg: [x.put_image.data_offset]u8 = undefined;
    const expected_msg_len = x.put_image.data_offset + data.len;
    std.debug.assert(expected_msg_len == x.put_image.getLen(data.len));
    x.put_image.serializeNoDataCopy(&msg, data.len, .{
        .format = .z_pixmap,
        .drawable_id = drawable_id,
        .gc_id = gc_id,
        .width = @intCast(u16, width),
        .height = @intCast(u16, height),
        .x = x_loc,
        .y = y,
        .left_pad = 0,
        // hardcoded to my machine with:
        //     depth= 24 bpp= 32 scanpad= 32
        .depth = 24,
    });
    if (builtin.os.tag == .windows) {
        @compileError("writev not implemented on windows");
    } else {
        const len = try os.writev(sock, &[_]os.iovec_const {
            .{ .iov_base = &msg, .iov_len = msg.len },
            .{ .iov_base = data.ptr, .iov_len = data.len },
        });
        if (len != expected_msg_len) {
            // TODO: need to call write multiple times
            std.debug.panic("TODO: writev {} only wrote {}", .{expected_msg_len, len});
        }
    }
}
