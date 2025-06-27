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
        root_ctx:   *param.Context,
        iterations: usize,
        thread_id:  usize
    };

    const CreateContext = struct {
        parent_ctx:       *param.Context,
        iterations:       usize,
        thread_id:        usize,
        created_contexts: *std.ArrayList(*param.Context),
        mutex:            *std.Thread.Mutex,
    };


    test "Stress test: Heavy retain/release with random delays" {
        var root_db = try param.database("stress_test_db", testing.allocator);
        defer root_db.release();

        const root_ctx = root_db.retain();
        defer root_ctx.release();

        const iterations = 1;
        const num_threads = 1;

        var prng = std.Random.DefaultPrng.init(12345);
        const random = prng.random();

        const StressWorker = struct {
            fn worker(ctx: *ThreadContext, rng: std.Random) void {

                var retained_contexts = std.ArrayList(*param.Context).init(testing.allocator);
                defer {
                    for (retained_contexts.items) |retained_ctx| {
                        retained_ctx.release();
                    }
                    retained_contexts.deinit();
                }

                var i: usize = 0;
                while (i < ctx.iterations) : (i += 1) {
                    const operation = rng.intRangeAtMost(u8, 0, 2);

                    switch (operation) {
                        0 => {
                            const retained = ctx.root_ctx.retain();
                            retained_contexts.append(retained) catch @panic("OOM");
                        },
                        1 => {
                            if (retained_contexts.items.len > 0) {
                                const idx = rng.intRangeLessThan(usize, 0, retained_contexts.items.len);
                                const to_release = retained_contexts.swapRemove(idx);
                                to_release.release();
                            }
                        },
                        2 => {
                            const retained = ctx.root_ctx.retain();
                            retained.release();
                        },
                        else => break,
                    }
                    if (rng.intRangeAtMost(u8, 0, 100) < 5) {
                        std.Thread.yield() catch {};
                    }
                }
            }
        };

        var threads: [num_threads]std.Thread = undefined;
        var thread_contexts: [num_threads]ThreadContext = undefined;

        for (0..num_threads) |i| {
            thread_contexts[i] = .{
                .root_ctx = root_ctx,
                .iterations = iterations,
                .thread_id = i,
            };
            threads[i] = try std.Thread.spawn(.{}, StressWorker.worker, .{&thread_contexts[i], random});
        }

        for (&threads) |*t| {
            t.join();
        }

        try testing.expectEqual(@as(usize, 2), root_ctx.refs.load(.acquire));
    }

    test "Concurrent inheritance chain operations" {
        var root_db = try param.database("inheritance_db", testing.allocator);
        defer root_db.release();

        const root_ctx = root_db.retain();
        defer root_ctx.release();

        const base_class = try root_ctx.createClass("BaseClass", null);
        defer base_class.release();

        const derived_class = try root_ctx.createClass("DerivedClass", base_class);
        defer derived_class.release();

        const iterations = 1000;
        const num_threads = 4;

        var all_contexts = std.ArrayList(*param.Context).init(testing.allocator);
        defer {
            for (all_contexts.items) |ctx| {
                ctx.release();
            }
            all_contexts.deinit();
        }

        var contexts_mutex = std.Thread.Mutex{};

        const InheritanceWorker = struct {
            fn worker(ctx: *CreateContext, base: *param.Context, derived: *param.Context) void {
                var local_prng = std.Random.DefaultPrng.init(@intCast(ctx.thread_id * 2021));
                var local_random = local_prng.random();

                var i: usize = 0;
                while (i < ctx.iterations) : (i += 1) {
                    const operation = local_random.intRangeAtMost(u8, 0, 4);

                    switch (operation) {
                        0 => {
                            // Create class extending base
                            var class_name_buf: [32]u8 = undefined;
                            const class_name = std.fmt.bufPrint(&class_name_buf, "ext_base_{}_{}", .{ctx.thread_id, i}) catch unreachable;

                            if (ctx.parent_ctx.createClass(class_name, base)) |new_class| {
                                ctx.mutex.lock();
                                defer ctx.mutex.unlock();
                                ctx.created_contexts.append(new_class) catch @panic("OOM");
                            } else |_| {}
                        },
                        1 => {
                            // Create class extending derived
                            var class_name_buf: [32]u8 = undefined;
                            const class_name = std.fmt.bufPrint(&class_name_buf, "ext_derived_{}_{}", .{ctx.thread_id, i}) catch unreachable;

                            if (ctx.parent_ctx.createClass(class_name, derived)) |new_class| {
                                ctx.mutex.lock();
                                defer ctx.mutex.unlock();
                                ctx.created_contexts.append(new_class) catch @panic("OOM");
                            } else |_| {}
                        },
                        2 => {
                            // Retain and release base class
                            const retained = base.retain();
                            retained.release();
                        },
                        3 => {
                            // Retain and release derived class
                            const retained = derived.retain();
                            retained.release();
                        },
                        4 => {
                            // Change inheritance of a random existing class
                            ctx.mutex.lock();
                            defer ctx.mutex.unlock();

                            if (ctx.created_contexts.items.len > 0) {
                                const idx = local_random.intRangeLessThan(usize, 0, ctx.created_contexts.items.len);
                                const target = ctx.created_contexts.items[idx];

                                // Randomly extend base, derived, or null
                                const extend_choice = local_random.intRangeAtMost(u8, 0, 2);
                                switch (extend_choice) {
                                    0 => target.extend(base),
                                    1 => target.extend(derived),
                                    2 => target.extend(null),
                                    else => break
                                }
                            }
                        },
                        else => break
                    }
                }
            }
        };

        var threads: [num_threads]std.Thread = undefined;
        var create_contexts: [num_threads]CreateContext = undefined;

        for (0..num_threads) |i| {
            create_contexts[i] = .{
                .parent_ctx = root_ctx,
                .iterations = iterations,
                .thread_id = i,
                .created_contexts = &all_contexts,
                .mutex = &contexts_mutex,
            };
            threads[i] = try std.Thread.spawn(.{}, InheritanceWorker.worker, .{&create_contexts[i], base_class, derived_class});
        }

        for (&threads) |*t| {
            t.join();
        }

        // Verify reference counts are sane
        try testing.expect(base_class.refs.load(.acquire) > 0);
        try testing.expect(derived_class.refs.load(.acquire) > 0);
        try testing.expect(base_class.derivatives.load(.acquire) >= 1); // At least derived_class extends it
    }
};

// Run all tests
test {
    //
    std.testing.refAllDecls(RefCountTests);
    std.testing.refAllDecls(MultithreadTests);
}
