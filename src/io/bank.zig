const std = @import("std");

//entry -----------------------------------------------------------------------------------------
pub const BankEntryMime = extern union {
    const DECOMPRESSED: i32 = 0x00000000;
    const COMPRESSED: i32 = 0x43707273;
    const ENCRYPTED: i32 = 0x456e6372;
    const VERSION: i32 = 0x56657273;
    Version: void,
    Decompressed: void,
    Compressed: void,
    Encrypted: void,
    Other: i32,

    pub fn default() BankEntryMime {
        return .Decompressed;
    }

    pub fn format(
        self: BankEntryMime,
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

    pub fn toInt(self: BankEntryMime) i32 {
        return switch (self) {
            .Version => VERSION,
            .Decompressed => DECOMPRESSED,
            .Compressed => COMPRESSED,
            .Encrypted => ENCRYPTED,
            .Other => |unknown| unknown,
        };
    }

    pub fn fromInt(value: i32) BankEntryMime {
        return switch (value) {
            DECOMPRESSED => .Decompressed,
            COMPRESSED => .Compressed,
            ENCRYPTED => .Encrypted,
            VERSION => .Version,
            else => .{ .Other = value },
        };
    }
};

pub const BankEntryMeta = extern struct {
    mime: BankEntryMime,
    size_ext: u32,
    offset: u32,
    time: u32,
    size_int: u32,

    pub fn isVersion(self: BankEntryMeta) bool {
        return self.mime == .Version and self.size_int == 0 and self.time == 0;
    }

    pub fn isEnd(self: BankEntryMeta) bool {
        return self.mime == .Decompressed
            and self.size_ext == 0
            and self.offset == 0
            and self.size_int == 0
            and self.time == 0;

    }
};

pub const BankEntryMetaNamed = extern struct {
    name: []const u8,
    meta: BankEntryMeta,
};

pub const BankEntryData = extern union {
    Uninitialized: u32,
    Malformed: i64,
    Loaded: extern struct {
        offset: u32,
        data: []u8,
    }
};

pub const BankEntry = extern struct {
    named_metadata: BankEntryMetaNamed,
    data: BankEntryData,


    pub fn dataOffset(self: BankEntry) u32 {
        return switch (self.data) {
            .Loaded => |loaded| loaded.offset,
            .Malformed => |malformed_offset| @as(u32, @intCast(malformed_offset)),
            else => 0,
        };
    }
};

//-----------------------------------------------
pub const BankReadOptions = struct {
    read_checksum:      bool,
    signed_offsets:     bool,
    require_terminator: bool,
    vbs2_lite:          bool
};

pub const BankSource = enum {
    Created,
    Open
};

pub const Bank = extern struct {
    const PREFIX_PROP_NAME = "prefix";
    allocator: std.mem.Allocator,
    properties: std.StringHashMap([]const u8),
    entries: std.StringHashMap(BankEntry),
    source: BankSource,
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
        options:   BankReadOptions,
        allocator: std.mem.Allocator,
    ) !Bank {
        var self = try init(prefix, allocator);
        errdefer self.deinit();

        self.buffer = try allocator.dupe(u8, input);
        self.source = BankSource.Open;

        if (path) |path_| {
            self.path = try allocator.dupe(u8, path_);
        }

        var idx: usize = 0;
        var metas_read = 0;
        var start_offset: i32 = 0;

        while (idx < input.len) {
            const name = try std.ascii.allocLowerString(allocator,
                try readString(self.buffer, options.require_terminator)
            );
            idx += name.len + 1;

            const entry_meta: BankEntryMeta = std.mem.bytesAsValue(BankEntryMeta, input[idx..][0..@sizeOf(BankEntryMeta)]).*;
            idx += @sizeOf(BankEntryMeta);

            metas_read += 1;
            if(entry_meta.isVersion() and name.len == 0 and (options.vbs2_lite or (!options.vbs2_lite and metas_read == 1))) {
                while (true) {
                    const prop_name = try readString(self.buffer, true);
                    if (prop_name.len == 0) { break; }

                    const prop_value =  try readString(self.buffer, true);

                    self.properties[prop_name] = if(prop_name == PREFIX_PROP_NAME)
                        try ensureTrailingSlash(prop_value, allocator)
                    else
                        prop_value;
                }
            } else {
                if(name.len == 0 and entry_meta.isEnd()) break;
                const offset = if (entry_meta.size_int > std.math.maxInt(i32)) {
                    if (options.signed_offsets) {
                        return error.NegativeOffset;
                    } else {
                        const size = @as(i32, @bitCast(entry_meta.size_int));
                        const malfomed = BankEntryData{ .Malformed = start_offset };
                        start_offset += size;
                        malfomed;
                    }
                } else {
                    const uninitialized = BankEntryData{ .Uninitialized = start_offset };
                    start_offset += entry_meta.size_int;
                    uninitialized;
                };

                self.entries[name] = BankEntry {
                    .named_metadata = .{
                        .name = name,
                        .meta = entry_meta,
                    },
                    .data = offset,
                };
            }
        }

        for (self.entries.iterator()) |entry| {
            const name = entry.key_ptr.*;
            const old_entry = entry.value_ptr.*;

            const new_entry = BankEntry{
                .data = switch (old_entry.data) {
                    .Loaded => |loaded| .{
                        .Loaded = .{
                            .offset = loaded.offset + idx,
                            .data = loaded.data,
                        }
                    },
                    .Uninitialized => |offset| .{
                        .Uninitialized = offset + self.buffer_offset.?,
                    },
                    .Malformed => |offset| .{
                        .Malformed = offset + @as(i64, idx),
                    },
                },
                .named_metadata = old_entry.named_metadata,
            };

            try self.inner.entries.put(name, new_entry);
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

        var entries = std.StringHashMap(BankEntry).init(allocator);
        errdefer entries.deinit();

        try properties.put(PREFIX_PROP_NAME, prefix_copy);
        
        return .{
            .allocator = allocator,
            .properties = properties,
            .source = BankSource.Created,
            .buffer = null,
            .entries = entries,
            .path = prefix_copy[0 .. prefix_copy.len - 1]
        };
    }
    
    pub fn deinit(self: *Bank) void {
        var it = self.properties.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.properties.deinit();


        it = self.entries.iterator();
        while (it.next()) |entry| {
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
