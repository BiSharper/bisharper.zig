const bisharper = @import("root.zig");
const std = @import("std");
const param = @import("param/root.zig");

pub fn readFileContents(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const size = try file.getEndPos();
    const buffer = try allocator.alloc(u8, @intCast(size));
    _ = try file.readAll(buffer);

    return buffer;
}

pub fn readFileFromParts(allocator: std.mem.Allocator, path_parts: []const []const u8) ![]u8 {
    const file_path = try std.fs.path.join(allocator, path_parts);
    defer allocator.free(file_path);

    return readFileContents(allocator, file_path);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const mainBuffer = try readFileFromParts(allocator, &.{ ".", "tests", "param", "dayz.cpp" });
    defer allocator.free(mainBuffer);

    const parsed = try param.parse("config", mainBuffer, false, allocator);
    defer parsed.release();
    //
    // const addMissionScriptBuffer = try readFileFromParts(allocator, &.{ ".", "tests", "param", "addMissionScript.cpp" });
    // defer allocator.free(addMissionScriptBuffer);
    //
    // try parsed.parse(addMissionScriptBuffer, true);

    const syntax = try parsed.toSyntax(allocator);
    defer allocator.free(syntax);

    std.debug.print("{s}", .{syntax});

}