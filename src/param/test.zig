const std = @import("std");
const testing = std.testing;
const smartptr = @import("zigrc");
const param = @import("root.zig");

const RefCountTests = struct {
    test "createClass with extends properly sets up references" {
        const allocator = testing.allocator;

        var root = try param.database("config", allocator);
        defer root.release();

        const rootContext = root.retain();
        defer rootContext.release();

        const child1 = try rootContext.createClass("child1", null);
        defer child1.release();

        const child2 = try rootContext.createClass("child2", child1);

        defer child2.release();

    }

    test "basic database creation and cleanup" {
        const allocator = testing.allocator;

        const root = try param.database("test_db", allocator);
        defer root.release();

        try testing.expectEqual(@as(usize, 1), root.context.refs.load(.acquire));
        try testing.expect(std.mem.eql(u8, "test_db", root.name));
        try testing.expect(root.context.parent == null);
        try testing.expect(root.context.base == null);
        try testing.expectEqual(@as(usize, 0), root.context.derivatives.load(.acquire));
    }


    test "createClass allocation failure" {
        const allocator = testing.allocator;

        var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
        const root = try param.database("root", allocator);

        root.allocator = failing_allocator.allocator();
        const result = root.context.createClass("fail", null);

        try testing.expectError(error.OutOfMemory, result);

        root.allocator = allocator;
        root.release();
    }

    test "parent reference propagation" {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const root = try param.database("test_db", allocator);
        defer root.release();

        const parent = try root.context.createClass("Parent", null);
        defer parent.release();

        const child = try parent.createClass("Child", null);
        defer child.release();

        // Child should have parent refs for both root and parent
        try testing.expectEqual(@as(usize, 3), child.parent_refs.len); // self + root + parent

        // Retain child should increment all parent refs
        const initial_root_refs = root.context.refs;
        const initial_parent_refs = parent.refs;

        const retained_child = child.retain();
        defer retained_child.release();

        // Parent refs should be incremented (starting from index 1)
        try testing.expectEqual(initial_root_refs.load(.acquire) + 1, root.context.refs.load(.acquire));
        try testing.expectEqual(initial_parent_refs.load(.acquire) + 1, parent.refs.load(.acquire));
    }


    test "base context should not deinit while derivatives exist" {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        // Create root database
        const root = try param.database("test_db", allocator);
        defer root.release();

        const root_context = root.retain();
        defer root_context.release();

        const base_ctx = try root_context.createClass("BaseClass", null);

        const derived_ctx = try root_context.createClass("DerivedClass", base_ctx);

        derived_ctx.release();

        base_ctx.release();

    }

    test "memory leak detection helper" {
        var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
        defer {
            const leaked = gpa.deinit();
            std.testing.expect(leaked == .ok) catch {
                std.debug.print("Memory leak detected!\n", .{});
            };
        }
        const allocator = gpa.allocator();

        // Run a complex scenario and ensure everything is cleaned up
        const root = try param.database("leak_test", allocator);

        const classes = [_]*param.Context{
            try root.context.createClass("A", null),
            try root.context.createClass("B", null),
            try root.context.createClass("C", null),
        };

        classes[1].extend(classes[0]);
        classes[2].extend(classes[1]);

        const nested = try classes[0].createClass("Nested", classes[2]);

        // Clean up everything
        nested.release();
        for (classes) |class| {
            class.release();
        }
        root.release();

        // If we reach here without the allocator detecting leaks, we're good
    }
};

const MultithreadTests = struct {
    const ThreadContext = struct {
        root_ctx: *param.Context,
        iterations: usize,
    };


    test "Concurrent retain and release" {
        var root_db = try param.database("test_db", testing.allocator);
        defer root_db.release();

        const root_ctx = root_db.retain();
        defer root_ctx.release();

        const iterations = 100_000;
        const num_threads = 4;
        try testing.expectEqual(2, root_ctx.refs.load(.acquire));

        var threads: [num_threads]std.Thread = undefined;
        var thread_contexts: [num_threads]ThreadContext = undefined;

        const retain_worker = struct {
            fn retain_worker(ctx: *ThreadContext) void {
                var i: usize = 0;
                while (i < ctx.iterations) : (i += 1) {
                    _ = ctx.root_ctx.retain();
                }
            }
        }.retain_worker;

        const release_worker = struct {
            fn release_worker(ctx: *ThreadContext) void {
                var i: usize = 0;
                while (i < ctx.iterations) : (i += 1) {
                    ctx.root_ctx.release();
                }
            }
        }.release_worker;

        for (0..num_threads) |i| {
            thread_contexts[i] = .{ .root_ctx = root_ctx, .iterations = iterations };
            if (i % 2 == 0) {
                threads[i] = try std.Thread.spawn(.{}, retain_worker, .{&thread_contexts[i]});
            } else {
                threads[i] = try std.Thread.spawn(.{}, release_worker, .{&thread_contexts[i]});
            }
        }

        for (&threads) |*t| {
            t.join();
        }
        try testing.expectEqual(@as(usize, 2), root_ctx.refs.load(.acquire));
    }
};

// Run all tests
test {
    //
    std.testing.refAllDecls(RefCountTests);
    // std.testing.refAllDecls(MultithreadTests);
}
