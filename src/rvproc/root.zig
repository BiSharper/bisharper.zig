const std = @import("std");
const Allocator = std.mem.Allocator;
const lex = @import("lexer.zig");
const Token = lex.Token;
const Lexer = lex.Lexer;

pub const Define = struct{
    name: []const u8,
    args: []const []const u8,
    value: []const u8,

    pub fn evaluate(self: *const Define, context: *Context, args: []const []const u8) ![]const u8 {
        _ = self;
        _ = context;
        _ = args;

        return error.Unimplemented;
    }
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

        const lexer = Lexer.init(context.allocator, content);
        var quoted = false;
        while (lexer.nextToken()) | token |{
            if (token == Token.EOF) break;

            if (token == Token.Quote) {
                quoted = !quoted;
                continue;
            }
            switch (token.*) {
                Token.NewFile or Token.NewLine => {

                },
                Token.BeginBlockComment => lexer.skipBlockComment(),
                Token.BeginLineComment => lexer.skipLineComment(),
                Token.Text => {

                },
                else => try out.appendSlice(lexer.slice)
            }
        }

        out.toOwnedSlice();
    }

};
