const std = @import("std");

const N: i32 = 0x1000;
const FILL: u8 = 0x20;
const F: i32 = 0x12;
const MATCH_THRESHOLD: u8 = 0x2;
const BUF_SIZE: i32 = N + F - 1;

//------------------------------------------------- read

pub const LzssError = error {
    InvalidData,
    ChecksumMismatch,
    BufferTooSmall,
    OutOfMemory
};

pub fn lzssDecompress(
    input:                      []const u8,
    expected_len:               usize,
    comptime signed_checksum:   bool,
    allocator:                  std.mem.Allocator
) LzssError![]u8 {
    const input_len = input.len;
    var text_buf = [_]u8{FILL} ** BUF_SIZE;
    var bytes_left = expected_len;
    var result = try allocator.alloc(u8, expected_len);
    errdefer allocator.free(result);

    var result_index: usize = 0;
    var r: i32 = @as(i32, @intCast(N - F));
    var checksum: i32 = 0;
    var flags: i32 = 0;
    var input_index: usize = 0;

    while (bytes_left != 0) {
        if (input_index >= input_len) return LzssError.InvalidData;

        flags >>= 1;
        if ((flags & 256) == 0) {
            flags = @as(i32, input[input_index]) | 0xff00;
            input_index += 1;
        }
        if (input_index >= input_len) return LzssError.InvalidData;
        if ((flags & 1) != 0) {
            const c = input[input_index];
            input_index += 1;

            try decompressHelper(
                &checksum,
                result[0..],
                &result_index,
                &text_buf,
                &r,
                &bytes_left,
                c,
                signed_checksum,
            );
            continue;
        }

        if (input_index + 1 >= input_len) return LzssError.InvalidData;

        var i = input[input_index];
        var j = input[input_index + 1];
        input_index += 2;

        i |= (j & 0xf0) << 4;
        j &= 0x0f;
        j += MATCH_THRESHOLD;

        const ii = r - @as(i32, @intCast(i));
        const jj = @as(i32, @intCast(j)) + ii;
        if (j + 1 > bytes_left) {
            return LzssError.BufferTooSmall;
        }

        var k = ii;
        while (k <= jj) : (k += 1) {
            const c = text_buf[@as(usize, @intCast(k & @as(i32, @intCast(N - 1))))];
            try decompressHelper(
                &checksum,
                result[0..],
                &result_index,
                &text_buf,
                &r,
                &bytes_left,
                c,
                signed_checksum,
            );
        }
    }

    if (input_index + 4 > input_len) return LzssError.InvalidData;

    const csr = std.mem.readInt(u32, input[input_index..][0..4], .little);
    if (csr != @as(u32, @bitCast(checksum))) {
        return LzssError.ChecksumMismatch;
    }

    return result[0..expected_len];

}

fn decompressHelper(
    checksum:                 *i32,
    dst:                      []u8,
    dst_index:                *usize,
    text_buf:                 []u8,
    r:                        *i32,
    bytes_left:               *usize,
    c:                        u8,
    comptime signed_checksum: bool,
) LzssError!void {
    checksum.* = if (signed_checksum)
        checksum.* +% @as(i32, @intCast(@as(u32,c)))
    else
        checksum.* +% @as(i32, c);

    if (dst_index.* >= dst.len) return LzssError.BufferTooSmall;


    dst[dst_index.*] = c;
    dst_index.* += 1;
    bytes_left.* -= 1;
    text_buf[@as(usize, @intCast(r.*))] = c;
    r.* = (r.* + 1) & @as(i32, @intCast(N - 1));
}

fn lzssDecompressSigned(
    input:        []const u8,
    expected_len: usize,
    allocator:    std.mem.Allocator
) LzssError![]u8 {
    return lzssDecompress(input, expected_len, true, allocator);
}

fn lzssDecompressUnsigned(
    input:        []const u8,
    expected_len: usize,
    allocator:    std.mem.Allocator
) LzssError![]u8 {
    return lzssDecompress(input, expected_len, false, allocator);
}

//c exports
pub const DecompressResultC = extern struct {
    data:       ?[*]u8,
    error_code: c_int,
};

