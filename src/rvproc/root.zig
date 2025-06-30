const std = @import("std");
const Allocator = std.mem.Allocator;


pub const Define = struct{
    name: []const u8,
    value: []const u8,
};

pub const PreprocessResult = struct{
    context:  *Context,
    contents: []const u8,

};

pub const OpenIncludeFn = fn (include: []const u8) ?[]const u8;

pub const Context = struct {
    allocator: Allocator,
    defines: std.ArrayList(Define),

    pub fn init(allocator: Allocator) Context {
        return Context{
            .allocator = allocator,
            .defines = std.ArrayList(Define).init(allocator),
        };
    }


    pub fn preprocess(context: *Context, path: []const u8, include: OpenIncludeFn) ![]const u8 {
        const content = try include(path) orelse return error.FileNotFound;

        var out = std.ArrayList(u8).init(context.allocator);
        defer out.deinit();

        var i: usize = 0;
        var quoted = false;
        while (i < content.len) : (i += 1) {
            const current_char = content[i];
            if(current_char == '"') {
                quoted = !quoted;
            }

            if(quoted) {
                try out.append(current_char);
                continue;
            }


            switch (current_char) {
                '/' => {
                    current_char = content[i + 1];
                    switch (current_char) {
                        '/' => {
                            while (i < content.len and content[i] != '\n') : (i += 1) {}
                        },
                        '*' => {
                            while (i + 1 < content.len) : (i += 1) {
                                if (content[i] == '*' and content[i + 1] == '/') {
                                    i += 1;
                                    break;
                                }
                            }
                        },
                        else => {
                            try out.append('/');
                        }
                    }
                }
            }

        }

        out.toOwnedSlice();
    }

};
