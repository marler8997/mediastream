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
pub fn Ioctl(
    comptime dir: IoctlDirection,
    comptime io_type: u8,
    comptime nr: u8,
    comptime T: type,
) IoctlInfo(dir, io_type, nr, T).Fn {
    return IoctlInfo(dir, io_type, nr, T).call;
}

fn IoctlInfo(comptime dir: IoctlDirection, comptime io_type: u8, comptime nr: u8, comptime T: type) type {
    comptime {
        switch (dir) {
            .none => {
                std.debug.assert(T == void);
            },
            else => {},
        }
    }

    return struct {
        pub const request = switch (dir) {
            .none => std.os.linux.IOCTL.IO(io_type, nr),
            .read => std.os.linux.IOCTL.IOR(io_type, nr, T),
            .write => std.os.linux.IOCTL.IOW(io_type, nr, T),
            .read_write => std.os.linux.IOCTL.IOWR(io_type, nr, T),
        };

        const Arg = switch (dir) {
            .none => void,
            .read => *T,
            .write => *const T,
            .read_write => *T,
        };

        pub const Fn =
            if (Arg == void) fn(fd: std.os.fd_t) usize
            else fn (fd: std.os.fd_t, arg: Arg) usize;

        pub usingnamespace if (Arg == void) struct {
            pub fn call(fd: std.os.fd_t) usize {
                return std.os.linux.syscall2(.ioctl, @bitCast(usize, @as(isize, fd)), request);
            }
        } else struct {
            pub fn call(fd: std.os.fd_t, arg: Arg) usize {
                return std.os.linux.ioctl(fd, request, @ptrToInt(arg));
            }
        };
    };
}
