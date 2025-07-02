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
    defines: std.StringHashMap(*Define),

    pub fn init(allocator: Allocator) Context {
        return Context{
            .allocator = allocator,
            .defines = std.StringHashMap(*Define).init(allocator),
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
                                lexer.position += 1;

                                const contents = try include(lexer.slice) orelse return error.FileNotFound;
                                const sub_result = try context.preprocess(path, contents, include);
                                try out.appendSlice(sub_result);
                                token = lexer.nextToken();
                            },
                            Token.Define => {
                                token = lexer.nextToken();
                                const define = try context.allocator.create(Define);
                                errdefer context.allocator.destroy(define);

                                const owned_name = try context.allocator.dupe(u8, lexer.slice);
                                errdefer context.allocator.free(owned_name);

                                token = lexer.nextToken();
                                const args = bkf: {
                                    if(token == .LeftParen) {
                                        lexer.skipWhitespace();
                                        token = lexer.nextToken();
                                        const args = std.ArrayList([]const u8).init(context.allocator);
                                        defer args.deinit();

                                        var count = 0;
                                        while (token == .Text) {
                                            const owned_arg = try context.allocator.dupe(u8, lexer.slice);
                                            errdefer context.allocator.free(owned_arg);

                                            try args.append(owned_arg);
                                            count += 1;
                                            lexer.skipWhitespace();

                                            token = lexer.nextToken();

                                            if(token == .Comma) {
                                                lexer.skipWhitespace();
                                                token = lexer.nextToken();
                                            }
                                        }

                                        if(token != .RightParen) {
                                            return error.DefineError;
                                        }

                                        lexer.skipWhitespace();
                                        token = lexer.nextToken();
                                        break :bkf try args.toOwnedSlice();
                                    } else break :bkf &.{};
                                };

                                if(lexer.slice[0] == 32) {
                                    lexer.skipWhitespace();
                                    token = lexer.nextToken();
                                }

                                const value = blk: {
                                    const val = std.ArrayList(u8).init(context.allocator);
                                    defer val.deinit();

                                    while (token != .NewLine and token != .EOF) {
                                        switch (token.*) {
                                            Token.BeginLineComment => lexer.skipLineComment(),
                                            Token.BeginBlockComment => lexer.skipBlockComment(),
                                            !Token.LineBreak => val.appendSlice(lexer.slice)
                                        }
                                        token = lexer.nextToken();
                                    }

                                    break :blk try val.toOwnedSlice();
                                };

                                define.* = .{
                                    .name = owned_name,
                                    .args = args,
                                    .value = value
                                };

                                context.defines.put(owned_name, define);


                            },
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
