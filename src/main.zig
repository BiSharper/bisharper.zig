const bisharper = @import("root.zig");
const std = @import("std");
const param = @import("param/root.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const param_path = std.fs.path.join(allocator, &.{ ".", "tests", "param", "config.cpp"}) catch unreachable;
    defer allocator.free(param_path);

    const file = try std.fs.cwd().openFile(param_path, .{});
    defer file.close();

    const size = try file.getEndPos();

    const buffer = try allocator.alloc(u8, @intCast(size));
    defer allocator.free(buffer);

    _ = try file.readAll(buffer);

    const parsed = try param.parse("config", buffer, false, allocator);

    const context = parsed.retain();
    defer context.release();

    std.debug.print("Parsed context name: {s}\n", .{context.name});
}