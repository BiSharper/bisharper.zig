const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn database(name: []const u8, allocator: Allocator) !*Root {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    const file = try allocator.create(Root);
    errdefer allocator.destroy(file);

    const root_ctx = try allocator.create(Context);
    errdefer allocator.destroy(root_ctx);

    const parent_strongs = try allocator.alloc(*AtomicUsize, 1);
    errdefer allocator.free(parent_strongs);

    file.* = .{
        .allocator = allocator,
        .name = name_copy,
        .context = root_ctx,
    };

    root_ctx.* = .{
        .name = file.name,
        .refs = AtomicUsize.init(1),
        .derivatives = AtomicUsize.init(0),
        .parent_refs = parent_strongs,
        .children = std.StringHashMap(*Context).init(allocator),
        .params = std.StringHashMap(*Parameter).init(allocator),
        .root = file,
        .parent = null,
        .base = null,
        .flags = ContextFlags.none(),
    };

    root_ctx.parent_refs[0] = &root_ctx.refs;

    return file;
}

pub fn createValue(value: anytype, alloc: Allocator) !Value {
    const T = @TypeOf(value);
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

pub const Access = enum(i8) {
    Default = -1,
    ReadWrite,
    ReadCreate,
    ReadOnly,
    ReadOnlyVerified,

    pub fn toSyntax(self: Access, allocator: Allocator) ![]const u8 {
        try std.fmt.allocPrint(allocator, "access = {d};", .{@intFromEnum(self)});
    }
};

pub const AtomicUsize = std.atomic.Value(usize);

pub const ContextFlags = packed struct {
    pending_cleanup: bool = false,
    loaded:          bool = true,

    pub fn none() ContextFlags {
        return ContextFlags{};
    }
};

pub const Value = union(enum) {
    i32:    i32,
    i64:    i64,
    f32:    f32,
    string: []u8,
    array:  Array,

    fn deinit(self: *Value, alloc: Allocator) void {
        switch (self.*) {
            .string => |str| alloc.free(str),
            .array => |arr| {
                for (arr.values.items) |*item| {
                    item.deinit(alloc);
                }
                arr.values.deinit();
            },
            // i32, i64, f32 don't need deinitialization
            .i32, .i64, .f32 => {},
        }
    }

    fn typeToTag(comptime T: type) std.meta.Tag(Value) {
        return comptime blk: {
            if (T == i32) break :blk .i32;
            if (T == i64) break :blk .i64;
            if (T == f32) break :blk .f32;
            if (std.meta.eql(T, []const u8) or std.meta.eql(T, []u8)) break :blk .string;
            if (std.meta.eql(T, Array)) break :blk .array;
            @compileError("Unsupported type for typeToTag: " ++ @typeName(T));
        };
    }

    pub fn toSyntax(self: *Value, allocator: Allocator) ![]u8 {
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

pub const Array = struct {
    values: std.ArrayList(Value),

    pub fn push(self: *Array, value: Value) !void {
        try self.values.append(value);
    }

    pub fn toSyntax(self: *Array, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.append('{');

        for (self.values.items, 0..) |item, index| {
            if (index > 0) {
                try result.append(',');
            }
            const next_slice = item.toSyntax(allocator);
            try result.appendSlice(next_slice);
            allocator.free(next_slice);
        }

        try result.append(']');

        return result.toOwnedSlice();
    }
};

pub const Parameter = struct {
    parent:      *Context,
    name:        []const u8,
    value:       Value,

    pub fn toSyntax(self: *Parameter, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try result.appendSlice(self.name);

        if(self.value == .array) {
            try result.append("[]");
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

        @memcpy(result[pos..pos + parent_path.len], parent_path);
        pos += parent_path.len;

        result[pos] = '.';
        pos += 1;

        @memcpy(result[pos..pos + self.name.len], self.name);
        pos += self.name.len;

        if (value_suffix) |suffix| {
            @memcpy(result[pos..pos + suffix.len], suffix);
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

pub const Root = struct {
    allocator: Allocator,
    name:      []u8,
    context:   *Context,

    pub fn retain(self: *Root) *Context {
        return self.context.retain();
    }

    pub fn release(self: *Root) void {
        self.context.release();
    }

};

pub const Context = struct {
    name:          []const u8,
    access:        Access = .Default,
    children:      std.StringHashMap(*Context),
    params:        std.StringHashMap(*Parameter),
    root:          *Root,
    parent:        ?*Context,
    base:          ?*Context,
    flags:         ContextFlags,

    parent_refs:   []volatile *AtomicUsize,
    refs:          AtomicUsize,
    derivatives:   AtomicUsize,
    rw_lock:       std.Thread.RwLock = .{},


    pub fn toSyntax(self: *Context, allocator: Allocator, indent: usize) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        const indent_str = try std.fmt.allocPrint(allocator, "{s}", .{std.mem.repeat(u8, ' ', indent)});
        defer allocator.free(indent_str);

        try result.appendSlice(indent_str);
        try result.appendSlice("class ");
        try result.appendSlice(self.name);

        if (self.base) |base| {
            try result.appendSlice(" : ");
            try result.appendSlice(base.name);
        }

        try result.appendSlice(" {\n");

        const s = try self.access.toSyntax(allocator);
        defer allocator.free(s);
        try result.appendSlice(s);

        {
            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();

            var param_it = self.params.valueIterator();
            while (param_it.next()) |param_ptr| {
                const param_syntax = try param_ptr.*.toSyntax(allocator);
                defer allocator.free(param_syntax);

                try result.appendSlice(indent_str);
                try result.appendSlice("    ");
                try result.appendSlice(param_syntax);
                try result.appendSlice("\n");
            }

            var child_it = self.children.valueIterator();
            while (child_it.next()) |child_ptr| {
                const child_syntax = try child_ptr.*.toSyntax(allocator, indent + 4);
                defer allocator.free(child_syntax);

                try result.appendSlice(child_syntax);
                try result.appendSlice("\n");
            }
        }

        try result.appendSlice(indent_str);
        try result.appendSlice("};");

        return result.toOwnedSlice();
    }

    pub fn retain(self: *Context) *Context {
        var old_refs = self.refs.load(.acquire);
        while (true) {
            if (old_refs == 0) {
                @panic("attempt to retain object with a zero reference count");
            }

            if(self.refs.cmpxchgWeak(
                old_refs,
                old_refs + 1,
                .acq_rel,
                .acquire,
            )) | actual_val | {
                old_refs = actual_val;
            } else break;
        }

        for (1..self.parent_refs.len) |i| {
            _ = @volatileCast(self.parent_refs[i]).rmw(.Add, 1, .acq_rel);
        }

        return self;
    }

    pub fn getPath(self: *Context, allocator: Allocator) ![]u8 {
        var path_components = std.ArrayList([]const u8).init(allocator);
        defer path_components.deinit();

        var current: ?*Context = self;
        while (current) |ctx| {
            try path_components.append(ctx.name);
            current = ctx.parent;
        }

        std.mem.reverse([]const u8, path_components.items);

        var total_len: usize = 0;
        for (path_components.items, 0..) |component, i| {
            total_len += component.len;
            if (i < path_components.items.len - 1) total_len += 1;
        }

        var result = try allocator.alloc(u8, total_len);
        var pos: usize = 0;

        for (path_components.items, 0..) |component, i| {
            @memcpy(result[pos..pos + component.len], component);
            pos += component.len;
            if (i < path_components.items.len - 1) {
                result[pos] = '.';
                pos += 1;
            }
        }

        return result;
    }

    pub fn addParameter(self: *Context, name: []const u8, value: anytype) !void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        const alloc = self.root.allocator;

        if(std.mem.eql(u8, name, "access")) {
            return error.ReservedParameterName;
        }

        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);

        const gop = try self.params.getOrPut(owned_name);
        if (gop.found_existing) {
            return error.ParameterAlreadyExists;
        }

        const param = try alloc.create(Parameter);
        errdefer alloc.destroy(param);

        const owned_value = try createValue(value, alloc);
        errdefer Parameter.deinitValue(&owned_value, alloc);

        param.* = .{
            .parent = self,
            .name = gop.key_ptr.*,
            .value = owned_value,
        };

        gop.value_ptr.* = param;
    }

    pub fn removeParameter(self: *Context, name: []const u8) bool {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        if (self.params.fetchRemove(name)) |removed_entry| {
            const param = removed_entry.value;
            param.deinit();
            return true;
        }
        return false;
    }

    pub fn getParameter(self: *Context, name: []const u8) ?*Parameter {
        self.rw_lock.lockShared();
        defer self.rw_lock.unlockShared();

        return self.params.get(name);
    }

    pub fn getValue(self: *Context, comptime T: type, name: []const u8) ?T {
        const param = self.getParameter(name) orelse return null;

        const expected_tag = comptime Value.typeToTag(T);

        const actual_tag = std.meta.activeTag(param.value);

        if (actual_tag == expected_tag) {
            return @field(param.value, @tagName(expected_tag));
        } else {
            return null;
        }
    }

    pub fn release(self: *Context) void {
        const old_refs = self.refs.rmw(.Sub, 1, .acq_rel);
        std.debug.assert(old_refs != 0);

        for (1..self.parent_refs.len) |i| {
            std.debug.assert(@volatileCast(self.parent_refs[i]).rmw(.Sub, 1, .acq_rel) != 0);
        }

        if (old_refs == 1) {
            if (self.derivatives.load(.acquire) > 0) {
                self.flags.pending_cleanup = true;
                return;
            }

            return self.deinit();
        }

    }

    pub fn extend(self: *Context, new_extends: ?*Context) void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        if (self.base) |old_base| {
            _ = old_base.derivatives.rmw(.Sub, 1, .acq_rel);
            old_base.checkBaseCleanup();
        }

        if(new_extends) |new| {
            _ = new.derivatives.rmw(.Add, 1, .acq_rel);
            self.base = new;
        } else{
            self.base = null;
        }

    }

    pub fn retainClass(self: *Context, name: []const u8) ?*Context {
        if (self.children.get(name)) |child_ctx| {
            return child_ctx.retain();
        }
        return null;
    }

    pub fn createClass(self: *Context, name: []const u8, extends: ?*Context) !*Context {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        const alloc = self.root.allocator;

        const child_ctx = try alloc.create(Context);
        errdefer alloc.destroy(child_ctx);

        const parent_strongs = try alloc.alloc(*AtomicUsize, self.parent_refs.len + 1);
        errdefer alloc.free(parent_strongs);

        @memcpy(parent_strongs[1..], self.parent_refs);

        const owned_name = try alloc.dupe(u8, name);
        const gop = try self.children.getOrPut(owned_name);
        if (gop.found_existing) {
            alloc.free(owned_name);
            return error.NameAlreadyExists;
        }

        child_ctx.* = .{
            .name = gop.key_ptr.*,
            .refs = AtomicUsize.init(1),
            .derivatives = AtomicUsize.init(0),
            .parent_refs = parent_strongs,
            .children = std.StringHashMap(*Context).init(alloc),
            .params = std.StringHashMap(*Parameter).init(alloc),
            .root = self.root,
            .parent = self,
            .base = null,
            .flags = ContextFlags.none(),
        };

        child_ctx.parent_refs[0] = &child_ctx.refs;
        child_ctx.extend(extends);

        gop.value_ptr.* = child_ctx;

        return child_ctx.retain();
    }

    fn checkBaseCleanup(self: *Context) void {
        if (self.derivatives.load(.acquire) == 0 and self.flags.pending_cleanup) {
            self.deinit();
        }
    }

    fn deinit(self: *Context) void {
        if (self.base) |base| {
            _ = base.derivatives.rmw(.Sub, 1, .acq_rel);
            base.checkBaseCleanup();
        }

        var children_to_deinit = std.ArrayList(*Context).init(self.root.allocator);
        defer children_to_deinit.deinit();

        {
            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();
            var it = self.children.valueIterator();
            while (it.next()) |child_ptr| {
                children_to_deinit.append(child_ptr.*) catch @panic("OOM in deinit");
            }
        }

        for (children_to_deinit.items) |child| {
            child.deinit();
        }

        {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();

            std.debug.assert(self.children.count() == 0);
            self.children.deinit();

            var param_it = self.params.valueIterator();
            while (param_it.next()) |param_ptr| {
                param_ptr.*.deinit();
            }

            self.params.deinit();
        }

        self.root.allocator.free(@volatileCast(self.parent_refs));

        if (self.parent) |parent| {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();

            if (parent.children.fetchRemove(self.name)) |removed_entry| {
                self.root.allocator.free(removed_entry.key);
            }
            self.root.allocator.destroy(self);
        } else {
            const root_ptr = self.root;
            const allocator = self.root.allocator;

            allocator.free(self.root.name);
            allocator.destroy(self.root.context);
            allocator.destroy(root_ptr);
        }

    }
};