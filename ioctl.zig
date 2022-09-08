// TODO: this should be in a library (maybe in std, not sure though)
const std = @import("std");

pub const IoctlDirection = enum {
    none,
    read,
    write,
    read_write,
};

/// Returns a type-safe ioctl wrapper function.
///
/// Linux encodes the size of the argument and its IO direction within the request number.
/// This function ties ioctl number definition to the Zig type system through the type-safe
/// wrapper function.
pub fn ioctlFunc(
    comptime dir: IoctlDirection,
    comptime io_type: u8,
    comptime nr: u8,
    comptime Arg: type,
) ioctlInfo(dir, io_type, nr, Arg).Fn {
    return ioctlInfo(dir, io_type, nr, Arg).call;
}

fn ioctlInfo(comptime dir: IoctlDirection, comptime io_type: u8, comptime nr: u8, comptime Arg: type) type {
    comptime {
        switch (dir) {
            .none => {
                std.debug.assert(Arg == void);
            },
            else => {},
        }
    }

    return struct {
        pub const request = switch (dir) {
            .none => std.os.linux.IOCTL.IO(io_type, nr),
            .read => std.os.linux.IOCTL.IOR(io_type, nr, Arg),
            .write => std.os.linux.IOCTL.IOW(io_type, nr, Arg),
            .read_write => std.os.linux.IOCTL.IOWR(io_type, nr, Arg),
        };

        const ArgPtr = switch (dir) {
            .none => void,
            .read => *Arg,
            .write => *const Arg,
            .read_write => *Arg,
        };

        pub const Fn =
            if (Arg == void) fn(fd: std.os.fd_t) usize
            else fn (fd: std.os.fd_t, arg: ArgPtr) usize;

        pub usingnamespace if (Arg == void) struct {
            pub fn call(fd: std.os.fd_t) usize {
                return std.os.linux.syscall2(.ioctl, @bitCast(usize, @as(isize, fd)), request);
            }
        } else struct {
            pub fn call(fd: std.os.fd_t, arg: ArgPtr) usize {
                return std.os.linux.ioctl(fd, request, @ptrToInt(arg));
            }
        };
    };
}
