const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StringPool = struct {
    allocator: Allocator,
    strings: std.StringHashMap(void),
    rw_lock: std.Thread.RwLock = .{},

    pub fn init(allocator: Allocator) StringPool {
        return StringPool{
            .allocator = allocator,
            .strings = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *StringPool) void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        self.deinitUnlocked();
    }

    pub fn deinitUnlocked(self: *StringPool) void {
        var it = self.strings.keyIterator();
        while (it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.strings.deinit();
    }

    pub fn intern(self: *StringPool, string: []const u8) ![]const u8 {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        return self.internUnlocked(string);
    }

    pub fn internUnlocked(self: *StringPool, string: []const u8) ![]const u8 {
        const gop = try self.strings.getOrPut(string);
        if (gop.found_existing) {
            return gop.key_ptr.*;
        }

        const stored_string = try self.allocator.dupe(u8, string);
        gop.key_ptr.* = stored_string;

        return stored_string;
    }

    pub fn containsUnlocked(self: *StringPool, string: []const u8) bool {
        return self.strings.contains(string);
    }

    pub fn getUnlocked(self: *StringPool, string: []const u8) ?[]const u8 {
        return self.strings.getKey(string);
    }

    pub fn remove(self: *StringPool, string: []const u8) bool {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        return self.removeUnlocked(string);
    }

    pub fn removeUnlocked(self: *StringPool, string: []const u8) bool {
        if (self.strings.fetchRemove(string)) |removed_entry| {
            self.allocator.free(removed_entry.key);
            return true;
        }
        return false;
    }

    pub fn count(self: *StringPool) usize {
        self.rw_lock.lockShared();
        defer self.rw_lock.unlockShared();
        return self.countUnlocked();
    }

    pub fn countUnlocked(self: *StringPool) usize {
        return self.strings.count();
    }
};

pub const ArenaStringPool = struct {
    arena: std.heap.ArenaAllocator,
    strings: std.StringHashMap(void),
    rw_lock: std.Thread.RwLock = .{},

    pub fn init(allocator: Allocator) ArenaStringPool {
        return ArenaStringPool{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .strings = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ArenaStringPool) void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        self.deinitUnlocked();
    }

    pub fn deinitUnlocked(self: *ArenaStringPool) void {
        self.strings.deinit();
        self.arena.deinit();
    }

    pub fn intern(self: *ArenaStringPool, string: []const u8) ![]const u8 {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();

        return self.internUnlocked(string);
    }

    pub fn internUnlocked(self: *ArenaStringPool, string: []const u8) ![]const u8 {
        const gop = try self.strings.getOrPut(string);
        if (gop.found_existing) {
            return gop.key_ptr.*;
        }

        const stored_string = try self.arena.allocator().dupe(u8, string);
        gop.key_ptr.* = stored_string;

        return stored_string;
    }

    pub fn containsUnlocked(self: *ArenaStringPool, string: []const u8) bool {
        return self.strings.contains(string);
    }

    pub fn getUnlocked(self: *ArenaStringPool, string: []const u8) ?[]const u8 {
        return self.strings.getKey(string);
    }

    pub fn remove(self: *ArenaStringPool, string: []const u8) bool {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        return self.removeUnlocked(string);
    }

    pub fn removeUnlocked(self: *ArenaStringPool, string: []const u8) bool {
        return self.strings.remove(string);
    }

    pub fn count(self: *ArenaStringPool) usize {
        self.rw_lock.lockShared();
        defer self.rw_lock.unlockShared();
        return self.countUnlocked();
    }

    pub fn countUnlocked(self: *ArenaStringPool) usize {
        return self.strings.count();
    }

    pub fn totalAllocated(self: *ArenaStringPool) usize {
        return self.arena.queryCapacity();
    }

    pub fn reset(self: *ArenaStringPool) void {
        self.rw_lock.lock();
        defer self.rw_lock.unlock();
        self.resetUnlocked();
    }

    pub fn resetUnlocked(self: *ArenaStringPool) void {
        self.strings.clearRetainingCapacity();
        self.arena.reset(.retain_capacity);
    }
};

pub fn ObjectPool(comptime T: type) type {
    return struct {
        allocator: Allocator,
        free_list: std.ArrayListUnmanaged(*T),
        rw_lock: std.Thread.RwLock = .{},

        const Self = @This();

        pub fn init(allocator: Allocator) Self {
            return Self{
                .allocator = allocator,
                .free_list = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            self.deinitUnlocked();
        }

        pub fn deinitUnlocked(self: *Self) void {
            for (self.free_list.items) |ptr| {
                self.allocator.destroy(ptr);
            }
            self.free_list.deinit(self.allocator);
        }

        pub fn acquire(self: *Self) !*T {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            return self.acquireUnlocked();
        }

        pub fn acquireUnlocked(self: *Self) !*T {
            if (self.free_list.pop()) |ptr| {
                return ptr;
            } else {
                return try self.allocator.create(T);
            }
        }

        pub fn release(self: *Self, obj: *T) void {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            self.releaseUnlocked(obj);
        }

        pub fn releaseUnlocked(self: *Self, obj: *T) void {
            self.free_list.append(self.allocator, obj) catch {
                // If append fails, just destroy the object
                self.allocator.destroy(obj);
            };
        }

        pub fn count(self: *Self) usize {
            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();
            return self.countUnlocked();
        }

        pub fn countUnlocked(self: *Self) usize {
            return self.free_list.items.len;
        }
    };
}

pub fn SlabPool(comptime T: type, comptime capacity: usize) type {
    return struct {
        allocator: Allocator,
        storage: [capacity]T,
        free_list: std.BoundedArray(usize, capacity),
        used: usize = 0,
        rw_lock: std.Thread.RwLock = .{},

        pub fn init(allocator: Allocator) SlabPool {
            var pool = SlabPool{
                .allocator = allocator,
                .storage = undefined,
                .free_list = .{},
                .used = 0,
            };
            for (0..capacity) |i| {
                pool.free_list.appendAssumeCapacity(i);
            }
            return pool;
        }

        pub fn deinit(self: *SlabPool) void {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            self.deinitUnlocked();
        }

        pub fn deinitUnlocked(self: *SlabPool) void {
            self.used = 0;
            self.free_list.len = 0;
        }

        pub fn acquire(self: *SlabPool) ?*T {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            return self.acquireUnlocked();
        }

        pub fn acquireUnlocked(self: *SlabPool) ?*T {
            if (self.free_list.pop()) |idx| {
                self.used += 1;
                return &self.storage[idx];
            }
            return null;
        }

        pub fn release(self: *SlabPool, obj: *T) void {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            self.releaseUnlocked(obj);
        }

        pub fn releaseUnlocked(self: *SlabPool, obj: *T) void {
            const idx = @intFromPtr(obj) - @intFromPtr(&self.storage[0]);
            self.free_list.appendAssumeCapacity(idx);
            self.used -= 1;
        }

        pub fn count(self: *SlabPool) usize {
            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();
            return self.countUnlocked();
        }

        pub fn countUnlocked(self: *SlabPool) usize {
            return self.used;
        }
    };
}

pub fn BlockPool(comptime block_size: usize, comptime capacity: usize) type {
    return struct {
        allocator: Allocator,
        storage: []u8,
        free_list: std.BoundedArray(usize, capacity),
        used: usize = 0,
        rw_lock: std.Thread.RwLock = .{},

        pub fn init(allocator: Allocator) !BlockPool {
            var pool = BlockPool{
                .allocator = allocator,
                .storage = try allocator.alloc(u8, block_size * capacity),
                .free_list = .{},
                .used = 0,
            };
            for (0..capacity) |i| {
                pool.free_list.appendAssumeCapacity(i);
            }
            return pool;
        }

        pub fn deinit(self: *BlockPool) void {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            self.deinitUnlocked();
        }

        pub fn deinitUnlocked(self: *BlockPool) void {
            self.allocator.free(self.storage);
            self.used = 0;
            self.free_list.len = 0;
        }

        pub fn acquire(self: *BlockPool) ?[]u8 {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            return self.acquireUnlocked();
        }

        pub fn acquireUnlocked(self: *BlockPool) ?[]u8 {
            if (self.free_list.pop()) |idx| {
                self.used += 1;
                return self.storage[idx * block_size .. (idx + 1) * block_size];
            }
            return null;
        }

        pub fn release(self: *BlockPool, block: []u8) void {
            self.rw_lock.lock();
            defer self.rw_lock.unlock();
            self.releaseUnlocked(block);
        }

        pub fn releaseUnlocked(self: *BlockPool, block: []u8) void {
            const idx = (@intFromPtr(&block[0]) - @intFromPtr(&self.storage[0])) / block_size;
            self.free_list.appendAssumeCapacity(idx);
            self.used -= 1;
        }

        pub fn count(self: *BlockPool) usize {
            self.rw_lock.lockShared();
            defer self.rw_lock.unlockShared();
            return self.countUnlocked();
        }

        pub fn countUnlocked(self: *BlockPool) usize {
            return self.used;
        }
    };
}
