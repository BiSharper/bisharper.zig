const std = @import("std");
const Allocator = std.mem.Allocator;
const param = @import("root.zig");

pub const Parameter = struct {
    parent: *param.Context,
    name: []const u8,
    value: Value,

    pub fn toSyntax(self: *Parameter, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.appendSlice(self.name);

        if (self.value == .array) {
            try result.appendSlice("[]");
        }

        try result.appendSlice(" = ");

        const value_syntax = try self.value.toSyntax(allocator);
        defer allocator.free(value_syntax);

        try result.appendSlice(value_syntax);
        try result.append(';');

        return result.toOwnedSlice();
    }

    pub fn getPath(self: *Parameter, allocator: Allocator) ![]u8 {
        return self.getInnerPath(&self.value, allocator);
    }

    pub fn getInnerPath(self: *Parameter, value: *const Value, allocator: Allocator) ![]u8 {
        const parent_path = try self.parent.getPath(allocator);
        defer allocator.free(parent_path);

        const value_suffix = try self.findInnerPath(&self.value, value, allocator);
        defer if (value_suffix) |suffix| allocator.free(suffix);

        const total_len = parent_path.len + 1 + self.name.len + (if (value_suffix) |suffix| suffix.len else 0);
        var result = try allocator.alloc(u8, total_len);

        var pos: usize = 0;

        @memcpy(result[pos .. pos + parent_path.len], parent_path);
        pos += parent_path.len;

        result[pos] = '.';
        pos += 1;

        @memcpy(result[pos .. pos + self.name.len], self.name);
        pos += self.name.len;

        if (value_suffix) |suffix| {
            @memcpy(result[pos .. pos + suffix.len], suffix);
        }

        return result;
    }

    fn findInnerPath(self: *Parameter, current_value: *const Value, target_value: *const Value, allocator: Allocator) !?[]u8 {
        if (current_value == target_value) {
            return null;
        }

        switch (current_value.*) {
            .array => |arr| {
                for (arr.values.items, 0..) |*item, index| {
                    if (item == target_value) {
                        return try std.fmt.allocPrint(allocator, "[{d}]", .{index});
                    }

                    if (try self.findInnerPath(item, target_value, allocator)) |nested_path| {
                        defer allocator.free(nested_path);
                        return try std.fmt.allocPrint(allocator, "[{d}]{s}", .{ index, nested_path });
                    }
                }
            },
            .i32, .i64, .f32, .string => {},
        }

        return null;
    }

    pub fn deinit(self: *Parameter) void {
        const allocator = self.parent.root.allocator;
        allocator.free(self.name);
        self.value.deinit(allocator);
        allocator.destroy(self);
    }
};

pub const Array = struct {
    values: std.ArrayList(Value),

    pub fn push(self: *Array, value: Value) !void {
        try self.values.append(value);
    }

    pub fn init(allocator: Allocator) Array {
        return Array{
            .values = std.ArrayList(Value).init(allocator),
        };
    }

    pub fn clone(self: *const Array, allocator: Allocator) Allocator.Error!Array {
        var new_array = Array.init(allocator);
        errdefer new_array.deinit(allocator);

        try new_array.values.ensureTotalCapacity(self.values.items.len);
        for (self.values.items) |*item| {
            const cloned_item: Value = try item.clone(allocator);
            new_array.values.appendAssumeCapacity(cloned_item);
        }
        return new_array;
    }

    pub fn deinit(self: *Array, allocator: Allocator) void {
        for (self.values.items) |*item| {
            item.deinit(allocator);
        }
        self.values.deinit();
    }

    fn clear(self: *Array, allocator: Allocator) void {
        for (self.values.items) |*item| {
            item.deinit(allocator);
        }
        self.values.clearAndFree();
    }

    pub fn toSyntax(self: *const Array, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.append('{');

        for (self.values.items, 0..) |item, index| {
            if (index > 0) {
                try result.append(',');
            }
            const next_slice = try item.toSyntax(allocator);
            try result.appendSlice(next_slice);
            allocator.free(next_slice);
        }

        try result.append(']');

        return result.toOwnedSlice();
    }
};

pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    string: []u8,
    array: Array,

    pub fn clone(self: *const Value, alloc: Allocator) Allocator.Error!Value {
        return switch (self.*) {
            .i32 => |v| Value{ .i32 = v },
            .i64 => |v| Value{ .i64 = v },
            .f32 => |v| Value{ .f32 = v },
            .string => |s| Value{ .string = try alloc.dupe(u8, s) },
            .array => |arr| Value{ .array = try arr.clone(alloc) },
        };
    }

    pub fn deinit(self: *Value, alloc: Allocator) void {
        switch (self.*) {
            .string => |str| alloc.free(str),
            .array => |*arr| arr.deinit(alloc),
            .i32, .i64, .f32 => {},
        }
    }

    pub fn typeToTag(comptime T: type) std.meta.Tag(Value) {
        return comptime blk: {
            if (T == i32) break :blk .i32;
            if (T == i64) break :blk .i64;
            if (T == f32) break :blk .f32;
            if (std.meta.eql(T, []const u8) or std.meta.eql(T, []u8)) break :blk .string;
            if (std.meta.eql(T, Array)) break :blk .array;
            @compileError("Unsupported type for typeToTag: " ++ @typeName(T));
        };
    }

    pub fn toSyntax(self: *const Value, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        switch (self.*) {
            .i32 => |v| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(s);
                try result.appendSlice(s);
            },
            .i64 => |v| {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                defer allocator.free(s);
                try result.appendSlice(s);
            },
            .f32 => |v| {
                const s = try std.fmt.allocPrint(allocator, "{.6}", .{v});
                defer allocator.free(s);
                try result.appendSlice(s);
            },
            .string => |s| {
                try result.append('"');
                for (s) |c| {
                    switch (c) {
                        '"' => try result.appendSlice("\"\""),
                        '\n' => try result.appendSlice("\" \\n \""),
                        else => try result.append(c),
                    }
                }
                try result.append('"');
            },
            .array => |arr| {
                const arr_syntax = try arr.toSyntax(allocator);
                defer allocator.free(arr_syntax);
                try result.appendSlice(arr_syntax);
            },
        }

        return result.toOwnedSlice();
    }
};

pub fn createValue(value: anytype, alloc: Allocator) !Value {
    const T = @TypeOf(value);

    if (T == Value) {
        return value;
    }

    if (T == Array) {
        return Value{ .array = value };
    }

    const type_info = @typeInfo(T);
    switch (type_info) {
        .int => |int_info| {
            if (int_info.bits <= 32) {
                return Value{ .i32 = @intCast(value) };
            } else {
                return Value{ .i64 = @intCast(value) };
            }
        },
        .comptime_int => {
            if (value <= std.math.maxInt(i32) and value >= std.math.minInt(i32)) {
                return Value{ .i32 = @intCast(value) };
            } else {
                return Value{ .i64 = @intCast(value) };
            }
        },
        .float, .comptime_float => {
            return Value{ .f32 = @floatCast(value) };
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (ptr_info.child == u8) {
                        // This handles []u8
                        const owned_str = try alloc.dupe(u8, value);
                        return Value{ .string = owned_str };
                    } else {
                        // This handles []T
                        var array_list = std.ArrayList(Value).init(alloc);
                        errdefer array_list.deinit();
                        for (value) |item| {
                            const item_value = try createValue(item, alloc);
                            try array_list.append(item_value);
                        }
                        return Value{ .array = .{ .values = array_list } };
                    }
                },
                .many, .one => {
                    const Pointee = ptr_info.child;
                    const pointee_info = @typeInfo(Pointee);

                    // Handles *u8 (C-style string)
                    if (ptr_info.child == u8) {
                        const len = std.mem.len(value);
                        const owned_str = try alloc.dupe(u8, value[0..len]);
                        return Value{ .string = owned_str };
                    }

                    // Handles *[N]T (pointer to an array)
                    if (pointee_info == .array) {
                        // Handles *[N]u8 (Zig string literal)
                        if (pointee_info.array.child == u8) {
                            // value.* dereferences the pointer to get the array.
                            // &value.* creates a slice from that array.
                            const slice = &value.*;
                            const owned_str = try alloc.dupe(u8, slice);
                            return Value{ .string = owned_str };
                        } else {
                            // Handles *[N]T where T is not u8
                            var array_list = std.ArrayList(Value).init(alloc);
                            errdefer array_list.deinit();
                            // Iterate over the dereferenced array
                            for (value.*) |item| {
                                const item_value = try createValue(item, alloc);
                                try array_list.append(item_value);
                            }
                            return Value{ .array = .{ .values = array_list } };
                        }
                    }
                    @compileError("Unsupported pointer to one/many type: " ++ @typeName(T));
                },
                else => @compileError("Unsupported pointer type for parameter value"),
            }
        },
        .array => |array_info| {
            if (array_info.child == u8) {
                const owned_str = try alloc.dupe(u8, value[0..]);
                return Value{ .string = owned_str };
            } else {
                var array_list = std.ArrayList(Value).init(alloc);
                errdefer array_list.deinit();

                for (value) |item| {
                    const item_value = try createValue(item, alloc);
                    try array_list.append(item_value);
                }

                return Value{ .array = .{ .values = array_list } };
            }
        },
        else => @compileError("Unsupported type for parameter value: " ++ @typeName(T)),
    }
}
