const std = @import("std");

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectError = testing.expectError;
const expectEqualStrings = testing.expectEqualStrings;

const param = @import("root.zig");

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

//document tests
test "parse param file" {
    const allocator = std.testing.allocator;
    const gameBuffer = try readFileFromParts(allocator, &.{ ".", "tests", "param", "dayz.cpp" });
    defer allocator.free(gameBuffer);

    const parsed = try param.parse("config", gameBuffer, false, allocator);
    defer parsed.release();

    const modBuffer = try readFileFromParts(allocator, &.{ ".", "tests", "param", "addMissionScript.cpp" });
    defer allocator.free(modBuffer);

    try parsed.parse(modBuffer, true);

    const patchBuffer = try readFileFromParts(allocator, &.{ ".", "tests", "param", "addMissionScript.cpp" });
    defer allocator.free(patchBuffer);

    try parsed.parse(patchBuffer, true);

    const syntax = try parsed.toSyntax(allocator);
    defer allocator.free(syntax);

    std.debug.print("{s}", .{syntax});
}

test "Context.getParameter" {
    const allocator = std.testing.allocator;

    // 1. Setup: Create a root database context for our tests
    var root = try param.database("test_db", allocator);
    defer root.release(); // Ensure cleanup after the test finishes

    const ctx = root.context;

    // 2. Add parameters of various types
    try ctx.addParameter("my_i32", @as(i32, 123));
    try ctx.addParameter("my_i64", @as(i64, 456));
    try ctx.addParameter("my_f32", @as(f32, 78.9));
    try ctx.addParameter("my_string", "hello world");
    try ctx.addParameter("my_empty_string", "");

    // 3. Test successful retrievals with correct types
    {
        const i32_val = ctx.getValue(i32, "my_i32");
        try std.testing.expect(i32_val != null);
        try std.testing.expectEqual(@as(i32, 123), i32_val.?);

        const i64_val = ctx.getValue(i64, "my_i64");
        try std.testing.expect(i64_val != null);
        try std.testing.expectEqual(@as(i64, 456), i64_val.?);

        const f32_val = ctx.getValue(f32, "my_f32");
        try std.testing.expect(f32_val != null);
        try std.testing.expectEqual(@as(f32, 78.9), f32_val.?);

        const greeting_val = ctx.getValue([]const u8, "my_string");
        try std.testing.expect(greeting_val != null); // It should NOT be null
        try std.testing.expectEqualStrings("hello world", greeting_val.?);
    }

    // 4. Test type mismatches - all should return null
    {
        const wrong_type_i32 = ctx.getValue(f32, "my_i32");
        try std.testing.expect(wrong_type_i32 == null);

        const wrong_type_f32 = ctx.getValue(i64, "my_f32");
        try std.testing.expect(wrong_type_f32 == null);

        const wrong_type_str = ctx.getValue(i32, "my_string");
        try std.testing.expect(wrong_type_str == null);
    }

    {
        const not_found = ctx.getValue(i32, "non_existent_param");
        try std.testing.expect(not_found == null);
    }
}
test "simple retain/release stress" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();

    const num_workers = 3;
    const SharedState = struct {
        ctx: *param.Context,
        iterations: usize,

        // Synchronization state
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        wait_count: usize = 0,
        thread_count: usize = num_workers + 1, // workers + main thread
    };

    var state = SharedState{
        .ctx = ctx,
        .iterations = 1000,
    };

    const Sync = struct {
        // A reusable barrier implementation.
        fn barrierWait(s: *SharedState) void {
            s.mutex.lock();
            defer s.mutex.unlock();

            s.wait_count += 1;
            if (s.wait_count < s.thread_count) {
                while (s.wait_count < s.thread_count) {
                    s.cond.wait(&s.mutex);
                }
            } else {
                s.cond.broadcast();
            }
        }
    };

    const Worker = struct {
        fn run(s: *SharedState) void {
            Sync.barrierWait(s); // Wait for the "go" signal
            var i: usize = 0;
            while (i < s.iterations) : (i += 1) {
                _ = s.ctx.retain();
                s.ctx.release();
            }
        }
    };

    var threads: [num_workers]?std.Thread = .{null} ** num_workers;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&state});
    }

    Sync.barrierWait(&state); // Unleash the workers

    for (threads) |t| {
        t.?.join();
    }

    try testing.expectEqual(@as(usize, 2), ctx.refs.load(.acquire));
    ctx.release();
}