pub export fn lzssDecompressC(
    input:           [*]const u8,
    input_len:       usize,
    expected_len:    usize,
    signed_checksum: bool
) DecompressResultC {
    if (signed_checksum) {
        const result = lzssDecompressSigned(
            input[0..input_len],
            expected_len,
            std.heap.c_allocator,
        ) catch |err| {
            return DecompressResultC{
                .data = null,
                .error_code = switch (err) {
                    LzssError.InvalidData => 1,
                    LzssError.ChecksumMismatch => 2,
                    LzssError.BufferTooSmall => 3,
                    LzssError.OutOfMemory => 4,
                },
            };
        };
        return DecompressResultC{
            .data = result.ptr,
            .error_code = 0,
        };
    } else {
        const result = lzssDecompressUnsigned(
            input[0..input_len],
            expected_len,
            std.heap.c_allocator,
        ) catch |err| {
            return DecompressResultC{
                .data = null,
                .error_code = switch (err) {
                    LzssError.InvalidData => 1,
                    LzssError.ChecksumMismatch => 2,
                    LzssError.BufferTooSmall => 3,
                    LzssError.OutOfMemory => 4,
                },
            };
        };
        return DecompressResultC{
            .data = result.ptr,
            .error_code = 0,
        };
    }

}

//------------------------------------------------ write
//

pub const CompressResult = extern struct {
    data:    ?[*]u8,
    length:  usize,
    success: u8
};

pub fn lzssCompress(
    input:                    []const u8,
    comptime signed_checksum: bool,
    allocator:                std.mem.Allocator
) ![]u8 {
    var context = LzssContext.init();
    const input_len: i32 = if (input.len > std.math.maxInt(i32))
        return error.BufferTooLong
    else @intCast(input.len);

    const max_output_size = input_len + (@divTrunc(input_len, 8)) + 8;
    const output_buffer = try allocator.alloc(u8, @intCast(max_output_size));
    errdefer allocator.free(output_buffer);

    var out_pos: usize = 0;
    var cbuf: [17]u8 = undefined;
    var mask: u8 = 1;
    var cptr: u8 = 1;

    var s: i32 = 0;
    var r: i32 = N - F;
    var csum: i32 = 0;

    var len: i32 = 0;
    var pos: usize = 0;
    while (len < F and pos < input_len) : (pos += 1) {
        const c = input[pos];
        context.text_buf[@intCast(r + len)] = c;
        csum = csum +% if (signed_checksum) @as(i32, c) else @as(i32, @intCast(@as(u32, c)));
        len += 1;
    }

    var i: i32 = 1;
    while (i <= F) : (i += 1) {
        context.insertNode(r - i);
    }
    context.insertNode(r);

    cbuf[0] = 0;
    while (len > 0) {
        if (context.match_len > len) context.match_len = len;

        if (context.match_len <= MATCH_THRESHOLD) {
            context.match_len = 1;
            cbuf[0] |= mask;
            cbuf[cptr] = context.text_buf[@intCast(r)];
            cptr += 1;
        } else {
            const mp = (r - context.match_pos) & (N - 1);
            cbuf[cptr] = @as(u8, @truncate(@as(u32, @intCast(mp))));
            cbuf[cptr + 1] = @as(u8, @truncate(@as(u32, @intCast(
                ((mp >> 4) & 0xf0) | (context.match_len - (MATCH_THRESHOLD + 1))))));
            cptr += 2;
        }

        mask = mask << 1;
        if (mask == 0) {
            @memcpy(output_buffer[out_pos..out_pos + cptr], cbuf[0..cptr]);
            out_pos += cptr;
            cbuf[0] = 0;
            cptr = 1;
            mask = 1;
        }

        const last_match_len = context.match_len;

        i = 0;
        while (i < last_match_len and pos < input_len) : (i += 1) {
            const c = input[pos];
            pos += 1;
            context.deleteNode(s);
            context.text_buf[@intCast(s)] = c;
            csum = csum +% if (signed_checksum) @as(i32, c) else @as(i32, @intCast(@as(u32, c)));

            if (s < F - 1) {
                context.text_buf[@intCast(s + N)] = c;
            }

            s = (s + 1) & (N - 1);
            r = (r + 1) & (N - 1);
            context.insertNode(r);
        }

        while (i < last_match_len) : (i += 1) {
            context.deleteNode(s);
            s = (s + 1) & (N - 1);
            r = (r + 1) & (N - 1);
            if (len > 0) {
               len -= 1;
               context.insertNode(r);
            }
        }

        if (len <= 0) break;
    }

    if (cptr > 1) {
        @memcpy(output_buffer[out_pos..out_pos + cptr], cbuf[0..cptr]);
        out_pos += cptr;
    }

    // Write checksum
    const checksum_bytes = @as([*]const u8, @ptrCast(&csum))[0..@sizeOf(i32)];
    @memcpy(output_buffer[out_pos..out_pos + @sizeOf(i32)], checksum_bytes);
    out_pos += @sizeOf(i32);

    return try allocator.realloc(output_buffer, out_pos);

}

