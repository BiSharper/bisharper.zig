const std = @import("std");
const value_mod = @import("value.zig");
const parser = @import("parser.zig");
const ctx = @import("context.zig");

const Allocator = std.mem.Allocator;

pub const Access = ctx.Access;
pub const Value = value_mod.Value;
pub const Array = value_mod.Array;
pub const Parameter = value_mod.Parameter;
pub const AstNode = parser.AstNode;
pub const Context = ctx.Context;
pub const ContextFlags = ctx.ContextFlags;
pub const AtomicUsize = ctx.AtomicUsize;

pub const createValue = value_mod.createValue;

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

pub fn parse(name: []const u8, content: []const u8, protect: bool, allocator: Allocator) !*Root {
    const root = try database(name, allocator);
    errdefer root.release();

    try root.parse(content, protect);

    return root;
}

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

    pub fn parse(self: *Root, content: []const u8, protect: bool) !void {
        const context: *Context = self.retain();
        defer context.release();

        context.flags.loaded = false;
        defer context.flags.loaded = true;

        try context.parse(content, protect);
    }

};
