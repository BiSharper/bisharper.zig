const std = @import("std");
const lzss = @import("../root.zig");

var allocator = if (@import("builtin").target.cpu.arch == .wasm32)
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

const ErrorCode = enum(i32) {
    Success = 0,
    OutOfMemory = -1,
    BufferTooLong = -2,
    DataTooLarge = -3,
    ExtraData = -4,
    ChecksumMismatch = -5,
    LZSSOverflow = -6,
    InputTooShort = -7,
    InvalidInput = -8,
};

pub const WasmResult = extern struct {
    ptr: ?[*]u8,
    len: u32,
    error_code: i32,
};

comptime {
    if (@import("builtin").target.cpu.arch == .wasm32) {
        @export(wasmAlloc, .{ .name = "wasmAlloc" });
        @export(wasmFree, .{ .name = "wasmFree" });
        @export(wasmEncode, .{ .name = "wasmEncode" });
        @export(wasmDecode, .{ .name = "wasmDecode" });
        @export(wasmRandom, .{ .name = "wasmRandom" });
    }
}

pub fn wasmAlloc(size: u32) ?[*]u8 {
    const memory = allocator.alloc(u8, size) catch return null;
    return memory.ptr;
}

pub fn wasmFree(ptr: [*]u8, size: u32) void {
    const slice = ptr[0..size];
    allocator.free(slice);
}

pub fn wasmEncode(input_ptr: [*]const u8, input_len: u32, signed_checksum: bool) WasmResult {
    if (input_len == 0) {
        return WasmResult{
            .ptr = null,
            .len = 0,
            .error_code = @intFromEnum(ErrorCode.InvalidInput),
        };
    }

    const input_slice = input_ptr[0..input_len];

    const encoded = lzss.encode(allocator, input_slice, signed_checksum) catch |err| {
        return WasmResult{
            .ptr = null,
            .len = 0,
            .error_code = switch (err) {
                error.OutOfMemory => @intFromEnum(ErrorCode.OutOfMemory),
                error.BufferTooLong => @intFromEnum(ErrorCode.BufferTooLong),
            },
        };
    };

    return WasmResult{
        .ptr = encoded.ptr,
        .len = @intCast(encoded.len),
        .error_code = @intFromEnum(ErrorCode.Success),
    };
}

pub fn wasmDecode(input_ptr: [*]const u8, input_len: u32, expected_len: u32, signed_checksum: bool) WasmResult {
    if (input_len == 0 or expected_len == 0) {
        return WasmResult{
            .ptr = null,
            .len = 0,
            .error_code = @intFromEnum(ErrorCode.InvalidInput),
        };
    }

    const input_slice = input_ptr[0..input_len];

    const decoded = lzss.decode(allocator, input_slice, expected_len, signed_checksum) catch |err| {
        return WasmResult{
            .ptr = null,
            .len = 0,
            .error_code = switch (err) {
                error.OutOfMemory => @intFromEnum(ErrorCode.OutOfMemory),
                error.DataToLarge => @intFromEnum(ErrorCode.DataTooLarge),
                error.ExtraData => @intFromEnum(ErrorCode.ExtraData),
                error.ChecksumMismatch => @intFromEnum(ErrorCode.ChecksumMismatch),
                error.LZSSOverflow => @intFromEnum(ErrorCode.LZSSOverflow),
                error.InputTooShort => @intFromEnum(ErrorCode.InputTooShort),
            },
        };
    };

    return WasmResult{
        .ptr = decoded.ptr,
        .len = @intCast(decoded.len),
        .error_code = @intFromEnum(ErrorCode.Success),
    };
}

pub fn wasmRandom(expected_output_size: u32, signed_checksum: bool, seed: u64) WasmResult {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    const random_data = lzss.random(allocator, rng, expected_output_size, signed_checksum) catch |err| {
        return WasmResult{
            .ptr = null,
            .len = 0,
            .error_code = switch (err) {
                error.OutOfMemory => @intFromEnum(ErrorCode.OutOfMemory),
            },
        };
    };

    return WasmResult{
        .ptr = random_data.ptr,
        .len = @intCast(random_data.len),
        .error_code = @intFromEnum(ErrorCode.Success),
    };
}