const LzssContext = struct {

    text_buf:  [BUF_SIZE] u8,
    left:      [N + 1]    i32,
    right:     [N + 257]  i32,
    parent:    [N + 1]    i32,
    match_pos:            i32,
    match_len:            i32,

    const Self = @This();

    fn init() Self {
        var context = Self{
            .text_buf = [_]u8{FILL} ** BUF_SIZE,
            .left = [_]i32{N} ** (N + 1),
            .right = [_]i32{N} ** (N + 257),  // Changed size to match array
            .parent = [_]i32{N} ** (N + 1),
            .match_pos = 0,
            .match_len = 0,
        };

        var i: i32 = N + 1;
        while (i <= N + 256) : (i += 1) {
            context.right[@intCast(i)] = N;
        }

        i = 0;
        while (i < N) : (i += 1) {
            context.parent[@intCast(i)] = N;
        }

        return context;
    }

    fn insertNode(self: *Self, r: i32) void {
        var i: i32 = undefined;
        var cmp: i32 = 1;
        var p: i32 = N + 1 + @as(i32, self.text_buf[@intCast(r)]);

        if (p >= N + 257) return;

        self.left[@intCast(r)] = N;
        self.right[@intCast(r)] = N;
        self.match_len = 0;

        while (true) {
            if (cmp != 0) {
                if (self.right[@intCast(p)] != N) {
                    p = self.right[@intCast(p)];
                } else {
                    self.right[@intCast(p)] = r;
                    self.parent[@intCast(r)] = p;
                    return;
                }
            } else {
                if(self.left[@intCast(p)] != N) {
                    p = self.left[@intCast(p)];
                } else {
                    self.left[@intCast(p)] = r;
                    self.parent[@intCast(r)] = p;
                    return;
                }
            }

            const tbp = &self.text_buf[@intCast(p + 1)..];
            const kp = &self.text_buf[@intCast(r + 1)..];

            i = 1;
            while (i < F) : (i += 1) {
                const kp_tmp = kp.*[@intCast(i - 1)];
                const tbp_tmp = tbp.*[@intCast(i - 1)];

                if ( kp_tmp != tbp_tmp) {
                    cmp = if (kp_tmp >= tbp_tmp) 1 else 0;
                    break;
                }
            }

            if (i > self.match_len) {
                self.match_pos = p;
                self.match_len = i;
                if (i >= F) break;
            }

        }

        self.parent[@intCast(r)] = self.parent[@intCast(p)];
        self.left[@intCast(r)] = self.left[@intCast(p)];
        self.right[@intCast(r)] = self.left[@intCast(p)];

        self.parent[@intCast(self.left[@intCast(p)])] = r;
        self.parent[@intCast(self.right[@intCast(p)])] = r;

        if (self.right[@intCast(self.parent[@intCast(p)])] == p) {
            self.right[@intCast(self.parent[@intCast(p)])] = r;
        } else {
            self.left[@intCast(self.parent[@intCast(p)])] = r;
        }

        self.parent[@intCast(p)] = N;
    }

    fn deleteNode(self: *Self, p: i32) void {
        var q: i32 = undefined;

        if (self.parent[@intCast(p)] == N) return;

        if(self.right[@intCast(p)] == N) {
            q = self.left[@intCast(p)];
        } else if (self.left[@intCast(p)] == N) {
            q = self.right[@intCast(p)];
        } else {
            q = self.left[@intCast(p)];
            if (self.right[@intCast(q)] != N) {
                while (self.right[@intCast(q)] != N) {
                    q = self.right[@intCast(q)];
                }

                self.right[@intCast(self.parent[@intCast(q)])] = self.left[@intCast(q)];
                self.parent[@intCast(self.left[@intCast(q)])] = self.parent[@intCast(q)];
                self.left[@intCast(q)] = self.left[@intCast(p)];
                self.parent[@intCast(self.left[@intCast(p)])] = q;
            }
            self.right[@intCast(q)] = self.right[@intCast(p)];
            self.parent[@intCast(self.right[@intCast(p)])] = q;
        }

        self.parent[@intCast(q)] = self.parent[@intCast(p)];
        if(self.right[@intCast(self.parent[@intCast(p)])] == p) {
            self.right[@intCast(self.parent[@intCast(p)])] = q;
        } else {
            self.left[@intCast(self.parent[@intCast(p)])] = q;
        }
        self.parent[@intCast(p)] = N;
    }
};