test "hierarchical retain/release stress" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const root = try param.database("test_db", allocator);
    const root_ctx = root.retain(); // root.context ref count -> 2
    defer root_ctx.release(); // Balances the retain above

    // createClass returns a retained context, so child_ctx has ref count 1.
    const child_ctx = try root_ctx.createClass("child", null);
    defer child_ctx.release();

    // grandchild_ctx also has ref count 1.
    const grandchild_ctx = try child_ctx.createClass("grandchild", null);
    defer grandchild_ctx.release();

    const num_workers = 3;
    const SharedState = struct {
        grandchild: *param.Context,
        iterations: usize,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        wait_count: usize = 0,
        thread_count: usize = num_workers + 1,
    };

    var state = SharedState{
        .grandchild = grandchild_ctx,
        .iterations = 1000,
    };

    const Sync = struct {
        fn barrierWait(s: *SharedState) void {
            s.mutex.lock();
            defer s.mutex.unlock();
            s.wait_count += 1;
            if (s.wait_count == s.thread_count) {
                s.cond.broadcast();
            } else {
                while (s.wait_count < s.thread_count) s.cond.wait(&s.mutex);
            }
        }
    };

    const Worker = struct {
        fn run(s: *SharedState) void {
            Sync.barrierWait(s);
            var i: usize = 0;
            while (i < s.iterations) : (i += 1) {
                _ = s.grandchild.retain();
                s.grandchild.release();
            }
        }
    };

    var threads: [num_workers]?std.Thread = .{null} ** num_workers;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&state});
    }

    Sync.barrierWait(&state);

    for (threads) |t| {
        t.?.join();
    }

    // Retaining a grandchild also retains parents. The net effect of workers is 0.
    // So counts should be what they were before workers started.
    try testing.expectEqual(@as(usize, 2), grandchild_ctx.refs.load(.acquire));
    try testing.expectEqual(@as(usize, 3), child_ctx.refs.load(.acquire));
    // root_ctx has its own reference + the master reference.
    try testing.expectEqual(@as(usize, 4), root_ctx.refs.load(.acquire));

    // The three defers will run, releasing the contexts in reverse order.
    // Finally, release the master reference.
    root.release();
}

test "param.database creation and basic operations" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    try expectEqualStrings("test_db", root.name);
    try expect(root.context.parent == null);
    try expectEqual(@as(usize, 1), root.context.refs.load(.acquire));
}

test "context retain and release" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    // Test retain
    const ctx1 = root.retain();
    try expectEqual(@as(usize, 2), root.context.refs.load(.acquire));

    const ctx2 = root.retain();
    try expectEqual(@as(usize, 3), root.context.refs.load(.acquire));

    // Test release
    ctx1.release();
    try expectEqual(@as(usize, 2), root.context.refs.load(.acquire));

    ctx2.release();
    try expectEqual(@as(usize, 1), root.context.refs.load(.acquire));
}

test "parameter operations - integers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    // Add i32 parameter
    try ctx.addParameter("int32_param", @as(i32, 42));

    // Add i64 parameter
    try ctx.addParameter("int64_param", @as(i64, 1234567890123));

    // Get parameters
    const param1 = ctx.getParameter("int32_param").?;
    const param2 = ctx.getParameter("int64_param").?;

    try expectEqual(@as(i32, 42), param1.value.i32);
    try expectEqual(@as(i64, 1234567890123), param2.value.i64);

    // Test parameter paths
    const path1 = try param1.getPath(allocator);
    defer allocator.free(path1);
    try expectEqualStrings("test_db.int32_param", path1);
}

test "parameter operations - floats and strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    // Add float parameter
    try ctx.addParameter("float_param", @as(f32, 3.14));

    // Add string parameter - use a slice to avoid pointer issues
    const test_string: []const u8 = "hello world";
    try ctx.addParameter("string_param", test_string);

    // Get parameters
    const float_param = ctx.getParameter("float_param").?;
    const string_param = ctx.getParameter("string_param").?;

    try expectEqual(@as(f32, 3.14), float_param.value.f32);
    try expectEqualStrings("hello world", string_param.value.string);
}

test "parameter operations - arrays" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    // Add array parameter
    const test_array = [_]i32{ 1, 2, 3, 4, 5 };
    try ctx.addParameter("array_param", test_array);

    // Get parameter
    const array_param = ctx.getParameter("array_param").?;

    try expectEqual(@as(usize, 5), array_param.value.array.values.items.len);
    try expectEqual(@as(i32, 1), array_param.value.array.values.items[0].i32);
    try expectEqual(@as(i32, 5), array_param.value.array.values.items[4].i32);
}

test "parameter duplicate names" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    try ctx.addParameter("duplicate", 42);
    try expectError(error.ParameterAlreadyExists, ctx.addParameter("duplicate", 43));
}

test "parameter removal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    try ctx.addParameter("to_remove", 42);
    try expect(ctx.getParameter("to_remove") != null);

    try expect(ctx.removeParameter("to_remove"));
    try expect(ctx.getParameter("to_remove") == null);

    // Test removing non-existent parameter
    try expect(!ctx.removeParameter("non_existent"));
}

test "context creation and hierarchy" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const root_ctx = root.retain();
    defer root_ctx.release();

    // Create child context
    const child = try root_ctx.createClass("child", null);
    defer child.release();

    try expectEqualStrings("child", child.name);
    try expect(child.parent == root_ctx);

    // Test path generation
    const child_path = try child.getPath(allocator);
    defer allocator.free(child_path);
    try expectEqualStrings("test_db.child", child_path);

    // Create grandchild
    const grandchild = try child.createClass("grandchild", null);
    defer grandchild.release();

    const grandchild_path = try grandchild.getPath(allocator);
    defer allocator.free(grandchild_path);
    try expectEqualStrings("test_db.child.grandchild", grandchild_path);
}

