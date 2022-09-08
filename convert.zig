const std = @import("std");

pub fn clip_i32_to_u8(val: i32) u8 {
    if (val < 0) return 0;
    if (val > 255) return 255;
    return @intCast(u8, val);
}
pub fn yuyvToRgb(
    dst: [*]u8,
    dst_stride: u32,
    src: [*]const u8,
    src_stride: u32,
    width: u32,
    height: u32,
) void {
    var src_next = src;
    var dst_next = dst;
    
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        yuyvToRgbRow(dst_next, src_next, width);
        src_next += src_stride;
        dst_next += dst_stride;
    }
}

fn yuyvToRgbRow(dst: [*]u8, src: [*]const u8, width: u32) void {
    const dst_u32 = @ptrCast([*]align(1) u32, dst);

    var i: u32 = 0;
    var dst_i: u32 = 0;
    var src_i: u32 = 0;
    while (i < width / 2) : (i += 1) {

        const y0 = src[src_i + 0];
        const u  = src[src_i + 1];
        const y1 = src[src_i + 2];
        const v  = src[src_i + 3];

        const d = @intCast(i32, u) - 128;
        const e = @intCast(i32, v) - 128;

        {
            const c = @intCast(i32, y0) - 16;
            const r = clip_i32_to_u8(( (298 * c) + (409 * e) + 128) >> 8);
            const g = clip_i32_to_u8(( (298 * c) - (100 * d) - (208 * e) + 128) >> 8);
            const b = clip_i32_to_u8(( (298 * c) + (516 * d) + 128) >> 8);
            dst_u32[dst_i] = (@intCast(u32, r) << 16) | (@intCast(u32, g) << 8) | @intCast(u32, b);
        }
        {
            const c = @intCast(i32, y1) - 16;
            const r = clip_i32_to_u8(( (298 * c) + (409 * e) + 128) >> 8);
            const g = clip_i32_to_u8(( (298 * c) - (100 * d) - (208 * e) + 128) >> 8);
            const b = clip_i32_to_u8(( (298 * c) + (516 * d) + 128) >> 8);
            dst_u32[dst_i+1] = (@intCast(u32, r) << 16) | (@intCast(u32, g) << 8) | @intCast(u32, b);
        }
            
        src_i += 4;
        dst_i += 2;
    }
}
