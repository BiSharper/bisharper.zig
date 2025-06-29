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

pub fn parse(name: []const u8, content: []const u8, allocator: Allocator) !*Root {
    const root = try database(name, allocator);
    errdefer root.release();

    const context: *Context = root.retain();
    defer context.release();

    try context.parse(content, false);

    return root;
}

pub fn createValue(value: anytype, alloc: Allocator) !Value {
    const T = @TypeOf(value);

    if (T == Value) {
        return value;
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

pub const Access = enum(i8) {
    Default = -1,
    ReadWrite = 0,
    ReadCreate = 1,
    ReadOnly = 2,
    ReadOnlyVerified = 3,

    pub fn toSyntax(self: Access, allocator: Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "access = {d};", .{@intFromEnum(self)});
    }
};

pub const AtomicUsize = std.atomic.Value(usize);

pub const ContextFlags = packed struct {
    pending_cleanup: bool = false,
    pending_delete: bool = true,
    loaded: bool = true,

    pub fn none() ContextFlags {
        return ContextFlags{};
    }
};

pub const Value = union(enum) {
    i32: i32,
    i64: i64,
    f32: f32,
    string: []u8,
    array: Array,

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

pub const Parameter = struct {
    parent: *Context,
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

pub const Root = struct {
    allocator: Allocator,
    name: []u8,
    context: *Context,

    pub fn retain(self: *Root) *Context {
        return self.context.retain();
    }

    pub fn release(self: *Root) void {
        self.context.release();
    }
};

pub const Context = struct {
    name: []const u8,
    access: Access = .Default,
    children: std.StringHashMap(*Context),
    params: std.StringHashMap(*Parameter),
    root: *Root,
    parent: ?*Context,
    base: ?*Context,
    flags: ContextFlags,

    parent_refs: []volatile *AtomicUsize,
    refs: AtomicUsize,
    derivatives: AtomicUsize,
    rw_lock: std.Thread.RwLock = .{},

    pub fn toSyntax(self: *Context, allocator: Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

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
                try result.appendSlice(param_syntax);
                try result.appendSlice("\n");
            }

            var child_it = self.children.valueIterator();
            while (child_it.next()) |child_ptr| {
                const child_syntax = try child_ptr.*.toSyntax(allocator);
                defer allocator.free(child_syntax);

                try result.appendSlice(child_syntax);
                try result.appendSlice("\n");
            }
        }

        try result.appendSlice("};");

        return result.toOwnedSlice();
    }

    pub fn parse(self: *Context, input: []const u8, protect: bool) !void {
        var index: usize = 0;
        var line: usize = 1;
        var line_start: usize = 0;

        const nodes = try AstNode.parseContext(input, &index, &line, &line_start, self.root.allocator);
        defer self.root.allocator.free(nodes);

        try self.update(nodes, protect);
    }

    pub fn retain(self: *Context) *Context {
        var old_refs = self.refs.load(.acquire);
        while (true) {
            if (old_refs == 0) {
                @panic("attempt to retain object with a zero reference count");
            }

            if (self.refs.cmpxchgWeak(
                old_refs,
                old_refs + 1,
                .acq_rel,
                .acquire,
            )) |actual_val| {
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
            @memcpy(result[pos .. pos + component.len], component);
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
        return self.addParameterUnlocked(name, value);
    }

    fn addParameterUnlocked(self: *Context, name: []const u8, value: anytype) !void {
        const alloc = self.root.allocator;

        if (std.mem.eql(u8, name, "access")) {
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
        errdefer Value.deinit(&owned_value, alloc);

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
        return self.removeParameterUnlocked(name);
    }

    fn removeParameterUnlocked(self: *Context, name: []const u8) bool {
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
        self.extendUnlocked(new_extends);
    }

    fn extendUnlocked(self: *Context, new_extends: ?*Context) void {
        if (self.base) |old_base| {
            _ = old_base.derivatives.rmw(.Sub, 1, .acq_rel);
            old_base.checkBaseCleanup();
        }

        if (new_extends) |new| {
            _ = new.derivatives.rmw(.Add, 1, .acq_rel);
            self.base = new;
        } else {
            self.base = null;
        }
    }

    pub fn retainClass(self: *Context, name: []const u8) ?*Context {
        if (self.children.get(name)) |child_ctx| {
            return child_ctx.retain();
        }
        return null;
    }

    pub fn clear(
        self: *Context,
    ) void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        self.clearUnlocked();
    }

    fn clearUnlocked(
        self: *Context,
    ) void {
        var child_iter = self.children.keyIterator();
        while (child_iter.next()) |child_ptr| {
            _ = self.removeClassUnlocked(child_ptr.*);
        }

        var param_iter = self.params.keyIterator();
        while (param_iter.next()) |param_ptr| {
            _ = self.removeParameterUnlocked(param_ptr.*);
        }

        self.access = if (self.parent) |p| p.access else .Default;
    }

    pub fn removeClass(self: *Context, name: []const u8) bool {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        return self.removeClassUnlocked(name);
    }

    fn removeClassUnlocked(self: *Context, name: []const u8) bool {
        if (self.derivatives.load(.acquire) > 0) {
            self.clearUnlocked();
        }

        if (self.children.fetchRemove(name)) |removed_entry| {
            removed_entry.value.flags.pending_delete = true;
            removed_entry.value.release();
            return true;
        }
        return false;
    }

    pub fn getOrCreateClass(self: *Context, name: []const u8, extends: ?*Context) !*Context {
        if (self.children.get(name)) |child_ctx| {
            return child_ctx.retain();
        }
        return self.createClass(name, extends);
    }

    pub fn createClass(self: *Context, name: []const u8, extends: ?*Context) !*Context {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        return self.createClassUnlocked(name, extends);
    }

    fn createClassUnlocked(self: *Context, name: []const u8, extends: ?*Context) !*Context {
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
        child_ctx.extendUnlocked(extends);

        gop.value_ptr.* = child_ctx;

        return child_ctx.retain();
    }

    const Entry = union(enum) {
        parameter: *Parameter,
        context: *Context,
    };

    fn findEntry(
        self: *Context,
        name: []const u8,
        parent: bool,
        base: bool,
    ) ?Entry {
        if (self.children.get(name)) |child| {
            return .{ .context = child };
        }

        if (self.params.get(name)) |param| {
            return .{ .parameter = param };
        }

        if (base) {
            if (self.base) |base_ctx| {
                if (base_ctx.findEntry(name, false, base)) |entry| {
                    return entry;
                }
            }
        }

        if (parent) {
            if (self.parent) |parent_ctx| {
                if (parent_ctx.findEntry(name, true, base)) |entry| {
                    return entry;
                }
            }
        }

        return null;
    }

    fn update(self: *Context, nodes: []const AstNode, protect: bool) !void {
        const access: Access = if (!protect) .ReadWrite else self.access;
        if (@intFromEnum(access) >= @intFromEnum(Access.ReadOnly)) {
            return error.AccessDenied;
        }
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        for (nodes) |node| {
            switch (node) {
                .delete => |del_name| {
                    _ = self.removeClassUnlocked(del_name);
                },
                .classs => |class_node| {
                    var child_ctx: *Context = undefined;
                    if (self.children.get(class_node.name)) |existing| {
                        child_ctx = existing.retain();
                    } else {
                        child_ctx = try self.createClassUnlocked(class_node.name, null);
                    }

                    if (class_node.extends) |extends_name| {
                        child_ctx.extendUnlocked(self.children.get(extends_name) orelse return error.BaseClassNotFound);
                    }

                    try child_ctx.update(class_node.nodes orelse &[_]AstNode{}, protect);

                    child_ctx.release();
                },
                .param => |param_node| {
                    try self.addParameterUnlocked(param_node.name, param_node.value);
                },
                .array => |array_node| {
                    switch (array_node.operator) {
                        .Add, .Sub => {
                            return error.NotImplemented;
                        },
                        .Assign => {
                            const gop = try self.params.getOrPut(array_node.name);
                            const alloc = self.root.allocator;
                            const ptr = gop.value_ptr.*;
                            if (gop.found_existing) {
                                if (ptr.value != .array) {
                                    return error.TypeMismatch;
                                }
                                ptr.value.array.clear(alloc);
                            } else {
                                const param = try alloc.create(Parameter);
                                errdefer alloc.destroy(param);
                                const owned_name = gop.key_ptr.*;
                                param.* = .{
                                    .parent = self,
                                    .name = owned_name,
                                    .value = Value{ .array = Array.init(alloc) },
                                };
                                gop.value_ptr.* = param;
                            }
                            try gop.value_ptr.*.value.array.values.appendSlice(array_node.value.values.items);
                        },
                    }
                },
            }
        }
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

const AstNode = union(enum) {
    classs: AstClass,
    param: AstParam,
    delete: []const u8,
    array: AstArray,

    pub const AstClass = struct { name: []const u8, extends: ?[]const u8, nodes: ?[]const AstNode };

    pub const AstParam = struct {
        name: []const u8,
        value: Value,
    };

    pub const AstOperator = enum {
        Add,
        Sub,
        Assign,
    };

    pub const AstArray = struct {
        name: []const u8,
        operator: AstOperator,
        value: Array,
    };

    pub fn parseContext(input: []const u8, index: *usize, line: *usize, line_start: *usize, allocator: Allocator) ![]const AstNode {
        var nodes = std.ArrayList(AstNode).init(allocator);
        while (index.* < input.len) {
            skipWhitespace(input, index, line, line_start);

            var c = input[index.*];
            if (c == '#') {
                //todo
            }

            if (c == '}') {
                index.* += 1;
                if (input[index.*] != ';') {
                    std.log.err("Error at line {}, col {}: expected ';' after class ending.", .{ line.*, index.* - line_start.* });
                    return error.SyntaxError;
                }
                index.* += 1;

                break;
            }
            var word = getAlphaWord(input, index, line, line_start);
            if (std.mem.eql(u8, word, "delete")) {
                word = getAlphaWord(input, index, line, line_start);

                skipWhitespace(input, index, line, line_start);

                if (input[index.*] != ';') {
                    std.log.err("Error at line {}, col {}: expected ';' after 'delete' statement.", .{ line.*, index.* - line_start.* });
                    return error.SyntaxError;
                }
                index.* += 1;
                try nodes.append(.{ .delete = word });
            } else if (std.mem.eql(u8, word, "class")) {
                const class_name = getAlphaWord(input, index, line, line_start);

                skipWhitespace(input, index, line, line_start);

                if (input[index.*] == ';') {
                    index.* += 1;

                    try nodes.append(.{ .classs = .{ .name = class_name, .extends = null, .nodes = null } });
                } else {
                    var extends_name: ?[]const u8 = null;
                    if (input[index.*] == ':') {
                        index.* += 1;
                        extends_name = getAlphaWord(input, index, line, line_start);
                    }
                    skipWhitespace(input, index, line, line_start);

                    if (input[index.*] != '{') {
                        if (extends_name != null) {
                            std.log.err("Error at line {}, col {}: expected '{{' after class declaration.", .{ line.*, index.* - line_start.* });
                        } else {
                            std.log.err("Error at line {}, col {}: expected ';' or '{{' after class declaration.", .{ line.*, index.* - line_start.* });
                        }
                        return error.SyntaxError;
                    }
                    index.* += 1;

                    try nodes.append(.{ .classs = .{ .name = class_name, .extends = extends_name, .nodes = try parseContext(input, index, line, line_start, allocator) } });
                }
            } else {
                if (input[index.*] == '[') {
                    index.* += 1;

                    skipWhitespace(input, index, line, line_start);

                    if (input[index.*] != ']') {
                        std.log.err("Error at line {}, col {}: expected ']' or whitespace after '['", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }
                    index.* += 1;

                    skipWhitespace(input, index, line, line_start);

                    const operator: AstNode.AstOperator = blk: switch (input[index.*]) {
                        '+' => {
                            index.* += 1;

                            if (input[index.*] != '=') {
                                std.log.err("Error at line {}, col {}: expected '=' after '+'", .{ line.*, index.* - line_start.* });
                                return error.SyntaxError;
                            }
                            index.* += 1;
                            break :blk AstNode.AstOperator.Add;
                        },
                        '-' => {
                            index.* += 1;

                            if (input[index.*] != '=') {
                                std.log.err("Error at line {}, col {}: expected '=' after '+'", .{ line.*, index.* - line_start.* });
                                return error.SyntaxError;
                            }
                            index.* += 1;
                            break :blk AstNode.AstOperator.Sub;
                        },
                        '=' => {
                            index.* += 1;
                            break :blk AstNode.AstOperator.Assign;
                        },
                        else => {
                            std.log.err("Error at line {}, col {}: expected '=', '+=', or '-=' after array name", .{ line.*, index.* - line_start.* });
                            return error.SyntaxError;
                        },
                    };
                    const array = try parseArray(input, index, line, line_start, allocator);

                    try nodes.append(.{ .array = .{ .name = word, .operator = operator, .value = array } });
                    skipWhitespace(input, index, line, line_start);

                    if (input[index.*] != ';') {
                        std.log.err("Error at line {}, col {}: expected ';' after array parameter", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }

                    index.* += 1;
                } else {
                    skipWhitespace(input, index, line, line_start);
                    if (input[index.*] != '=') {
                        std.log.err("Error at line {}, col {}: expected '=' or '[' after parameter name", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }
                    index.* += 1;

                    skipWhitespace(input, index, line, line_start);

                    var expression = false;
                    if (input[index.*] == '@') {
                        expression = true;
                    }

                    var foundQuote: bool = false;
                    const wordValue = try getWord(input, index, line, line_start, &[_]u8{ ';', '}', '\n', '\r' }, &foundQuote, allocator);

                    c = input[index.*];
                    switch (c) {
                        '}' => {
                            index.* -= 1;
                            std.log.warn("Warning at line {}, col {}: Missing ';' prior to '}}'", .{ line.*, index.* - line_start.* });
                        },
                        ';' => {
                            index.* += 1;
                        },
                        else => {
                            if (c != '\n' and c != '\r') {
                                if (!foundQuote) {
                                    std.log.err("Error at line {}, col {}: Expected ';' after parameter value", .{ line.*, index.* - line_start.* });
                                    return error.SyntaxError;
                                } else {
                                    index.* -= 1;
                                }
                            }
                            std.log.warn("Warning at line {}, col {}: Missing ';' at end of line.", .{ line.*, index.* - line_start.* });
                        },
                    }

                    if (expression) {
                        std.log.err("Error at line {}, col {}: Expressions are not yet implemented", .{ line.*, index.* - line_start.* });
                        return error.NotImplemented;
                    } else if (!foundQuote) {
                        if (wordValue.len > 7 and std.mem.eql(u8, wordValue[0..6], "__EVAL")) {
                            std.log.err("Error at line {}, col {}: Evaluate not yet implemented", .{ line.*, index.* - line_start.* });
                            return error.NotImplemented;
                        }
                        var value = try scanInt(wordValue, allocator) orelse
                            try scanInt64(wordValue, allocator) orelse
                            try scanFloat(wordValue, allocator) orelse
                            try createValue(wordValue, allocator);
                        errdefer Value.deinit(&value, allocator);

                        try nodes.append(.{ .param = .{ .name = word, .value = value } });
                    } else {
                        var value = try createValue(wordValue, allocator);
                        errdefer Value.deinit(&value, allocator);

                        try nodes.append(.{ .param = .{ .name = word, .value = value } });
                    }
                }
            }
        }

        return try nodes.toOwnedSlice();
    }

    pub fn parseArray(input: []const u8, index: *usize, line: *usize, line_start: *usize, allocator: Allocator) !Array {
        skipWhitespace(input, index, line, line_start);
        var array = Array.init(allocator);
        if (input[index.*] != '{') {
            return error.SyntaxError;
        }
        index.* += 1;

        while (true) {
            skipWhitespace(input, index, line, line_start);

            if (index.* >= input.len) {
                return error.SyntaxError;
            }
            var current_char = input[index.*];

            switch (current_char) {
                '{' => {
                    const nested_array = try parseArray(input, index, line, line_start, allocator);
                    try array.push(Value{ .array = nested_array });
                },
                '#' => {
                    std.log.err("Error at line {}, col {}: Directives not implemented", .{ line.*, index.* - line_start.* });
                    return error.NotImplemented;
                },
                '@' => {
                    var foundQuote = false;
                    _ = try getWord(input, index, line, line_start, &[_]u8{ ',', ';', '}' }, &foundQuote, allocator);
                    std.log.err("Error at line {}, col {}: Expressions not implemented", .{ line.*, index.* - line_start.* });
                    return error.NotImplemented;
                },
                '}' => {
                    index.* += 1;
                    return array;
                },
                ',' => {
                    index.* += 1;
                },
                ';' => {
                    std.log.warn("Warning at line {}, col {}: Using ';' as array separator is deprecated, use ',' instead.", .{ line.*, index.* - line_start.* });
                    index.* += 1;
                },
                else => {
                    var foundQuote = false;
                    const found = try getWord(input, index, line, line_start, &[_]u8{ ',', ';', '}' }, &foundQuote, allocator);

                    current_char = input[index.*];

                    if (current_char == ',' or current_char == ';') {
                        if (current_char == ';') {
                            std.log.warn("Warning at line {}, col {}: Using ';' as array separator is deprecated, use ',' instead.", .{ line.*, index.* - line_start.* });
                        }

                        if (!foundQuote) {
                            if (found[0] == '@') {
                                std.log.err("Error at line {}, col {}: Expressions not implemented", .{ line.*, index.* - line_start.* });
                                return error.NotImplemented;
                            }

                            if (std.mem.eql(u8, found[0..6], "__EVAL")) {
                                std.log.err("Error at line {}, col {}: Evaluate not yet implemented", .{ line.*, index.* - line_start.* });
                                return error.NotImplemented;
                            }
                            var value = try scanInt(found, allocator) orelse
                                try scanFloat(found, allocator) orelse
                                try createValue(found, allocator);
                            errdefer Value.deinit(&value, allocator);
                            try array.push(value);
                        } else {
                            var value = try createValue(found, allocator);
                            errdefer Value.deinit(&value, allocator);
                            try array.push(value);
                        }
                    }
                },
            }
        }

        return error.Unimplemented;
    }
};

fn scanHex(val: []const u8) ?i32 {
    if (val.len < 3) return null;

    if (!std.ascii.eqlIgnoreCase(val[0..2], "0x")) return null;

    const hex_part = val[2..];
    if (hex_part.len == 0) return null;

    for (hex_part) |c| {
        if (!std.ascii.isHex(c)) return null;
    }

    return std.fmt.parseInt(i32, hex_part, 16) catch null;
}

fn scanInt(input: []const u8, allocator: Allocator) !?Value {
    if (input.len == 0) return null;

    if (scanIntPlain(input)) |val| {
        return try createValue(val, allocator);
    }

    if (scanHex(input)) |val| {
        return try createValue(val, allocator);
    }

    return null;
}

fn scanIntPlain(ptr: []const u8) ?i32 {
    if (ptr.len == 0) return null;

    return std.fmt.parseInt(i32, ptr, 10) catch null;
}

fn scanInt64Plain(ptr: []const u8) ?i64 {
    if (ptr.len == 0) return null;

    return std.fmt.parseInt(i64, ptr, 10) catch null;
}

fn scanInt64(input: []const u8, allocator: Allocator) !?Value {
    if (input.len == 0) return null;

    if (scanInt64Plain(input)) |val| {
        return try createValue(val, allocator);
    }

    if (scanHex(input)) |val| {
        return try createValue(val, allocator);
    }

    return null;
}

fn scanFloatPlain(ptr: []const u8) ?f32 {
    if (ptr.len == 0) return null;

    return std.fmt.parseFloat(f32, ptr) catch null;
}

fn scanDb(ptr: []const u8) ?f32 {
    if (ptr.len < 3 or ptr[0] != 'd' or ptr[1] != 'b') return null;

    const db_part = ptr[2..];

    const db_value = std.fmt.parseFloat(f32, db_part) catch {
        std.debug.print("invalid db value {s}\n", .{ptr});
        return null;
    };

    return std.math.pow(f32, 10.0, db_value * (1.0 / 20.0));
}

fn scanFloat(ptr: []const u8, allocator: Allocator) !?Value {
    if (ptr.len == 0) return null;

    if (scanFloatPlain(ptr)) |val| {
        return try createValue(val, allocator);
    }

    if (scanDb(ptr)) |val| {
        return try createValue(val, allocator);
    }

    return null;
}

fn getWord(input: []const u8, index: *usize, line: *usize, line_start: *usize, terminators: []const u8, found_quote: *bool, allocator: Allocator) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    skipWhitespace(input, index, line, line_start);

    if (input[index.*] == '"') {
        index.* += 1;
        found_quote.* = true;
        while (index.* < input.len) {
            const c = input[index.*];
            if (c == '"') {
                index.* += 1;
                if (index.* < input.len and input[index.*] != '"') {
                    skipWhitespace(input, index, line, line_start);

                    if (index.* < input.len and input[index.*] != '\\') {
                        return try result.toOwnedSlice();
                    }
                    index.* += 1;
                    if (index.* < input.len and input[index.*] != 'n') {
                        std.log.err("Error at line {}, col {}: invalid escape sequence", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }
                    skipWhitespace(input, index, line, line_start);

                    if (index.* < input.len and input[index.*] != '"') {
                        std.log.err("Error at line {}, col {}: expected '\"' after escape sequence", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }

                    index.* += 1;
                    try result.append('\n');
                } else {
                    index.* += 1;
                    try result.append('"');
                }
            } else {
                if (c == '\n' or c == '\r') {
                    std.log.err("Error at line {}, col {}: End of line encountered", .{ line.*, index.* - line_start.* });
                    return error.SyntaxError;
                }
                try result.append(c);
                index.* += 1;
                continue;
            }
        }
        std.log.err("Error at line {}, col {}: unterminated string literal", .{ line.*, index.* - line_start.* });
        return error.SyntaxError;
    } else {
        found_quote.* = false;
        var c = input[index.*];
        while (index.* < input.len and std.mem.indexOfScalar(u8, terminators, c) == null) {
            if (c == '\n' or c == '\r') {
                while (true) {
                    skipWhitespace(input, index, line, line_start);
                    if (input[index.*] != '#') {
                        break;
                    }
                    std.log.err("Error at line {}, col {}: Directives not implemented", .{ line.*, index.* - line_start.* });
                    return error.NotImplemented;
                }
                c = input[index.*];
                if (std.mem.indexOfScalar(u8, terminators, c) == null) {
                    std.log.err("Error at line {}, col {}: Expected unquoted terminator got '{}'", .{ line.*, index.* - line_start.*, c });
                }
            } else {
                index.* += 1;
                if (index.* >= input.len) break;
                try result.append(c);
                c = input[index.*];
            }
        }

        return try result.toOwnedSlice();
    }
}

fn skipWhitespace(input: []const u8, index: *usize, line: *usize, line_start: *usize) void {
    while (index.* < input.len) {
        const c = input[index.*];
        if (c == '\n') {
            line.* += 1;
            index.* += 1;
            line_start.* = index.*;
        } else if (std.ascii.isWhitespace(c)) {
            index.* += 1;
        } else {
            break;
        }
    }
}

fn getAlphaWord(input: []const u8, index: *usize, line: *usize, line_start: *usize) []const u8 {
    skipWhitespace(input, index, line, line_start);

    const word_start = index.*;

    while (index.* < input.len) {
        const c = input[index.*];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            break;
        }
        index.* += 1;
    }

    return input[word_start..index.*];
}