//c exports
//
pub fn lzssCompressedSigned(
    input:     []const u8,
    allocator: std.mem.Allocator
) ![]u8  {
    return lzssCompress( input, true, allocator);
}

pub fn lzssCompressedUnsigned(
    input:     []const u8,
    allocator: std.mem.Allocator
) ![]u8  {
    return lzssCompress( input, false, allocator);
}

const CompressResultC = extern struct {
    data: ?[*]const u8,
    length: usize,
    success: i32
};

pub export fn lzssCompressC(
    input:           [*]const u8,
    length:          u32,
    signed_checksum: bool,
) CompressResultC {
    if (signed_checksum) {
        const result = lzssCompressedSigned(
            input[0..length],
            std.heap.c_allocator,
        ) catch {
            return CompressResultC{
                .data = null,
                .length = 0,
                .success = 3
            };
        };
        return CompressResultC{
            .data = result.ptr,
            .length = result.len,
            .success = 1
        };
    } else {
        const result = lzssCompressedUnsigned(
            input[0..length],
            std.heap.c_allocator,
        ) catch {
            return CompressResultC{
                .data = null,
                .length = 0,
                .success = 3
            };
        };
        return CompressResultC{
            .data = result.ptr,
            .length = result.len,
            .success = 1
        };
    }
}

//---------------------------------------------------------------------------- tests
const testing = std.testing;
const test_allocator = testing.allocator;

test "LZSS De/Compress Roundtrip" {
    const test_cases = [_][]const u8{
        "j",
        "Hello World",
        "Bisharper.... again.... in another languague? I think you've finally lost it ellie; atleast your learning.",
        "AAAAAAAAAAAAAAAAAAAAAAAAAA", //Repeted patterns
        "101010101010101010101010101010",
        "This is a test. This is a test. This is a test.",
        "The quick brown fox jumps over the lazy dog",
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Praesent posuere eros a cursus tincidunt.",
        "Эй, жлоб! Где туз? Прячь юных съёмщиц в шкаф.", //unicode
        &[_]u8{ 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5 },
    };

    for (test_cases) |input| {
        const compressed = try lzssCompress(input, false, test_allocator);

        defer test_allocator.free(compressed);

        const decompressed = try lzssDecompress(compressed, input.len, false, test_allocator);

        defer test_allocator.free(decompressed);

        try testing.expectEqualSlices(u8, input, decompressed);
    }
}

test "LZSS invalid data handling" {
    const invalid_data = [_]u8{0xFF} ** 10;
    const expected_len = 100;
    const data = lzssDecompress(&invalid_data, expected_len, false, test_allocator);
    try testing.expectError(LzssError.InvalidData, data);
}

test "LZSS with signed checksum" {
    const test_data = "Test with signed checksum";

    // Compress
    const compressed = try lzssCompress(test_data, true, test_allocator);
    defer test_allocator.free(compressed);

    // Decompress with signed checksum
    const decompressed = try lzssDecompress(compressed, test_data.len, true, // signed checksum
        test_allocator);
    defer test_allocator.free(decompressed);

    // Verify content
    try testing.expectEqualSlices(u8, test_data, decompressed);
}

test "LZSS with unsigned checksum" {
    const test_data = "Test with signed checksum";

    // Compress
    const compressed = try lzssCompress(test_data, false, test_allocator);
    defer test_allocator.free(compressed);

    // Decompress with unsigned checksum
    const decompressed = try lzssDecompress(compressed,test_data.len, false, // unsigned checksum
        test_allocator);
    defer test_allocator.free(decompressed);

    // Verify content
    try testing.expectEqualSlices(u8, test_data, decompressed);
}

test "LZSS with random binary data" {
    var prng = std.rand.DefaultPrng.init(0); // Fixed seed for reproducibility
    const random = prng.random();
    const sizes = [_]usize{ 100, 1000, 10000 };

    for (sizes) |size| {
        const original_data = try test_allocator.alloc(u8, size);
        defer test_allocator.free(original_data);

        for (original_data) |*byte| {
            byte.* = random.int(u8);
        }

        const compressed = try lzssCompress(original_data, false, test_allocator);
        defer test_allocator.free(compressed);

        const decompressed = try lzssDecompress(compressed, original_data.len, false, test_allocator);
        defer test_allocator.free(decompressed);

        try testing.expectEqualSlices(u8, original_data, decompressed);
    }
}
