const std = @import("std");
const os = std.os;
const Ioctl = @import("ioctl.zig").Ioctl;

// Find all the video4linux2 devices reported by the kernel
pub const KernelDevices = struct {
    const sysfs_path = "/sys/class/video4linux";

    dir: std.fs.IterableDir,
    pub fn init() !KernelDevices {
        return KernelDevices{
            .dir = try std.fs.openIterableDirAbsolute(sysfs_path, .{}),
        };
    }
    pub fn deinit(self: *KernelDevices) void {
        self.dir.close();
    }

    pub fn iterate(self: KernelDevices) Iterator {
        return Iterator{
            .iterator = self.dir.iterate(),
        };
    }
    pub const Iterator = struct {
        iterator: std.fs.IterableDir.Iterator,
        pub fn next(self: *Iterator) !?u8 {
            const entry = (try self.iterator.next()) orelse return null;
            const video_prefix = "video";
            if (!std.mem.startsWith(u8, entry.name, video_prefix)) {
                std.log.err("expected all entries in '{s}' to begin with '{s}' but got '{s}'", .{
                    sysfs_path,
                    video_prefix,
                    entry.name,
                });
                return error.UnexpectedSysfs;
            }
            const num_string = entry.name[video_prefix.len..];
            const num = std.fmt.parseInt(u8, num_string, 10) catch |err| {
                std.log.err("video4linux sysfs entry '{s}' is in an unexpected format, parse error {s}", .{ entry.name, @errorName(err) });
                return error.UnexpectedSysfs;
            };
            return num;
        }
    };
};

fn getRdevMajor(rdev: os.dev_t) u32 {
    return @intCast(u32, ((rdev >> 32) & 0xfffff000) | ((rdev >> 8) & 0x00000fff));
}
fn getRdevMinor(rdev: os.dev_t) u32 {
    return @intCast(u32, ((rdev >> 12) & 0xffffff00) | (rdev & 0x000000ff));
}

const major = 81;

pub const DeviceFiles = struct {
    const dev_path = "/dev";

    dir: std.fs.IterableDir,
    pub fn open() !DeviceFiles {
        return DeviceFiles{
            .dir = try std.fs.openIterableDirAbsolute(dev_path, .{}),
        };
    }
    pub fn close(self: *DeviceFiles) void {
        self.dir.close();
    }

    pub fn iterate(self: DeviceFiles) Iterator {
        return Iterator{
            .iterator = self.dir.iterate(),
        };
    }
    pub const Entry = struct {
        base_name: []const u8,
        minor: u32,
        pub fn allocPathZ(self: Entry, allocator: std.mem.Allocator) error{OutOfMemory}![:0]u8 {
            return std.fmt.allocPrintZ(allocator, dev_path ++ "/{s}", .{self.base_name});
        }
    };
    pub const Iterator = struct {
        iterator: std.fs.IterableDir.Iterator,
        pub fn next(self: *Iterator) !?Entry {
            while (true) {
                const entry = (try self.iterator.next()) orelse return null;
                if (entry.kind != .CharacterDevice)
                    continue;

                const stat = os.fstatat(self.iterator.dir.fd, entry.name, 0) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => |e| return e,
                };
                if (major != getRdevMajor(stat.rdev))
                    continue;
                return Entry{ .base_name = entry.name, .minor = getRdevMinor(stat.rdev) };
            }
        }
    };
};

pub const Capability = extern struct {
    driver: [16]u8,
    card: [32]u8,
    bus_info: [32]u8,
    version: u32,
    capabilities: u32,
    device_caps: u32,
    reserved: [3]u32,
};

pub const BufType = enum(u32) {
    video_capture        = 1,
    video_output         = 2,
    video_overlay        = 3,
    vbi_capture          = 4,
    vbi_output           = 5,
    sliced_vbi_capture   = 6,
    sliced_vbi_output    = 7,
    video_output_overlay = 8,
    video_capture_mplane = 9,
    video_output_mplane  = 10,
    sdr_capture          = 11,
    sdr_output           = 12,
    meta_capture         = 13,
    meta_output          = 14,
    _,
};

pub const Fmtdesc = extern struct {
    index: u32,
    buf_type: BufType,
    flags: u32,
    description: [32]u8,
    pixelformat: u32,
    mbus_code: u32,
    reserved: [3]u32,
};

pub const PixFormat = extern struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv: u32,
    flags: u32,
    enc: extern union {
        ycbcr: u32,
        hsv_enc: u32,
    },
    quantization: u32,
    xfer_func: u32,
};

pub const Rect = extern struct {
    left: i32,
    top: i32,
    width: u32,
    height: u32,
};

pub const Clip = extern struct {
    c: Rect,
    next: *Clip,
};

pub const Window = extern struct {
    w: Rect,
    field: u32,
    chromakey: u32,
    clips: *Clip,
    clipcount: u32,
    bitmap: *anyopaque,
    global_alpha: u8,
};

pub const Format = extern struct {
    buf_type: BufType,
    fmt: extern union {
        pix: PixFormat,
        win: Window,
        raw_data: [200]u8,
    },
};

pub const Memory = enum(u32) {
    mmap = 1,
    userptr = 2,
    overlay = 3,
    dmabuf = 4,
    _,
};

pub const Requestbuffers = extern struct {
    count: u32,
    buf_type: BufType,
    memory: Memory,
    capabilities: u32,
    flags: u8,
    reserved: [3]u8 = [1]u8 { 0 } ** 3,
};

pub const Timecode = extern struct {
    @"type": Type,
    flags: u32,
    frames: u8,
    seconds: u8,
    minutes: u8,
    hours: u8,
    userbits: [4]u8,
    pub const Type = enum(u32) {
        _24_fps = 1,
        _25_fps = 2,
        _30_fps = 3,
        _50_fps = 4,
        _60_fps = 5,
    };
};

pub const Plane = extern struct {
    bytesused: u32,
    length: u32,
    m: extern union {
        mem_offset: u32,
        userptr: c_ulong,
        fd: os.fd_t,
    },
    data_offset: u32,
    reserved: [11]u32,
};

pub const Buffer = extern struct {
    index: u32,
    buf_type: BufType,
    bytesused: u32,
    flags: u32,
    field: u32,
    timestamp: os.timeval,
    timecode: Timecode,
    sequence: u32,
    memory: Memory,
    m: extern union {
        offset: u32,
        userptr: c_ulong,
        planes: [*]Plane,
        fd: os.fd_t,
    },
    length: u32,
    reserved2: u32,
    request: extern union {
        request_fd: os.fd_t,
        reserved: u32,
    },
};

pub const ioctl = struct {
    pub const querycap = Ioctl(.read , 'V', 0, Capability);
    pub const enum_fmt = Ioctl(.read_write, 'V', 2, Fmtdesc);
    pub const g_fmt = Ioctl(.read_write, 'V', 4, Format);
    pub const s_fmt = Ioctl(.read_write, 'V', 5, Format);
    pub const reqbufs = Ioctl(.read_write, 'V', 8, Requestbuffers);
    pub const querybuf = Ioctl(.read_write, 'V', 9, Buffer);
    pub const qbuf = Ioctl(.read_write, 'V', 15, Buffer);
    pub const dqbuf = Ioctl(.read_write, 'V', 17, Buffer);
    pub const streamon = Ioctl(.write, 'V', 18, BufType);
};
