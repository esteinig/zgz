//! Minimal native zlib-ng ABI bindings used by zgz.
//!
//! This binds the native zlib-ng API exposed by `zlib-ng.h`, not the classic
//! zlib-compatible API exposed by `zlib.h`.

const std = @import("std");

pub const int32_t = i32;
pub const uint32_t = u32;
pub const Bytef = u8;

/// Native zlib-ng uses uint32_t for avail_in / avail_out.
pub const uInt = uint32_t;

/// Opaque internal zlib-ng state.
pub const internal_state = opaque {};

/// zlib-ng allocator callback.
pub const alloc_func = ?*const fn (?*anyopaque, c_uint, c_uint) callconv(.c) ?*anyopaque;

/// zlib-ng free callback.
pub const free_func = ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

/// Native zlib-ng stream.
///
/// Must match `zng_stream` from generated `zlib-ng.h`.
pub const zng_stream = extern struct {
    /// `const uint8_t *next_in`
    next_in: ?[*]const Bytef,

    /// `uint32_t avail_in`
    avail_in: uint32_t,

    /// `size_t total_in`
    total_in: usize,

    /// `uint8_t *next_out`
    next_out: ?[*]Bytef,

    /// `uint32_t avail_out`
    avail_out: uint32_t,

    /// `size_t total_out`
    total_out: usize,

    /// `const char *msg`
    msg: ?[*:0]const u8,

    /// `struct internal_state *state`
    state: ?*internal_state,

    /// `alloc_func zalloc`
    zalloc: alloc_func,

    /// `free_func zfree`
    zfree: free_func,

    /// `void *opaque`
    @"opaque": ?*anyopaque,

    /// `int data_type`
    data_type: c_int,

    /// `uint32_t adler`
    adler: uint32_t,

    /// `unsigned long reserved`
    reserved: c_ulong,
};

pub const z_stream = zng_stream;

pub const Z_NO_FLUSH: int32_t = 0;

pub const Z_OK: int32_t = 0;
pub const Z_STREAM_END: int32_t = 1;
pub const Z_NEED_DICT: int32_t = 2;
pub const Z_ERRNO: int32_t = -1;
pub const Z_STREAM_ERROR: int32_t = -2;
pub const Z_DATA_ERROR: int32_t = -3;
pub const Z_MEM_ERROR: int32_t = -4;
pub const Z_BUF_ERROR: int32_t = -5;
pub const Z_VERSION_ERROR: int32_t = -6;

pub extern fn zlibng_version() [*:0]const u8;

pub extern fn zng_inflateInit2(
    strm: *zng_stream,
    window_bits: int32_t,
) int32_t;

pub extern fn zng_inflate(
    strm: *zng_stream,
    flush: int32_t,
) int32_t;

pub extern fn zng_inflateReset2(
    strm: *zng_stream,
    window_bits: int32_t,
) int32_t;

pub extern fn zng_inflateEnd(
    strm: *zng_stream,
) int32_t;


pub const Z_DEFLATED: int32_t = 8;
pub const Z_FINISH: int32_t = 4;
pub const Z_DEFAULT_STRATEGY: int32_t = 0;

pub extern fn zng_deflateInit2(
    strm: *zng_stream,
    level: int32_t,
    method: int32_t,
    window_bits: int32_t,
    mem_level: int32_t,
    strategy: int32_t,
) int32_t;

pub extern fn zng_deflate(
    strm: *zng_stream,
    flush: int32_t,
) int32_t;

pub extern fn zng_deflateEnd(
    strm: *zng_stream,
) int32_t;


test "zng_stream ABI layout sanity" {
    try std.testing.expect(@sizeOf(zng_stream) >= 96);
    try std.testing.expect(@alignOf(zng_stream) >= @alignOf(usize));

    try std.testing.expectEqual(@as(usize, 0), @offsetOf(zng_stream, "next_in"));
    try std.testing.expect(@offsetOf(zng_stream, "state") > @offsetOf(zng_stream, "msg"));
    try std.testing.expect(@offsetOf(zng_stream, "reserved") > @offsetOf(zng_stream, "adler"));
}

// test "zng_stream ABI layout sanity - Linux x86_64" {
//     try std.testing.expectEqual(@as(usize, 104), @sizeOf(zng_stream));
//     try std.testing.expectEqual(@as(usize, 8), @alignOf(zng_stream));

//     try std.testing.expectEqual(@as(usize, 0), @offsetOf(zng_stream, "next_in"));
//     try std.testing.expectEqual(@as(usize, 8), @offsetOf(zng_stream, "avail_in"));
//     try std.testing.expectEqual(@as(usize, 16), @offsetOf(zng_stream, "total_in"));
//     try std.testing.expectEqual(@as(usize, 24), @offsetOf(zng_stream, "next_out"));
//     try std.testing.expectEqual(@as(usize, 32), @offsetOf(zng_stream, "avail_out"));
//     try std.testing.expectEqual(@as(usize, 40), @offsetOf(zng_stream, "total_out"));
//     try std.testing.expectEqual(@as(usize, 48), @offsetOf(zng_stream, "msg"));
//     try std.testing.expectEqual(@as(usize, 56), @offsetOf(zng_stream, "state"));
//     try std.testing.expectEqual(@as(usize, 64), @offsetOf(zng_stream, "zalloc"));
//     try std.testing.expectEqual(@as(usize, 72), @offsetOf(zng_stream, "zfree"));
//     try std.testing.expectEqual(@as(usize, 80), @offsetOf(zng_stream, "opaque"));
//     try std.testing.expectEqual(@as(usize, 88), @offsetOf(zng_stream, "data_type"));
//     try std.testing.expectEqual(@as(usize, 92), @offsetOf(zng_stream, "adler"));
//     try std.testing.expectEqual(@as(usize, 96), @offsetOf(zng_stream, "reserved"));
// }
