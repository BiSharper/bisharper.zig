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
pub const AtomicUsize = std.atomic.Value(usize);
pub const Context = struct {
    name:        []const u8,
    children:    std.StringHashMap(*Context),
    root:        *Root,
    parent:      ?*Context,
    base:        ?*Context,
    flags:       ContextFlags,

    parent_refs: []volatile *AtomicUsize,
    refs:        AtomicUsize,
    derivatives: AtomicUsize,
    mutex:       std.Thread.Mutex = .{},

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
        self.mutex.lock();
        defer self.mutex.unlock();
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
        self.mutex.lock();
        defer self.mutex.unlock();

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

        if (self.parent) |parent| {
            parent.mutex.lock();
            defer parent.mutex.unlock();

            if (parent.children.fetchRemove(self.name)) |removed_entry| {
                self.root.allocator.free(removed_entry.key);
            }
        }


        var children_to_deinit = std.ArrayList(*Context).init(self.root.allocator);
        defer children_to_deinit.deinit();

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            var it = self.children.valueIterator();
            while (it.next()) |child_ptr| {
                children_to_deinit.append(child_ptr.*) catch @panic("OOM in deinit");
            }
        }

        for (children_to_deinit.items) |child| {
            child.deinit();
        }

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.children.count() == 0);
            self.children.deinit();
        }

        self.root.allocator.free(@volatileCast(self.parent_refs));

        if (self.parent) |parent| {
            parent.mutex.lock();
            defer parent.mutex.unlock();

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