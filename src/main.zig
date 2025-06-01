const std = @import("std");
const bisharper = @import("bisharper.zig");
lol: i32,
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();


    var prng = std.rand.DefaultPrng.init(5);
    const rng = prng.random();
    const random_data_size = 100 * 1024 * 1024;

    const compressed = try bisharper.lzss.random(
        allocator,
        rng,
        random_data_size,
        false,
    );
    defer allocator.free(compressed);
    try writeFile("compressed.bin", compressed);

    const decompressed = try bisharper.lzss.decode(allocator, compressed, random_data_size, false);
    defer allocator.free(decompressed);
    try writeFile("decompressed.bin", decompressed);
}

fn writeFile(filename: []const u8, data: []const u8) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    try file.writeAll(data);
}