test "context class retention" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const root_ctx = root.retain();
    defer root_ctx.release();

    // Create child context
    const child = try root_ctx.createClass("child", null);
    child.release(); // Release our reference, but it should still exist in parent

    // Retain the child through parent
    const child_retained = root_ctx.retainClass("child");
    try expect(child_retained != null);
    defer child_retained.?.release();

    // Test non-existent child
    const non_existent = root_ctx.retainClass("non_existent");
    try expect(non_existent == null);
}

test "context inheritance/extension" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const root_ctx = root.retain();
    defer root_ctx.release();

    // Create base context
    const base = try root_ctx.createClass("base", null);
    defer base.release();

    // Create derived context that extends base
    const derived = try root_ctx.createClass("derived", base);
    defer derived.release();

    try expect(derived.base == base);
    try expectEqual(@as(usize, 1), base.derivatives.load(.acquire));

    // Test changing extension
    const new_base = try root_ctx.createClass("new_base", null);
    defer new_base.release();

    derived.extend(new_base);
    try expect(derived.base == new_base);
    try expectEqual(@as(usize, 0), base.derivatives.load(.acquire));
    try expectEqual(@as(usize, 1), new_base.derivatives.load(.acquire));

    // Test removing extension
    derived.extend(null);
    try expect(derived.base == null);
    try expectEqual(@as(usize, 0), new_base.derivatives.load(.acquire));
}

test "supported string types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    const string_slice: []const u8 = "slice string";
    try ctx.addParameter("slice_param", string_slice);

    // Method 2: Array converted to slice
    const string_array = [_]u8{ 'a', 'r', 'r', 'a', 'y' };
    try ctx.addParameter("array_param", string_array);

    // Verify the parameters
    const slice_param = ctx.getParameter("slice_param").?;
    const array_param = ctx.getParameter("array_param").?;

    try expectEqualStrings("slice string", slice_param.value.string);
    try expectEqualStrings("array", array_param.value.string);
}

test "parameter path generation with nested arrays" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    // Create nested array parameter
    const test_array = [_]i32{ 1, 2, 3 };
    try ctx.addParameter("nested_array", test_array);

    const par = ctx.getParameter("nested_array").?;

    const element_path = try par.getInnerPath(&par.value.array.values.items[1], allocator);
    defer allocator.free(element_path);

    try expectEqualStrings("test_db.nested_array[1]", element_path);
}

test "duplicate class name error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const root_ctx = root.retain();
    defer root_ctx.release();

    const child1 = try root_ctx.createClass("duplicate_name", null);
    defer child1.release();

    try expectError(error.NameAlreadyExists, root_ctx.createClass("duplicate_name", null));
}

test "memory cleanup and reference counting" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leak detected!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);

    // Create multiple contexts and parameters
    const ctx1 = root.retain();
    const ctx2 = root.retain();

    const test_string: []const u8 = "value1";
    try ctx1.addParameter("param1", test_string);
    try ctx1.addParameter("param2", [_]i32{ 1, 2, 3, 4, 5 });

    const child = try ctx1.createClass("child", null);
    try child.addParameter("child_param", 42);

    // Release everything
    child.release();
    ctx1.release();
    ctx2.release();
    root.release();

    // If we reach here without crashes and no memory leaks, cleanup worked properly
}

test "concurrent access simulation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("test_db", allocator);
    defer root.release();

    const ctx = root.retain();
    defer ctx.release();

    // Simulate concurrent parameter operations
    try ctx.addParameter("concurrent1", 1);
    try ctx.addParameter("concurrent2", 2);
    try ctx.addParameter("concurrent3", 3);

    // Multiple gets (simulating concurrent reads)
    const param1 = ctx.getParameter("concurrent1");
    const param2 = ctx.getParameter("concurrent2");
    const param3 = ctx.getParameter("concurrent3");

    try expect(param1 != null);
    try expect(param2 != null);
    try expect(param3 != null);

    // Remove parameters
    try expect(ctx.removeParameter("concurrent1"));
    try expect(ctx.removeParameter("concurrent2"));
    try expect(ctx.removeParameter("concurrent3"));
}

test "deep hierarchy path generation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = try param.database("root", allocator);
    defer root.release();

    const root_ctx = root.retain();
    defer root_ctx.release();

    // Create deep hierarchy: root -> level1 -> level2 -> level3
    const level1 = try root_ctx.createClass("level1", null);
    defer level1.release();

    const level2 = try level1.createClass("level2", null);
    defer level2.release();

    const level3 = try level2.createClass("level3", null);
    defer level3.release();

    // Test path generation at each level
    const path1 = try level1.getPath(allocator);
    defer allocator.free(path1);
    try expectEqualStrings("root.level1", path1);

    const path2 = try level2.getPath(allocator);
    defer allocator.free(path2);
    try expectEqualStrings("root.level1.level2", path2);

    const path3 = try level3.getPath(allocator);
    defer allocator.free(path3);
    try expectEqualStrings("root.level1.level2.level3", path3);
}
