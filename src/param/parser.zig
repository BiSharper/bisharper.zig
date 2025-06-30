const std = @import("std");
const Allocator = std.mem.Allocator;
const param = @import("root.zig");

pub const AstNode = union(enum) {
    class: AstClass,
    param: AstParam,
    delete: []const u8,
    array: AstArray,

    pub const AstClass = struct { name: []const u8, extends: ?[]const u8, nodes: ?[]AstNode };

    pub const AstParam = struct {
        name: []const u8,
        value: param.Value,
    };

    pub const AstOperator = enum {
        Add,
        Sub,
        Assign,
    };

    pub const AstArray = struct {
        name: []const u8,
        operator: AstOperator,
        value: param.Array,
    };

    pub fn deinit(self: *AstNode, allocator: Allocator) void {
        switch (self.*) {
            .class => |*class_node| {
                if (class_node.nodes) |nodes| {
                    for (nodes) |*node| {
                        node.deinit(allocator);
                    }
                    allocator.free(nodes);
                }
            },
            .param => |*param_node| {
                param_node.value.deinit(allocator);
            },
            .delete => {},
            .array => |*array_node| {
                array_node.value.deinit(allocator);
            },
        }
    }

    pub fn parseContext(input: []const u8, index: *usize, line: *usize, line_start: *usize, allocator: Allocator) ![]AstNode {
        var nodes = std.ArrayList(AstNode).init(allocator);
        while (index.* < input.len) {
            skipWhitespace(input, index, line, line_start);

            var c = input[index.*];
            if (c == '#') {
                //todo
            }

            if (c == '}') {
                index.* += 1;
                if (input[index.*] != ';') {
                    std.log.err("Error at line {}, col {}: expected ';' after class ending.", .{ line.*, index.* - line_start.* });
                    return error.SyntaxError;
                }
                index.* += 1;

                break;
            }
            var word = getAlphaWord(input, index, line, line_start);
            if (std.mem.eql(u8, word, "delete")) {
                word = getAlphaWord(input, index, line, line_start);

                skipWhitespace(input, index, line, line_start);

                if (input[index.*] != ';') {
                    std.log.err("Error at line {}, col {}: expected ';' after 'delete' statement.", .{ line.*, index.* - line_start.* });
                    return error.SyntaxError;
                }
                index.* += 1;
                try nodes.append(.{ .delete = word });
            } else if (std.mem.eql(u8, word, "class")) {
                const class_name = getAlphaWord(input, index, line, line_start);

                skipWhitespace(input, index, line, line_start);

                if (input[index.*] == ';') {
                    index.* += 1;

                    try nodes.append(.{ .class = .{ .name = class_name, .extends = null, .nodes = null } });
                } else {
                    var extends_name: ?[]const u8 = null;
                    if (input[index.*] == ':') {
                        index.* += 1;
                        extends_name = getAlphaWord(input, index, line, line_start);
                    }
                    skipWhitespace(input, index, line, line_start);

                    if (input[index.*] != '{') {
                        if (extends_name != null) {
                            std.log.err("Error at line {}, col {}: expected '{{' after class declaration.", .{ line.*, index.* - line_start.* });
                        } else {
                            std.log.err("Error at line {}, col {}: expected ';' or '{{' after class declaration.", .{ line.*, index.* - line_start.* });
                        }
                        return error.SyntaxError;
                    }
                    index.* += 1;

                    try nodes.append(.{ .class = .{ .name = class_name, .extends = extends_name, .nodes = try parseContext(input, index, line, line_start, allocator) } });
                }
            } else {
                if (input[index.*] == '[') {
                    index.* += 1;

                    skipWhitespace(input, index, line, line_start);

                    if (input[index.*] != ']') {
                        std.log.err("Error at line {}, col {}: expected ']' or whitespace after '['", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }
                    index.* += 1;

                    skipWhitespace(input, index, line, line_start);

                    const operator: AstNode.AstOperator = blk: switch (input[index.*]) {
                        '+' => {
                            index.* += 1;

                            if (input[index.*] != '=') {
                                std.log.err("Error at line {}, col {}: expected '=' after '+'", .{ line.*, index.* - line_start.* });
                                return error.SyntaxError;
                            }
                            index.* += 1;
                            break :blk AstNode.AstOperator.Add;
                        },
                        '-' => {
                            index.* += 1;

                            if (input[index.*] != '=') {
                                std.log.err("Error at line {}, col {}: expected '=' after '+'", .{ line.*, index.* - line_start.* });
                                return error.SyntaxError;
                            }
                            index.* += 1;
                            break :blk AstNode.AstOperator.Sub;
                        },
                        '=' => {
                            index.* += 1;
                            break :blk AstNode.AstOperator.Assign;
                        },
                        else => {
                            std.log.err("Error at line {}, col {}: expected '=', '+=', or '-=' after array name", .{ line.*, index.* - line_start.* });
                            return error.SyntaxError;
                        },
                    };
                    const array = try parseArray(input, index, line, line_start, allocator);

                    try nodes.append(.{ .array = .{ .name = word, .operator = operator, .value = array } });
                    skipWhitespace(input, index, line, line_start);

                    if (input[index.*] != ';') {
                        std.log.err("Error at line {}, col {}: expected ';' after array parameter", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }

                    index.* += 1;
                } else {
                    skipWhitespace(input, index, line, line_start);
                    if (input[index.*] != '=') {
                        std.log.err("Error at line {}, col {}: expected '=' or '[' after parameter name", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }
                    index.* += 1;

                    skipWhitespace(input, index, line, line_start);

                    var expression = false;
                    if (input[index.*] == '@') {
                        expression = true;
                    }

                    var foundQuote: bool = false;
                    const wordValue = try getWord(input, index, line, line_start, &[_]u8{ ';', '}', '\n', '\r' }, &foundQuote, allocator);
                    defer allocator.free(wordValue);

                    c = input[index.*];
                    switch (c) {
                        '}' => {
                            index.* -= 1;
                            std.log.warn("Warning at line {}, col {}: Missing ';' prior to '}}'", .{ line.*, index.* - line_start.* });
                        },
                        ';' => {
                            index.* += 1;
                        },
                        else => {
                            if (c != '\n' and c != '\r') {
                                if (!foundQuote) {
                                    std.log.err("Error at line {}, col {}: Expected ';' after parameter value", .{ line.*, index.* - line_start.* });
                                    return error.SyntaxError;
                                } else {
                                    index.* -= 1;
                                }
                            }
                            std.log.warn("Warning at line {}, col {}: Missing ';' at end of line.", .{ line.*, index.* - line_start.* });
                        },
                    }

                    if (expression) {
                        std.log.err("Error at line {}, col {}: Expressions are not yet implemented", .{ line.*, index.* - line_start.* });
                        return error.NotImplemented;
                    } else if (!foundQuote) {
                        if (wordValue.len > 7 and std.mem.eql(u8, wordValue[0..6], "__EVAL")) {
                            std.log.err("Error at line {}, col {}: Evaluate not yet implemented", .{ line.*, index.* - line_start.* });
                            return error.NotImplemented;
                        }
                        var value = try scanInt(wordValue, allocator) orelse
                            try scanInt64(wordValue, allocator) orelse
                            try scanFloat(wordValue, allocator) orelse
                            try param.createValue(wordValue, allocator);
                        errdefer param.Value.deinit(&value, allocator);

                        try nodes.append(.{ .param = .{ .name = word, .value = value } });
                    } else {
                        var value = try param.createValue(wordValue, allocator);
                        errdefer param.Value.deinit(&value, allocator);

                        try nodes.append(.{ .param = .{ .name = word, .value = value } });
                    }
                }
            }
        }

        return try nodes.toOwnedSlice();
    }

    pub fn parseArray(input: []const u8, index: *usize, line: *usize, line_start: *usize, allocator: Allocator) !param.Array {
        skipWhitespace(input, index, line, line_start);
        var array = param.Array.init(allocator);
        if (input[index.*] != '{') {
            return error.SyntaxError;
        }
        index.* += 1;

        while (true) {
            skipWhitespace(input, index, line, line_start);

            if (index.* >= input.len) {
                return error.SyntaxError;
            }
            var current_char = input[index.*];

            switch (current_char) {
                '{' => {
                    const nested_array = try parseArray(input, index, line, line_start, allocator);
                    try array.push(param.Value{ .array = nested_array });
                },
                '#' => {
                    std.log.err("Error at line {}, col {}: Directives not implemented", .{ line.*, index.* - line_start.* });
                    return error.NotImplemented;
                },
                '@' => {
                    var foundQuote = false;
                    const word = try getWord(input, index, line, line_start, &[_]u8{ ',', ';', '}' }, &foundQuote, allocator);
                    allocator.free(word);
                    std.log.err("Error at line {}, col {}: Expressions not implemented", .{ line.*, index.* - line_start.* });
                    return error.NotImplemented;
                },
                '}' => {
                    index.* += 1;
                    return array;
                },
                ',' => {
                    index.* += 1;
                },
                ';' => {
                    std.log.warn("Warning at line {}, col {}: Using ';' as array separator is deprecated, use ',' instead.", .{ line.*, index.* - line_start.* });
                    index.* += 1;
                },
                else => {
                    var foundQuote = false;
                    const found = try getWord(input, index, line, line_start, &[_]u8{ ',', ';', '}' }, &foundQuote, allocator);
                    defer allocator.free(found);

                    current_char = input[index.*];

                    if (current_char == ',' or current_char == ';') {
                        if (current_char == ';') {
                            std.log.warn("Warning at line {}, col {}: Using ';' as array separator is deprecated, use ',' instead.", .{ line.*, index.* - line_start.* });
                        }

                        if (!foundQuote) {
                            if (found[0] == '@') {
                                std.log.err("Error at line {}, col {}: Expressions not implemented", .{ line.*, index.* - line_start.* });
                                return error.NotImplemented;
                            }

                            if (std.mem.eql(u8, found[0..6], "__EVAL")) {
                                std.log.err("Error at line {}, col {}: Evaluate not yet implemented", .{ line.*, index.* - line_start.* });
                                return error.NotImplemented;
                            }
                            var value = try scanInt(found, allocator) orelse
                                try scanFloat(found, allocator) orelse
                                try param.createValue(found, allocator);
                            errdefer param.Value.deinit(&value, allocator);
                            try array.push(value);
                        } else {
                            var value = try param.createValue(found, allocator);
                            errdefer param.Value.deinit(&value, allocator);
                            try array.push(value);
                        }
                    }
                },
            }
        }

        return error.Unimplemented;
    }
};

fn scanHex(val: []const u8) ?i32 {
    if (val.len < 3) return null;

    if (!std.ascii.eqlIgnoreCase(val[0..2], "0x")) return null;

    const hex_part = val[2..];
    if (hex_part.len == 0) return null;

    for (hex_part) |c| {
        if (!std.ascii.isHex(c)) return null;
    }

    return std.fmt.parseInt(i32, hex_part, 16) catch null;
}

fn scanInt(input: []const u8, allocator: Allocator) !?param.Value {
    if (input.len == 0) return null;

    if (scanIntPlain(input)) |val| {
        return try param.createValue(val, allocator);
    }

    if (scanHex(input)) |val| {
        return try param.createValue(val, allocator);
    }

    return null;
}

fn scanIntPlain(ptr: []const u8) ?i32 {
    if (ptr.len == 0) return null;

    return std.fmt.parseInt(i32, ptr, 10) catch null;
}

fn scanInt64Plain(ptr: []const u8) ?i64 {
    if (ptr.len == 0) return null;

    return std.fmt.parseInt(i64, ptr, 10) catch null;
}

fn scanInt64(input: []const u8, allocator: Allocator) !?param.Value {
    if (input.len == 0) return null;

    if (scanInt64Plain(input)) |val| {
        return try param.createValue(val, allocator);
    }

    if (scanHex(input)) |val| {
        return try param.createValue(val, allocator);
    }

    return null;
}

fn scanFloatPlain(ptr: []const u8) ?f32 {
    if (ptr.len == 0) return null;

    return std.fmt.parseFloat(f32, ptr) catch null;
}

fn scanDb(ptr: []const u8) ?f32 {
    if (ptr.len < 3 or ptr[0] != 'd' or ptr[1] != 'b') return null;

    const db_part = ptr[2..];

    const db_value = std.fmt.parseFloat(f32, db_part) catch {
        std.debug.print("invalid db value {s}\n", .{ptr});
        return null;
    };

    return std.math.pow(f32, 10.0, db_value * (1.0 / 20.0));
}

fn scanFloat(ptr: []const u8, allocator: Allocator) !?param.Value {
    if (ptr.len == 0) return null;

    if (scanFloatPlain(ptr)) |val| {
        return try param.createValue(val, allocator);
    }

    if (scanDb(ptr)) |val| {
        return try param.createValue(val, allocator);
    }

    return null;
}

fn getWord(input: []const u8, index: *usize, line: *usize, line_start: *usize, terminators: []const u8, found_quote: *bool, allocator: Allocator) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    skipWhitespace(input, index, line, line_start);

    if (input[index.*] == '"') {
        index.* += 1;
        found_quote.* = true;
        while (index.* < input.len) {
            const c = input[index.*];
            if (c == '"') {
                index.* += 1;
                if (index.* < input.len and input[index.*] != '"') {
                    skipWhitespace(input, index, line, line_start);

                    if (index.* < input.len and input[index.*] != '\\') {
                        return try result.toOwnedSlice();
                    }
                    index.* += 1;
                    if (index.* < input.len and input[index.*] != 'n') {
                        std.log.err("Error at line {}, col {}: invalid escape sequence", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }
                    skipWhitespace(input, index, line, line_start);

                    if (index.* < input.len and input[index.*] != '"') {
                        std.log.err("Error at line {}, col {}: expected '\"' after escape sequence", .{ line.*, index.* - line_start.* });
                        return error.SyntaxError;
                    }

                    index.* += 1;
                    try result.append('\n');
                } else {
                    index.* += 1;
                    try result.append('"');
                }
            } else {
                if (c == '\n' or c == '\r') {
                    std.log.err("Error at line {}, col {}: End of line encountered", .{ line.*, index.* - line_start.* });
                    return error.SyntaxError;
                }
                try result.append(c);
                index.* += 1;
                continue;
            }
        }
        std.log.err("Error at line {}, col {}: unterminated string literal", .{ line.*, index.* - line_start.* });
        return error.SyntaxError;
    } else {
        found_quote.* = false;
        var c = input[index.*];
        while (index.* < input.len and std.mem.indexOfScalar(u8, terminators, c) == null) {
            if (c == '\n' or c == '\r') {
                while (true) {
                    skipWhitespace(input, index, line, line_start);
                    if (input[index.*] != '#') {
                        break;
                    }
                    std.log.err("Error at line {}, col {}: Directives not implemented", .{ line.*, index.* - line_start.* });
                    return error.NotImplemented;
                }
                c = input[index.*];
                if (std.mem.indexOfScalar(u8, terminators, c) == null) {
                    std.log.err("Error at line {}, col {}: Expected unquoted terminator got '{}'", .{ line.*, index.* - line_start.*, c });
                }
            } else {
                index.* += 1;
                if (index.* >= input.len) break;
                try result.append(c);
                c = input[index.*];
            }
        }

        return try result.toOwnedSlice();
    }
}

fn skipWhitespace(input: []const u8, index: *usize, line: *usize, line_start: *usize) void {
    while (index.* < input.len) {
        const c = input[index.*];
        if (c == '\n') {
            line.* += 1;
            index.* += 1;
            line_start.* = index.*;
        } else if (std.ascii.isWhitespace(c)) {
            index.* += 1;
        } else {
            break;
        }
    }
}

fn getAlphaWord(input: []const u8, index: *usize, line: *usize, line_start: *usize) []const u8 {
    skipWhitespace(input, index, line, line_start);

    const word_start = index.*;

    while (index.* < input.len) {
        const c = input[index.*];
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) {
            break;
        }
        index.* += 1;
    }

    return input[word_start..index.*];
}
