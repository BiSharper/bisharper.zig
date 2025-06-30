const std = @import("std");
const Allocator = std.mem.Allocator;

const param = @import("root.zig");

pub const AtomicUsize = std.atomic.Value(usize);

pub const Access = enum(i8) {
    Default = -1,
    ReadWrite = 0,
    ReadCreate = 1,
    ReadOnly = 2,
    ReadOnlyVerified = 3,

    pub fn toSyntax(self: Access, allocator: Allocator) Allocator.Error![]const u8 {
        return try std.fmt.allocPrint(allocator, "access = {d};\n", .{@intFromEnum(self)});
    }
};

pub const ContextFlags = packed struct {
    pending_cleanup: bool = false,
    pending_delete: bool = true,
    loaded: bool = true,

    pub fn none() ContextFlags {
        return ContextFlags{};
    }
};

// Helper to generate indentation
fn writeIndent(result: *std.ArrayList(u8), indent: usize) !void {
    for (0..indent) |_| try result.append(' ');
}

pub const Context = struct {
    name: []const u8,
    access: Access = .Default,
    children: std.StringHashMap(*Context),
    params: std.StringHashMap(*param.Parameter),
    root: *param.Root,
    parent: ?*Context,
    base: ?*Context,
    flags: ContextFlags,

    parent_refs: []volatile *AtomicUsize,
    refs: AtomicUsize,
    derivatives: AtomicUsize,
    rw_lock: std.Thread.RwLock = .{},

    pub fn toSyntax(self: *Context, allocator: Allocator, indent: usize) Allocator.Error![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();

        try writeIndent(&result, indent);
        try result.appendSlice("class ");
        try result.appendSlice(self.name);

        if (self.base) |base| {
            try result.appendSlice(" : ");
            try result.appendSlice(base.name);
        }

        try result.appendSlice(" {\n");

        const s = try self.access.toSyntax(allocator);
        defer allocator.free(s);
        if (self.access != .Default) {
            try writeIndent(&result, indent + 4);
            try result.appendSlice(s);
        }

        {
            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();

            var param_it = self.params.valueIterator();
            while (param_it.next()) |param_ptr| {
                const param_syntax = try param_ptr.*.toSyntax(allocator);
                defer allocator.free(param_syntax);
                try writeIndent(&result, indent + 4);
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

        try writeIndent(&result, indent);
        try result.appendSlice("};");

        return result.toOwnedSlice();
    }

    pub fn parse(self: *Context, input: []const u8, protect: bool) !void {
        const alloc = self.root.allocator;
        var index: usize = 0;
        var line: usize = 1;
        var line_start: usize = 0;

        const nodes = try param.AstNode.parseContext(input, &index, &line, &line_start, self.root.allocator);
        defer {
            for (nodes) |*node| {
                node.deinit(alloc);
            }
            alloc.free(nodes);
        }

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

        const par = try alloc.create(param.Parameter);
        errdefer alloc.destroy(par);

        const owned_value = try param.createValue(value, alloc);
        errdefer param.Value.deinit(&owned_value, alloc);

        par.* = .{
            .parent = self,
            .name = gop.key_ptr.*,
            .value = owned_value,
        };

        gop.value_ptr.* = par;
    }

    pub fn removeParameter(self: *Context, name: []const u8) bool {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        return self.removeParameterUnlocked(name);
    }

    fn removeParameterUnlocked(self: *Context, name: []const u8) bool {
        if (self.params.fetchRemove(name)) |removed_entry| {
            const par = removed_entry.value;
            par.deinit();
            return true;
        }
        return false;
    }

    pub fn getParameter(self: *Context, name: []const u8) ?*param.Parameter {
        self.rw_lock.lockShared();
        defer self.rw_lock.unlockShared();

        return self.params.get(name);
    }

    pub fn getValue(self: *Context, comptime T: type, name: []const u8) ?T {
        const par = self.getParameter(name) orelse return null;

        const expected_tag = comptime param.Value.typeToTag(T);

        const actual_tag = std.meta.activeTag(par.value);

        if (actual_tag == expected_tag) {
            return @field(par.value, @tagName(expected_tag));
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
            .params = std.StringHashMap(*param.Parameter).init(alloc),
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
        parameter: *param.Parameter,
        context: *Context,
    };

    fn findEntry(self: *Context, name: []const u8, parent: bool, base: bool) ?Entry {
        if (self.children.get(name)) |child| {
            return .{ .context = child };
        }

        if (self.params.get(name)) |par| {
            return .{ .parameter = par };
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

    fn update(self: *Context, nodes: []param.AstNode, protect: bool) !void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        return self.updateUnlocked(nodes, protect);
    }

    fn updateUnlocked(self: *Context, nodes: []param.AstNode, protect: bool) !void {
        const access: Access = if (!protect) .ReadWrite else self.access;
        const alloc = self.root.allocator;
        if (@intFromEnum(access) >= @intFromEnum(Access.ReadOnly)) {
            return error.AccessDenied;
        }

        for (nodes) |node| {
            switch (node) {
                .delete => |del_name| {
                    if (@intFromEnum(access) >= @intFromEnum(Access.ReadCreate)) {
                        return error.AccessDenied;
                    }
                    _ = self.removeClassUnlocked(del_name);
                },
                .class => |class_node| {
                    var child_ctx: *Context = undefined;
                    if (self.children.get(class_node.name)) |existing| {
                        child_ctx = existing.retain();
                    } else {
                        child_ctx = try self.createClassUnlocked(class_node.name, null);
                    }

                    if (class_node.extends) |extends_name| {
                        child_ctx.extendUnlocked(self.children.get(extends_name) orelse return error.BaseClassNotFound);
                    }

                    try child_ctx.updateUnlocked(class_node.nodes orelse &[_]param.AstNode{}, protect);

                    child_ctx.release();
                },
                .param => |param_node| {
                    var value_clone = try param_node.value.clone(alloc);
                    errdefer value_clone.deinit(alloc);
                    try self.addParameterUnlocked(param_node.name, value_clone);
                },
                .array => |array_node| {
                    if (@intFromEnum(access) >= @intFromEnum(Access.ReadCreate)) {
                        return error.AccessDenied;
                    }

                    switch (array_node.operator) {
                        .Add => {
                            const found: ?*param.Parameter = self.params.get(array_node.name);
                            if (found) |par| {
                                if (par.value != .array) {
                                    return error.TypeMismatch;
                                }

                                for (array_node.value.values.items) |*item| {
                                    const cloned_item: param.Value = try item.clone(alloc);
                                    try par.value.array.values.append(cloned_item);
                                }
                            } else {
                                var value_clone = try param.createValue(try array_node.value.clone(alloc), alloc);
                                errdefer value_clone.deinit(alloc);
                                try self.addParameterUnlocked(array_node.name, value_clone);
                            }
                        },
                        .Sub => {
                            return error.NotImplemented;
                        },
                        .Assign => {
                            const found: ?*param.Parameter = self.params.get(array_node.name);
                            if (found) |par| {
                                if (par.value != .array) {
                                    return error.TypeMismatch;
                                }
                                par.value.array.deinit(alloc);
                                par.value.array = try array_node.value.clone(alloc);
                            } else {
                                var value_clone = try param.createValue(try array_node.value.clone(alloc), alloc);
                                errdefer value_clone.deinit(alloc);
                                try self.addParameterUnlocked(array_node.name, value_clone);
                            }
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
