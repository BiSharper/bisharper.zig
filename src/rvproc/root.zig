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
        var token = lexer.nextToken();
        while (true){
            if (token == Token.EOF) break;

            if (token == Token.Quote) {
                quoted = !quoted;
                token = lexer.nextToken();
                continue;
            }
            switch (token.*) {
                Token.NewFile or Token.NewLine => {
                    lexer.skipWhitespace();
                    token = lexer.nextToken();
                    if(token == Token.Hash) {
                        token = lexer.nextToken();
                        lexer.skipWhitespace();
                        switch(token.*) {
                            Token.Include => {
                                token = lexer.nextToken();
                                if(token != Token.Quote and token != Token.LeftAngle) {
                                    return error.IncludeError;
                                }

                                lexer.scanString(if (token == Token.Quote) &.{'"'} else &.{'>'});
                                lexer.position += 1; //skip string terminator

                                const contents = try include(lexer.slice) orelse return error.FileNotFound;
                                const sub_result = try context.preprocess(path, contents, include);
                                try out.appendSlice(sub_result);
                                token = lexer.nextToken();
                            },
                            Token.Define => {},
                            Token.IfDef => {},
                            Token.IfNDef => {},
                            Token.EndIf => {},
                            Token.Else => {},
                            Token.Undef => {},
                            else => {
                                // Unrecognized directive
                                return error.UnrecognizedDirective;
                            }
                        }
                    }
                },
                Token.BeginBlockComment => {
                    lexer.skipBlockComment();
                    token = lexer.nextToken();
                },
                Token.BeginLineComment => {
                    lexer.skipLineComment();
                    token = lexer.nextToken();
                },
                Token.Text => {

                },
                else => try out.appendSlice(lexer.slice)
            }
        }

        out.toOwnedSlice();
    }

};
