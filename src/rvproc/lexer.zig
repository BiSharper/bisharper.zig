const std = @import("std");
const Allocator = std.mem.Allocator;



pub const Token = enum {
    Include,
    Define,
    IfDef,
    IfNDef,
    Else,
    EndIf,
    LeftParen,
    RightParen,
    Comma,
    Hash,
    NewFile,
    NewLine,
    LineBreak,
    BeginLineComment,
    BeginBlockComment,
    Quote,
    Text,
    Unknown,
    LeftAngle,
    RightAngle,
    DoubleHash,
    Undef,
    EOF
};

const Lexer = struct {
    allocator: Allocator,
    content: []const u8,
    position: usize,
    slice: []const u8,

    pub fn init(allocator: Allocator, content: []const u8) Lexer {
        return Lexer{
            .allocator = allocator,
            .content = content,
            .position = 0,
        };
    }

    pub fn skipBlockComment(self: *Lexer) void {
        while (self.position < self.content and (self.content[self.position - 1] != '*' and self.content[self.position] != '/')) : (self.position += 1) {}
    }

    pub fn skipLineComment(self: *Lexer) void {
        while (self.position < self.content.len and self.content[self.position] != '\n') : (self.position += 1) {}

    }

    pub fn nextToken(self: *Lexer) Token {
        while (self.content[self.position] == '\r') : (self.position += 1) {}
        if (self.position >= self.content.len) return Token.EOF;
        if(validIdChar(self.content[self.position], true)) {
            const start = self.position;
            while (self.position < self.content.len and validIdChar(self.content[self.position], false)) : (self.position += 1) {}
            self.slice = self.content[start..self.position];
            return self.findLexemeWord() orelse Token.Text;
        }

        const start = self.position;
        if ((self.content[self.position] == '/') or (self.content[self.position] == '\\')) {
            self.position += 1;
            while (self.content[self.position] == '\r') : (self.position += 1) {}
            if (self.position < self.content.len and !validIdChar(self.content[self.position], true)) {
                self.position += 1;
                self.slice = self.content[start..self.position];
                if(self.findLexemeChar()) |token| {
                    return token;
                } else {
                    self.position -= 1;
                    self.slice = self.content[start..self.position];
                }
            } else {
                self.position -= 1;
            }
        } else if (self.content[self.position] == '#') {
            if(self.position < self.content.len and self.content[self.position + 1] == '#') {
                self.position += 1;
                self.slice = self.content[start..self.position];
                return Token.DoubleHash;
            }
            return Token.Hash;
        } else {
            if (self.position >= self.content.len) return Token.EOF;
            self.slice = self.content[start..self.position + 1];
            return self.findLexemeChar() orelse Token.Unknown;
        }
    }

    fn findLexemeWord(self: *Lexer) ?Token {
        if(std.mem.eql(u8, self.slice, "include")) {
             return Token.Include;
        } else if(std.mem.eql(u8, self.slice, "define")) {
             return Token.Define;
        } else if(std.mem.eql(u8, self.slice, "ifdef")) {
            return Token.IfDef;
        } else if(std.mem.eql(u8, self.slice, "ifndef")) {
            return Token.IfNDef;
        } else if(std.mem.eql(u8, self.slice, "else")) {
            return Token.Else;
        } else if(std.mem.eql(u8, self.slice, "endif")) {
            return Token.EndIf;
        } else if(std.mem.eql(u8, self.slice, "undef")) {
            return Token.Undef;
        } else return null;
    }

    fn findLexemeChar(self: *Lexer) ?Token {
        if(std.mem.eql(u8, self.slice, "(")) {
            return Token.LeftParen;
        } else if(std.mem.eql(u8, self.slice, ")")) {
            return Token.RightParen;
        } else if(std.mem.eql(u8, self.slice, ",")) {
            return Token.Comma;
        } else if(std.mem.eql(u8, self.slice, "#")) {
            return Token.Hash;
        } else if(std.mem.eql(u8, self.slice, "\n")) {
            return Token.NewLine;
        } else if(std.mem.eql(u8, self.slice, "//")) {
            return Token.BeginLineComment;
        } else if(std.mem.eql(u8, self.slice, "/*")) {
            return Token.BeginBlockComment;
        } else if(std.mem.eql(u8, self.slice, "\\\n")) {
            return Token.LineBreak;
        } else if(std.mem.eql(u8, self.slice, "\"")) {
            return Token.Quote;
        } else if(std.mem.eql(u8, self.slice, "<")) {
            return Token.LeftAngle;
        } else if(std.mem.eql(u8, self.slice, ">")) {
            return Token.RightAngle;
        } else if(std.mem.eql(u8, self.slice, "##")) {
            return Token.DoubleHash;
        } else return null;
    }

    pub fn validIdChar(c: u8, first: bool) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c == '_') or (!first and (c >= '0' and c <= '9'));
    }
};