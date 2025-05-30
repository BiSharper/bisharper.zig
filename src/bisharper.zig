const std = @import("std");
pub const Lzss = struct {
    const N: i32 = 0x1000;
    const FILL: u8 = 0x20;
    const F: i32 = 0x12;
    const MATCH_THRESHOLD: u8 = 0x2;
    const BUF_SIZE: i32 = N + F - 1;

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
        var cmp: bool = true;
        var p: i32 = N + 1 + self.text_buf[@intCast(r)];

        self.right[@intCast(r)] = N;
        self.left[@intCast(r)] = N;
        self.match_len =  0;

        while (true) {
            if (cmp) {
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

            const tbp = self.text_buf[@intCast(p + 1)..];
            const kp = self.text_buf[@intCast(r + 1)..];

            i = 1;
            while (i < F) : (i += 1) {
                if(kp[@intCast(i - 1)] != tbp[@intCast(i - 1)]) {
                    cmp = kp[@intCast(i - 1)] >= tbp[@intCast(i - 1)];
                    break;
                }
            }

            if (i > self.match_len) {
                self.match_pos = p;
                self.match_len = i;
                if (self.match_len >= F) break;
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

    inline fn incrementChecksum(csum: i32, increment: u8, signed_checksum: bool) i32 {
        return csum +% if (signed_checksum) @as(i32, increment) else @as(i32, @intCast(@as(u32, increment)));
    }

    inline fn boundsCheck(len: usize, idx: i32) !void {
        if(idx > len) {
            std.debug.print("LZSS failed to read stream", .{});
            return error.InputTooShort;
        }
    }

    pub fn decode(allocator: std.mem.Allocator, input: []const u8, expected_len: usize, signed_checksum: bool ) ![]u8 {
        if(input.len == 0 or expected_len == 0 ) {
            return try allocator.alloc(u8, 0);
        }
        if(expected_len >= std.math.maxInt(i32) or input.len >= std.math.maxInt(i32)) {
            return error.DataToLarge;
        }

        var output = try allocator.alloc(u8, expected_len);
        errdefer allocator.free(output);

        var out_idx: i32 = 0;
        var in_idx: i32 = 0;
        var bytes_left: i32 = @intCast(expected_len);
        var text_buf = [_]u8{FILL} ** BUF_SIZE;
        var csum: i32 = 0;

        var r: i32 = N - F;
        var flags: i32 = 0;

        while (bytes_left > 0) {
            var c: u8 = 0;

            flags >>= 1;
            if((flags & 256) == 0) {
                c = input[@intCast(in_idx)];
                in_idx += 1;
                flags = @as(i32, c) | 0xff00;
            }

            try boundsCheck(input.len, in_idx);

            if ((flags & 1) != 0) {
                c = input[@intCast(in_idx)];
                in_idx += 1;

                try boundsCheck(input.len, in_idx);
                csum = incrementChecksum(csum, c, signed_checksum);

                output[@intCast(out_idx)] = c;
                out_idx += 1;
                bytes_left -= 1;

                text_buf[@intCast(r)] = c;

                r += 1;
                r &= N - 1;
                continue;
            }

            var i: i32 = @intCast(input[@intCast(in_idx)]);
            in_idx += 1;
            var j: i32 = @intCast(input[@intCast(in_idx)]);
            in_idx += 1;
            try boundsCheck(input.len, in_idx);

            i |= (j & 0xf0) << 4;
            j &= 0x0f;
            j += MATCH_THRESHOLD;

            if((j + 1) > bytes_left) {
                std.log.debug("LZSS overflow", .{});
                return error.LZSSOverflow;
            }

            i = @intCast(r - i);
            j += i;

            while (i <= j) : (i += 1) {
                c = text_buf[@intCast(i & (N - 1))];
                csum = incrementChecksum(csum, c, signed_checksum);

                output[@intCast(out_idx)] = c;
                out_idx += 1;
                bytes_left -= 1;

                text_buf[@intCast(r)] = c;
                r += 1;
                r &= N-1;
            }
        }

        if (in_idx + 4 != input.len) return error.ExtraData;

        const csr = std.mem.readInt(i32, input[@intCast(in_idx)..][0..4], .little);

        if (csr != csum) {

            return error.ChecksumMismatch;
        }

        return output;
    }

    pub fn encode(allocator: std.mem.Allocator, input: []const u8, signed_checksum: bool) ![]u8 {
        var context = Self.init();
        const input_len: i32 = if (input.len > std.math.maxInt(i32))
            return error.BufferTooLong
        else @intCast(input.len);

        const max_out: i32 = @intCast(@max(std.math.maxInt(i32), input_len + (@divTrunc(input_len, 8)) + 8));
        var out = try allocator.alloc(u8, @intCast(max_out));
        errdefer allocator.free(out);


        var out_idx: i32 = 0;
        var in_idx: i32 = 0;
        var text_size: i32 = 0;
        var codesize: i32 = 0;
        var csum: i32 = 0;
        var last_match_len: i32 = 0;
        var cbuf = [_]u8{0} ** 17;
        var cbuf_idx: u5 = 1;
        var mask: u8 = 1;
        var s: i32 = 0;
        var r: i32 = N - F;
        var c: u8 = undefined;

        var len: i32 = 0;
        while (len < F and in_idx < input_len) : (len += 1) {
            c = input[@intCast(in_idx)];
            context.text_buf[@intCast(r + len)] = c;

            in_idx += 1;
            csum = incrementChecksum(csum, c, signed_checksum);
        }
        text_size = len;

        std.debug.assert(text_size > 0);
        var i: i32 = 1;
        while (i <= F) : (i += 1) {
            context.insertNode(r - i);
        }
        context.insertNode(r);

        while (true) {
            if(context.match_len > len) context.match_len = len;

            if(context.match_len <= MATCH_THRESHOLD) {
                context.match_len = 1;
                cbuf[0] |= mask;
                cbuf[@intCast(cbuf_idx)] = context.text_buf[@intCast(r)];
                cbuf_idx += 1;
            } else {
                const mp: u8 = @intCast((r - context.match_pos) & (N - 1));
                cbuf[cbuf_idx] = mp;
                cbuf_idx += 1;
                cbuf[cbuf_idx] = @intCast(((mp >> 4) & 0xF0) | (context.match_len - (MATCH_THRESHOLD + 1)));
                cbuf_idx += 1;
            }

            mask <<= 1;
            if(mask == 0) {
                @memcpy(out[@intCast(out_idx)..@intCast(out_idx + cbuf_idx)], cbuf[0..@intCast(cbuf_idx)]);
                codesize += cbuf_idx;
                out_idx += cbuf_idx;
                cbuf[0] = 0;
                cbuf_idx = 1;
                mask = 1;
            }

            last_match_len = context.match_len;

            i = 0;
            while (i < last_match_len and in_idx < input_len) : (i += 1) {
                context.deleteNode(s);

                c = input[@intCast(in_idx)];
                in_idx += 1;

                context.text_buf[@intCast(s)] = c;
                csum = incrementChecksum(csum, c, signed_checksum);

                if(s < F - 1) context.text_buf[@intCast(s + N)] = c;
                s += 1; s &= N - 1;
                r += 1; r &= N - 1;
                context.insertNode(r);
            }

            text_size += 1;
            while (i < last_match_len) : (i += 1) {
                context.deleteNode(s);
                s = (s + 1) & (N - 1);
                r = (r + 1) & (N - 1);
                len -= 1;
                if (len > 0) context.insertNode(r);
            }

            if(len <= 0) break;
        }
        if (cbuf_idx > 1) {
            @memcpy(out[@intCast(out_idx)..@intCast(out_idx + cbuf_idx)], cbuf[0..@intCast(cbuf_idx)]);
            codesize += cbuf_idx;
            out_idx += cbuf_idx;
        }

        @memcpy(
            out[@intCast(out_idx)..@intCast(out_idx + @sizeOf(i32))],
            @as([*]const u8, @ptrCast(&csum))[0..@sizeOf(i32)]
        );
        out_idx += @sizeOf(i32);

        return try allocator.realloc(out, @intCast(out_idx));
    }

    pub fn random(allocator: std.mem.Allocator, rng: std.rand.Random, expected_output_size: usize, signed_checksum: bool) ![]u8 {
        const MIN_MATCH: i32 = MATCH_THRESHOLD + 1;
        const MAX_MATCH: i32 = F;
        const MATCH_PROB: f32 = 0.3; //Directly correlates to entropy
        //very liberal with size here we could probably get a lower higher bound
        const max_size =  if (expected_output_size == 0) 4 else expected_output_size * 2 + 8;
        var buffer = try allocator.alloc(u8, if (expected_output_size == 0) 4 else max_size);
        errdefer allocator.free(buffer);

        if (expected_output_size == 0) {
            std.mem.writeInt(u32, buffer[0..4], 0, .little);
            return buffer;
        }
        var text_buf: [N]u8 = .{FILL} ** N;
        var r: usize = N - F;
        var decomp: usize = 0;
        var csum: i32 = 0;
        var idx: usize = 0;
        while (decomp < expected_output_size) {
            const flag_idx = idx;
            idx += 1;
            var flag: u8 = 0;
            var ops_in_this_block: u4 = 0;
            for (0..8) |op_idx_in_block| {
                if (decomp >= expected_output_size) {
                    break;
                }
                const remaining = expected_output_size - decomp;
                const match = (remaining >= MIN_MATCH and rng.float(f32) < MATCH_PROB);

                decomp += blk: {if(!match) {
                    const next = rng.int(u8);
                    flag |= (@as(u8, 1) << @intCast(op_idx_in_block));

                    buffer[idx] = next;
                    idx += 1;
                    text_buf[r] = next;
                    r = (r + 1) & (N - 1);
                    csum = incrementChecksum(csum, next, signed_checksum);

                    break :blk 1;
                } else {
                    const out_len = rng.intRangeAtMost(
                        usize,
                        MIN_MATCH,
                        @min(MAX_MATCH, remaining),
                    );

                    const length_code: u4 = @intCast(out_len - MIN_MATCH);
                    std.debug.assert(length_code <= (MAX_MATCH - MIN_MATCH) and length_code <= 0x0F);

                    const source_abs: u12 = @truncate(rng.intRangeAtMost(usize, 0, N - 1));
                    const offset_val: u12 = @truncate((r -% source_abs) & (N - 1));

                    buffer[idx] = @truncate(offset_val);
                    idx += 1;
                    buffer[idx] = (@as(u8, @truncate(offset_val >> 8)) << 4) | length_code;
                    idx += 1;

                    for (0..out_len) |i| {
                        const c = text_buf[(source_abs + i) & (N - 1)];

                        csum = incrementChecksum(csum, c, signed_checksum);
                        text_buf[r] = c;
                        r = (r + 1) & (N - 1);
                    }

                    break :blk out_len;
                }};
                ops_in_this_block += 1;
            }

            if (ops_in_this_block == 0) {
                idx = flag_idx;
            } else {
                buffer[flag_idx] = flag;
            }
        }
        std.mem.writeInt(i32, buffer[idx .. idx + 4][0..4],csum, .little);
        idx += 4;

        return try allocator.realloc(buffer, idx);
    }

    // pub fn skip(input: []const u8, expected_len: usize, signed_checksum: bool) !void {
    //     if(expected_len == 0) {
    //         return true;
    //     }
    //     if(expected_len >= std.math.maxInt(i32) or input.len >= std.math.maxInt(i32)) {
    //         return error.DataToLarge;
    //     }
    //
    //     var in_idx: i32 = 0;
    //     var left = expected_len;
    //     var text_buf = [_]u8{FILL} ** BUF_SIZE;
    //     var csum: i32 = 0;
    //
    //     var r: i32 = N - F;
    //     var flags: i32 = 0;
    //
    //     while(left > 0){
    //
    //     }
    // }


    const testing = std.testing;
    const test_allocator = testing.allocator;

    test "Generate and decompress random LZSS" {
        var prng = std.rand.DefaultPrng.init(5);
        const rng = prng.random();

        const sizes = [_]usize{
            10,
            50,
            100,
            1024,
            10000,
            100000,
            1000000,
            5000000,
            10000000
        };

        for (sizes) |size| {
            const compressed = try random(
                test_allocator,
                rng,
                size,
                false,
            );
            defer test_allocator.free(compressed);

            const decompressed = decode(
                testing.allocator,
                compressed,
                size,
                false,
            ) catch |err| switch (err) {
                error.ChecksumMismatch => {
                    continue;
                },
                else => return err,
            };

            defer test_allocator.free(decompressed);
        }
    }

    test "LZSS De/Compress Roundtrip" {
        const test_cases = [_][]const u8{
            "a",
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
            const compressed = try encode(test_allocator, input, false);

            defer test_allocator.free(compressed);

            const decompressed = try decode(test_allocator, compressed, input.len, false);

            defer test_allocator.free(decompressed);

            try testing.expectEqualSlices(u8, input, decompressed);
        }
    }

    test "LZSS with signed checksum" {
        const test_data = "Test with signed checksum";

        const compressed = try encode(test_allocator, test_data, true);
        defer test_allocator.free(compressed);

        const decompressed = try decode(test_allocator, compressed, test_data.len, true);
        defer test_allocator.free(decompressed);

        try testing.expectEqualSlices(u8, test_data, decompressed);
    }

    test "LZSS with unsigned checksum" {
        const test_data = "Test with signed checksum";

        const compressed = try encode(test_allocator, test_data, true);
        defer test_allocator.free(compressed);

        const decompressed = try decode(test_allocator, compressed, test_data.len, true);
        defer test_allocator.free(decompressed);

        try testing.expectEqualSlices(u8, test_data, decompressed);
    }
};

pub const Bank = struct {
    pub const CWrapper = extern struct {
        inner: ?*Bank,
        success: u8,

        pub fn deinit(self: *CWrapper) void {
            if(self.inner) |inner| {
                inner.deinit();
                inner.allocator.destroy(inner);
            }
        }
    };

    pub const Mime = union(enum) {
        const DECOMPRESSED: i32 = 0x00000000;
        const COMPRESSED: i32 = 0x43707273;
        const ENCRYPTED: i32 = 0x456e6372;
        const VERSION: i32 = 0x56657273;
        Version: void,
        Decompressed: void,
        Compressed: void,
        Encrypted: void,
        Other: i32,

        pub fn default() Mime {
            return .Decompressed;
        }

        pub fn format(
            self: Mime,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            switch (self) {
                .Version => try writer.writeAll("Version"),
                .Decompressed => try writer.writeAll("Decompressed"),
                .Compressed => try writer.writeAll("Compressed"),
                .Encrypted => try writer.writeAll("Encrypted"),
                .Other => |unknown| try std.fmt.format(writer, "Unknown ({x:0>8})", .{unknown}),
            }
        }

        pub fn toInt(self: Mime) i32 {
            return switch (self) {
                .Version => VERSION,
                .Decompressed => DECOMPRESSED,
                .Compressed => COMPRESSED,
                .Encrypted => ENCRYPTED,
                .Other => |unknown| unknown,
            };
        }

        pub fn fromInt(value: i32) Mime {
            return switch (value) {
                DECOMPRESSED => .Decompressed,
                COMPRESSED => .Compressed,
                ENCRYPTED => .Encrypted,
                VERSION => .Version,
                else => .{ .Other = value },
            };
        }
    };

    pub const Meta = struct {
        mime: Mime,
        size_ext: u32,
        offset: u32,
        time: u32,
        size_int: u32,

        pub fn isVersion(self: Meta) bool {
            return self.mime == .Version and self.size_int == 0 and self.time == 0;
        }

        pub fn isEnd(self: Meta) bool {
            return self.mime == .Decompressed
                and self.size_ext == 0
                and self.offset == 0
                and self.size_int == 0
                and self.time == 0;

        }
    };

    pub const Data = union(enum) {
        Uninitialized: u64,
        Malformed: i64,
        Stitched: []u8,
        Loaded: struct {
            offset: u64,
            data: []u8,
        },
        Patched: struct {
            offset: u64,
            data: []u8,
        },


        pub fn incrementOffset(self: *Data, incrementation: usize) !void {
            return switch (self.*) {
                .Loaded => |*loaded| loaded.offset += @intCast(incrementation),
                .Patched => |*loaded| loaded.offset += @intCast(incrementation),
                .Uninitialized => |*offset| offset.* += @intCast(incrementation),
                .Malformed => |*offset| offset.* += @intCast(incrementation),
                else => error.NoOffsetToIncrement
            };
        }
    };

    pub const Entry = struct {
        meta: Meta,
        data: Data,
    };

    //-----------------------------------------------
    pub const ReadOptions = extern struct {
        verify_checksum:    bool,
        signed_offsets:     bool,
        require_terminator: bool,
        vbs2_lite:          bool
    };

    pub const Source = enum {
        Created,
        Open
    };

    const PREFIX_PROP_NAME = "prefix";

    allocator: std.mem.Allocator,
    properties: std.StringHashMap([]const u8),
    entries: std.StringHashMap(Entry),
    source: Source,
    buffer: ?[]u8,
    path: ?[]u8,

    fn ensureTrailingSlash(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        if (path.len == 0 or path[path.len - 1] == '/') {
            return allocator.dupe(u8, path);
        }

        var result = try allocator.alloc(u8, path.len + 1);
        @memcpy(result[0..path.len], path);
        result[path.len] = '/';
        return result;
    }

    fn readString(data: []const u8, require_terminator: bool) ![:0]const u8 {
        var end: usize = 0;
        while (end < @min(1024, data.len)) : (end += 1) {
            if (data[end] == 0) break;
        }

        if (require_terminator and (end >= data.len or data[end] != 0)) {
            return error.InvalidData;
        }

        if (!std.unicode.utf8ValidateSlice(data[0..end])) {
            return error.InvalidData;
        }

        return data[0..end :0];
    }

    pub fn read(
        input:     []const u8,
        prefix:    []const u8,
        path:      ?[]const u8,
        options:   ReadOptions,
        allocator: std.mem.Allocator,
    ) !Bank {
        var self = try init(prefix, allocator);
        errdefer self.deinit();

        self.buffer = try allocator.dupe(u8, input);

        self.source = Source.Open;

        if (path) |path_| {
            allocator.free(self.path.?);
            self.path = try allocator.dupe(u8, path_);
        }

        var idx: usize = 0;
        var metas_read: u32 = 0;
        var versions_read: u32 = 0;
        var start_offset: i32 = 0;

        if(self.buffer) |buffer| {
            while (idx < input.len) {
                const name = try std.ascii.allocLowerString(allocator,
                    try readString(buffer, options.require_terminator)
                );
                idx += name.len + 1;

                const entry_meta: Meta = std.mem.bytesAsValue(Meta, buffer[idx..][0..@sizeOf(Meta)]).*;
                idx += @sizeOf(Meta);

                metas_read += 1;
                if(entry_meta.isVersion() and name.len == 0 and (options.vbs2_lite or (!options.vbs2_lite and metas_read == 1))) {
                    while (true) {
                        const prop_name = try readString(buffer, true);
                        if (prop_name.len == 0) { break; }

                        const prop_value =  try readString(buffer, true);

                        try self.properties.put(prop_name, if(std.mem.eql(u8, prop_name, PREFIX_PROP_NAME))
                            try ensureTrailingSlash(prop_value, allocator)
                        else
                            prop_value);
                    }
                    versions_read += 1;
                } else {
                    if(name.len == 0 and entry_meta.isEnd()) break;
                    const offset = blk: {if (entry_meta.size_int > std.math.maxInt(i32)) {
                        if (options.signed_offsets) {
                            return error.NegativeOffset;
                        } else {
                            const size = @as(i32, @bitCast(entry_meta.size_int));
                            const malfomed = Data{ .Malformed = @intCast(start_offset) };
                            start_offset += size;
                            break :blk malfomed;
                        }
                    } else {
                        const uninitialized = Data{ .Uninitialized = @intCast(@as(i64, start_offset)) };
                        start_offset += @intCast(entry_meta.size_int);
                        break :blk uninitialized;
                    }};

                    try self.entries.put(name, Entry {
                        .meta = entry_meta,
                        .data = offset,
                    });
                }
            }

        }

        var i: usize = 0;
        var it = self.entries.iterator();
        const data_files = metas_read - versions_read ;
        while (i < data_files) : (i += 1) {
            const entry = it.next() orelse break;
            var data = entry.value_ptr.data;
            try data.incrementOffset(idx);
        }

        if(options.verify_checksum) {
            const data_section = input[0..input.len - 24];
            const checksum_section = input[input.len - 24..];

            const checksum_version = std.mem.readInt(u32, checksum_section[0..4], .little);
            if (checksum_version != 0) return error.UnknownChecksumVersion;

            var hash_buf: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(data_section, &hash_buf, .{

            });

            if (!std.mem.eql(u8, hash_buf[0..], checksum_section[4..24])) {
                return error.InvalidChecksum;
            }
        }

        return self;
    }

    pub fn init(
        prefix: []const u8,
        allocator: std.mem.Allocator,
    ) !Bank {
        const prefix_copy = try ensureTrailingSlash(prefix, allocator);
        errdefer allocator.free(prefix_copy);

        var properties = std.StringHashMap([]const u8).init(allocator);
        errdefer properties.deinit();

        var entries = std.StringHashMap(Entry).init(allocator);
        errdefer entries.deinit();

        try properties.put(PREFIX_PROP_NAME, prefix_copy);

        const path = try allocator.dupe(u8, prefix_copy[0 .. prefix_copy.len - 1]);
        errdefer allocator.free(path);

        return .{
            .allocator = allocator,
            .properties = properties,
            .source = Source.Created,
            .buffer = null,
            .entries = entries,
            .path = path
        };
    }

    pub fn deinit(self: *Bank) void {
        var prop_it = self.properties.iterator();
        while (prop_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.properties.deinit();


        var ent_it = self.entries.iterator();
        while (ent_it.next()) |entry| {
            if (entry.value_ptr.data == .Loaded) {
                self.allocator.free(entry.value_ptr.data.Loaded.data);
            }
        }
        self.entries.deinit();

        if (self.buffer) |buffer| {
            self.allocator.free(buffer);
        }

        if (self.path) |path| {
            self.allocator.free(path);
        }
    }
};

pub export const hi = "im ellie";