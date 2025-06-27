const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ContextFlags = packed struct {
    pending_cleanup: bool = false,

    pub fn none() ContextFlags {
        return ContextFlags{};
    }

    pub fn hasAny(self: ContextFlags, other: ContextFlags) bool {
        const self_int: u8 = @bitCast(self);
        const other_int: u8 = @bitCast(other);
        return (self_int & other_int) != 0;
    }

    pub fn hasAll(self: ContextFlags, other: ContextFlags) bool {
        const self_int: u8= @bitCast(self);
        const other_int: u8 = @bitCast(other);
        return (self_int & other_int) == other_int;
    }
};

pub fn database(name: []const u8, allocator: Allocator) !*Root {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    const file = try allocator.create(Root);
    errdefer allocator.destroy(file);

    const root_ctx = try allocator.create(Context);
    errdefer allocator.destroy(root_ctx);

    const parent_strongs = try allocator.alloc(*usize, 1);
    errdefer allocator.free(parent_strongs);

    file.* = .{
        .allocator = allocator,
        .name = name_copy,
        .context = root_ctx,
    };

    root_ctx.* = .{
        .name = file.name,
        .refs = 1,
        .derivatives = 0,
        .parent_refs = parent_strongs,
        .children = std.StringHashMap(*Context).init(allocator),
        .root = file,
        .parent = null,
        .base = null,
        .flags = ContextFlags.none(),
    };

    root_ctx.parent_refs[0] = &root_ctx.refs;

    return file;
}

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
    name:        []const u8,
    refs:        usize,
    derivatives: usize,
    parent_refs: []volatile *usize,
    children:    std.StringHashMap(*Context),
    root:        *Root,
    parent:      ?*Context,
    base:        ?*Context,
    flags:       ContextFlags,

    pub fn retain(self: *Context) *Context {
        std.debug.assert(@atomicRmw(usize, &self.refs, .Add, 1, .acq_rel) != 0);

        for(1..self.parent_refs.len) |i| {
            std.debug.assert(@atomicRmw(usize, @volatileCast(self.parent_refs[i]), .Add, 1, .acq_rel) != 0);
        }

        return self;

    }

    pub fn release(self: *Context) void {
        const old_refs = @atomicRmw(usize, &self.refs, .Sub, 1, .acq_rel);

        if (self.parent) |_| {
            for (1..self.parent_refs.len) |i| {
                std.debug.assert(@atomicRmw(usize, @volatileCast(self.parent_refs[i]), .Sub, 1, .acq_rel) != 0);
            }
        }

        if (old_refs == 1) {
            if (@atomicLoad(usize, &self.derivatives, .acquire) > 0) {
                self.flags.pending_cleanup = true;
                return;
            }

            return self.deinit();
        }

    }

    pub fn extend(self: *Context, new_extends: ?*Context) void {
        if (self.base) |old_base| {
            _ = @atomicRmw(usize, &old_base.derivatives, .Sub, 1, .acq_rel);
            old_base.checkBaseCleanup();
        }

        if(new_extends) |new| {
            _ = @atomicRmw(usize, &new.derivatives, .Add, 1, .acq_rel);
            self.base = new;
        } else{
            self.base = null;
        }

    }

    pub fn createClass(self: *Context, name: []const u8, extends: ?*Context) !*Context {
        const alloc = self.root.allocator;

        const child_ctx = try alloc.create(Context);
        errdefer alloc.destroy(child_ctx);

        const parent_strongs = try alloc.alloc(*usize, self.parent_refs.len + 1);
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
            .refs = 1,
            .derivatives = 0,
            .parent_refs = parent_strongs,
            .children = std.StringHashMap(*Context).init(alloc),
            .root = self.root,
            .parent = self,
            .base = null,
            .flags = ContextFlags.none(),
        };

        child_ctx.parent_refs[0] = &child_ctx.refs;
        child_ctx.extend(extends);

        gop.value_ptr.* = child_ctx;

        try self.children.put(owned_name, child_ctx);

        return child_ctx.retain();
    }

    fn checkBaseCleanup(self: *Context) void {
        if (@atomicLoad(usize, &self.derivatives, .acquire) == 0 and self.flags.pending_cleanup) {
            self.deinit();
        }
    }

    fn deinit(self: *Context) void {
        if (self.base) |base| {
            _ = @atomicRmw(usize, &base.derivatives, .Sub, 1, .acq_rel);

            base.checkBaseCleanup();
        }
        var iterator = self.children.valueIterator();
        while (iterator.next()) |entry| entry.*.deinit();
        self.children.deinit();

        self.root.allocator.free(@volatileCast(self.parent_refs));

        if (self.parent == null) {
            const root_ptr = self.root;
            const allocator = self.root.allocator;
            const root_name = self.root.name;

            allocator.free(root_name);
            allocator.destroy(self.root.context);
            allocator.destroy(root_ptr);
        } else if (self.parent) |parent| {
            if (parent.children.fetchRemove(self.name)) |entry|
                self.root.allocator.free(entry.key) else
                self.root.allocator.free(self.name);

            self.root.allocator.destroy(self);
        }

    }
};