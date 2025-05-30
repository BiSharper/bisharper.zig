const std = @import("std");

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
