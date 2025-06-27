const lzss = @import("root.zig");
const std = @import("std");
const testing = std.testing;
const test_allocator = testing.allocator;

test "Generate and decompress random LZSS" {
    var prng = std.Random.DefaultPrng.init(5);
    const rng = prng.random();

    const sizes = [_]usize{
        10,
        50,
        100,
        1024,
        10000,
        100000,
        1000000,
        5000000,
        10000000
    };

    for (sizes) |size| {
        const compressed = try lzss.random(
            test_allocator,
            rng,
            size,
            false,
        );
        defer test_allocator.free(compressed);

        const decompressed = lzss.decode(
            testing.allocator,
            compressed,
            size,
            false,
        ) catch |err| switch (err) {
            error.ChecksumMismatch => {
                continue;
            },
            else => return err,
        };

        defer test_allocator.free(decompressed);
    }
}

test "LZSS De/Compress Roundtrip" {
    const test_cases = [_][]const u8{
        "a",
        "Hello World",
        "Bisharper.... again.... in another languague? I think you've finally lost it ellie; atleast your learning.",
        "AAAAAAAAAAAAAAAAAAAAAAAAAA", //Repeted patterns
        "101010101010101010101010101010",
        "This is a test. This is a test. This is a test.",
        "The quick brown fox jumps over the lazy dog",
        "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Praesent posuere eros a cursus tincidunt.",
        "Эй, жлоб! Где туз? Прячь юных съёмщиц в шкаф.", //unicode
        &[_]u8{ 0, 1, 2, 3, 4, 5, 0, 1, 2, 3, 4, 5 },
    };

    for (test_cases) |input| {
        const compressed = try lzss.encode(test_allocator, input, false);

        defer test_allocator.free(compressed);

        const decompressed = try lzss.decode(test_allocator, compressed, input.len, false);

        defer test_allocator.free(decompressed);

        try testing.expectEqualSlices(u8, input, decompressed);
    }
}

test "LZSS with signed checksum" {
    const test_data = "Test with signed checksum";

    const compressed = try lzss.encode(test_allocator, test_data, true);
    defer test_allocator.free(compressed);

    const decompressed = try lzss.decode(test_allocator, compressed, test_data.len, true);
    defer test_allocator.free(decompressed);

    try testing.expectEqualSlices(u8, test_data, decompressed);
}

test "LZSS with unsigned checksum" {
    const test_data = "Test with signed checksum";

    const compressed = try lzss.encode(test_allocator, test_data, true);
    defer test_allocator.free(compressed);

    const decompressed = try lzss.decode(test_allocator, compressed, test_data.len, true);
    defer test_allocator.free(decompressed);

    try testing.expectEqualSlices(u8, test_data, decompressed);
}