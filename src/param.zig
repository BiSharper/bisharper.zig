const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ParamDatabase = struct {
    allocator:  Allocator,
    sources:    std.ArrayList(MonolithicParam.Source),
    context:    Context,

    pub const Access = enum(i3) {
        Default = -1, //basically read write
        ReadWrite = 0,
        ReadCreate = 1, //Only can add class members
        ReadOnly = 2,
        ReadOnlyVerified = 3
    };

    pub const Source = union {
        diag: *MonolithicParam,
        file: []const u8,
        programatic: void
    };

    pub const Value = struct {
        value: ValueType,
        owner: *Source,

        pub const ValueType = union {
            array:      std.ArrayList(Value),
            nest_array: std.ArrayList(ValueType),
            string:     []u8,
            i64:        i64,
            i32:        i32,
            f32:        f32,

            pub fn deinit(self: *ValueType, allocator: Allocator) void {
                switch (self.value) {
                    .array => |*arr| {
                        for (arr.items) |*item| item.deinit(allocator);
                        arr.deinit();
                    },
                    .nest_array => | *arr | {
                        for (arr.items) |*item| item.deinit(allocator);
                        arr.deinit();
                    },
                    .string => |str| allocator.free(str),
                    .i64, .i32, .f32 => {},
                }
            }
        };

        pub fn deinit(self: *Value, allocator: Allocator) void {
            self.value.deinit(allocator);
        }
    };

    pub const Context = struct {
        name:        []u8,
        database:    *ParamDatabase,
        access:      Access = Access.Default,
        parameters:  std.StringHashMap(Value),
        classes:     std.StringHashMap(Context),
        base:        ?*Context,
        parent:      ?*Context,
        references:  std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        owner:       *Source,

        fn addRef(self: *Context) void {
            _ = self.references.fetchAdd(1, .monotonic);
        }

        fn outerReferences(self: *Context) u32 {
            self.references.load(.monotonic) - self.classes.count();
        }

        fn release(self: *Context) void {
            _ = self.references.fetchSub(1, .monotonic);
        }

        fn toValueType(alloc: Allocator, astValue: MonolithicParam.Value, inArray: bool) !Value {
            return switch (astValue) {
                .string => |s| Value.ValueType{ .string = try alloc.dupe(u8, s) },
                .i64 => |v| Value.ValueType{ .i64 = v },
                .i32 => |v| Value.ValueType{ .i32 = v },
                .f32 => |v| Value.ValueType{ .f32 = v },
                .array =>| values | {
                    if(inArray) {
                        const innerArray = std.ArrayList(Value.ValueType).init(alloc);
                        errdefer innerArray.deinit();

                        for(values) | v | try innerArray.append(
                            toValueType(alloc, v, true)
                        );

                        return Value.ValueType {
                            .nest_array = innerArray
                        };
                    }
                    const array = std.ArrayList(Value).init(alloc);
                    for(values) | v | try array.append(toValueType(alloc, v, true));
                    return Value.ValueType {
                        .array = array
                    };
                },
            };
        }

        fn convertValue(alloc: Allocator, source: *Source, ast: MonolithicParam.Value, inArray: bool) !Value {
            return Value{
                .value = toValueType(alloc, ast, inArray),
                .owner = source
            };
        }

        fn addParamAst(self: *Context, ast: *MonolithicParam.Parameter, source: *Source) !void {
            if (self.access >= Access.ReadOnly) {
                std.debug.print(
                    "Cannot add {} in current context. The accesss is restricted",
                    .{ast.name}
                );
                return error.InvalidAccess;
            }
            const alloc = self.database.allocator;

            switch (ast.op) {
                .Assign => {
                    // if this is access we should hyjack it and set access
                    if(std.mem.eql(u8 , ast.name, "access")) {
                        if(ast.val == .i32) {
                            self.access = @enumFromInt(ast.val.i32); //int to enum value
                        } else {
                            std.debug.print(
                                "Invalid Access {}",
                                .{ast.val.i32}
                            );
                            return error.WrongAccessInt;
                        }

                        return;
                    }

                    if (self.parameters.get(ast.name.*)) | existing | {
                        if(self.access >= Access.ReadCreate) {
                            std.debug.print(
                                "Cannot update {} in current context. The accesss is restricted",
                                .{ast.name}
                            );
                            return error.InvalidAccess;
                        }

                        self.parameters.removeByPtr(ast.name.*);
                        existing.deinit(alloc);
                    }

                    const nameCopy = try alloc.dupe(u8, ast.name.*);
                    const value: Value = convertValue(ast.val, false);
                    self.parameters.put(nameCopy, value);
                },
                .AddAssign => {
                    if (ast.val != .array) {
                        return error.InvalidAddAssign;
                    }
                    const array = try self.getOrCreateArrayAst(
                        ast.name,
                        source,
                        ast.val.array.len
                    );
                    for(ast.val.array) |val| try array.value.array.append(convertValue(val, true));
                },
                .SubAssign => {
                    if (ast.val != .array) {
                        return error.InvalidSubAssign;
                    }
                    const array = try self.getOrCreateArrayAst(ast.name, source, 0);
                    if(array.value.array.items.len == 0) return;

                    return error.SubAssignNotImplemented;//TODO: Lets sub here; we need to test how the tools do this
                }
            }
        }

        fn getOrCreateArrayAst(self: *Context, name: []const u8, source: *Source, capacity: usize) !*Value {
            if (self.parameters.getPtr(name)) | array | if(array != .array) {
                error.ValueNotArray;
            } else array;

            const newArray = Value {
                .owner = source,
                .value = Value.ValueType {
                    .array = std.ArrayList(Value).initCapacity(Allocator, capacity)
                }
            };
            const nameCopy = try self.database.allocator.dupe(u8, name);
            try self.parameters.put(nameCopy, newArray);
            return self.parameters.getPtr(nameCopy);
        }

        fn addExternalAst(self: *Context, name: []const u8, source: *Source) !void {
            if(self.access >= Access.ReadOnly) {
                std.debug.print(
                    "Cannot add {} in current context. The accesss is restricted",
                    .{name}
                );
                return error.InvalidAccess;
            }
            const alloc = self.database.allocator;

            if (!self.classes.contains(name.*)) {
                const nameCopy = try alloc.dupe(u8, name.*);
                self.addRef();
                try self.classes.put(nameCopy, Context{
                    .database = &self.database,
                    .access = Access.Default,
                    .parameters = std.StringHashMap(Value).init(alloc),
                    .classes = std.StringHashMap(Context).init(alloc),
                    .base = null,
                    .name = nameCopy,
                    .owner = source
                });
            }
        }

        fn addClassAst(self: *Context, ast: *MonolithicParam.Class, source: *Source) !void {
            if(self.access >= Access.ReadOnly) {
                std.debug.print(
                    "Cannot add {} in current context. The accesss is restricted",
                    .{ast.name}
                );
                return error.InvalidAccess;
            }
            const alloc = self.database.allocator;
            const context: Context = blk: {
                if (self.classes.get(ast.name.*)) |existing| {
                    break :blk existing;
                } else {

                    const base: ?*Context = if (ast.base.*) |baseName| self.getClass(baseName) else null;
                    if(ast.base and !base) {
                        std.debug.print(
                            "Undefined base class {}",
                            .{ast.base.?}
                        );
                        return error.UndefinedBase;
                    }
                    if(base) | valid_base | valid_base.addRef();
                    const nameCopy = try alloc.dupe(u8, ast.name.*);

                    const newContext = Context{
                        .database = &self.database,
                        .access = Access.Default,
                        .parameters = std.StringHashMap(Value).init(alloc),
                        .classes = std.StringHashMap(Context).init(alloc),
                        .base = base,
                        .name = nameCopy,
                        .owner = source
                    };
                    self.addRef();
                    try self.classes.put(nameCopy, newContext);

                    break :blk newContext;
                }
            };
            try context.addStatementsAst(ast.statements, source);
            if (context.access == .Default) {
                if(context.base != null and context.base.?.access > .Default) {
                    context.access = context.base.?.access;
                } else if( context.parent) | parent | {
                    var ctx: ?*Context = parent;
                    while (ctx) {
                        if(ctx.access > .Default) {
                            context.access = ctx.access;
                            break;
                        }
                        if(ctx.base and ctx.base.?.access > .Default) {
                            context.access = ctx.base.?.access;
                            break;
                        }
                        ctx = parent.parent;
                    }
                }
            }
        }

        fn deleteClassAst(self: *Context, className: []const u8) !void {
            if(self.access >= Access.ReadOnly) {
                std.debug.print(
                    "Cannot delete {} in current context. The accesss is restricted",
                    .{className}
                );
                return error.InvalidAccess;
            }

            if(self.getClass(className)) | class | {
                const remainingLinks = class.outerReferences();
                if (remainingLinks > 0) {
                    std.debug.print(
                        "Cannot delete {} in current context. The target is still being referenced in {} places.",
                        .{className, remainingLinks}
                    );
                    return error.InvalidDelete;
                }
                self.release();
                self.classes.removeByPtr(class.name);
                class.deinit();
            }
        }

        fn addStatementsAst(self: *Context, statements: []const MonolithicParam.Statement, source: *Source) !void {
            for (statements) | statement | {
                switch (statement) {
                    .external   => | external | try self.addExternalAst(external, source),
                    .class      => | class | try self.addClassAst(class, source),
                    .param      => | param | try self.addParamAst(param, source),
                    .delete     => | class | try self.deleteClassAst(class),
                    .exec       => return error.NotImplemented,
                    .enumerable => return error.NotImplemented
                }
            }
        }

        pub const Entry = union {
            class: *Context,
            param: *Value
        };

        pub fn getClass(self: *Context, name: []const u8) ?*Context {
            if (self.classes.get(name)) |*context| {
                return context;
            }

            return null;
        }

        pub fn findEntry(self: *Context, name: []const u8, parent: bool, base: bool) !?Entry {
            if (self.getClass(name)) | clazz | return Entry {
                .class = clazz
            } else if (self.getParam(name)) | param | return Entry {
                .param = param
            } else if (base and self.base) {
                return self.base.?.findEntry(name, false, true);
            } else if(parent and self.parent) {
                return self.parent.?.findEntry(name, parent, base);
            } else return null;
        }

        pub fn derivedFrom(self: *Context, parent: *Context) bool {
            const base: ?*Context = self;
            while (base) | found| {
                if(found == parent) return true;
                base = found.base;
            }
            return false;
        }

        pub fn getParam(self: *Context, name: []const u8) ?*Value {
            if (self.parameters.getPtr(name)) |parameter| {
                return parameter;
            }

            return null;
        }

        pub fn getParamOwner(self: *Context, name: []const u8) ?*Source {
            if (try self.getParam(name)) | param | {
                return param.owner;
            }

            return null;
        }

        pub fn getString(self: *Context, name: []const u8) ?[]u8 {
            if (self.getParam(name)) | param | {
                if(param.value != .string) return null;
                return param.value.string;
            }
            return null;
        }

        pub fn getInt32(self: *Context, name: []const u8) ?*i32 {
            if (self.getParam(name)) | param | {
                if(param.value != .i32) return null;
                return param.value.i32;
            }

            return null;
        }

        pub fn getInt64(self: *Context, name: []const u8) ?*i64 {
            if (self.getParam(name)) | param | {
                if(param.value != .i64) return null;
                return param.value.i64;
            }

            return null;
        }

        pub fn getFloat(self: *Context, name: []const u8) ?*f32 {
            if (self.getParam(name)) | param | {
                if(param.value != .f32) return null;
                return param.value.f32;
            }

            return null;
        }

        pub fn addSource(self: *Context, ast: *MonolithicParam, diag: bool) !void {
            const source = if (diag) {
                ast.addRef();
                MonolithicParam.Source {
                    .diag = &ast,
                };
            } else {
                MonolithicParam.Source {
                    .file = try self.database.allocator.dupe(u8, ast.file)
                };
            };

            try self.database.sources.append(source);
            try self.addStatementsAst(ast.statements, &source);
        }

        pub fn deinit(self: *Context) void {
            const alloc = self.database.allocator;

            alloc.free(self.name);

            var parameter_iterator = self.parameters.iterator();
            while (parameter_iterator.next()) |entry| {
                entry.value_ptr.deinit(alloc);
                alloc.free(entry.key_ptr.*);
            }
            self.parameters.deinit();

            var class_iterator = self.classes.iterator();

            while (class_iterator.next()) |entry| {
                self.release();
                entry.value_ptr.deinit(alloc);
                alloc.free(entry.key_ptr.*);
            }
            std.debug.assert(self.references.load(.monotonic) == 0);
            if(self.parent) | parent | {
                parent.children -= 1;
            }
            self.classes.deinit();
        }
    };

    pub fn deinit(self: *ParamDatabase) void {
        self.context.deinit();
        for (self.sources.items) |source| {
            switch (source.*) {
                .diag => |diag| {
                    diag.release();
                    diag.deinit();
                },
                .file => |file| self.allocator.free(file),
                .programatic => {},
            }
        }
        self.sources.deinit();

    }
};

pub const MonolithicParam = struct {
    allocator:  Allocator,
    statements: []const Statement,
    file:       []const u8,
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn addRef(self: *MonolithicParam) void {
        _ = self.references.fetchAdd(1, .monotonic);
    }

    fn release(self: *MonolithicParam) void {
        _ = self.references.fetchSub(1, .monotonic);
    }

    pub fn read(allocator: Allocator, path: []const u8, text: []const u8, preproc: ParamPreproc) !MonolithicParam {
        return ParamParser.parse(
            allocator,
            path,
            text,
            preproc
        );
    }

    pub fn deinit(self: *MonolithicParam) void {
        const refs = self.references.load(.monotonic);
        if(refs > 1) {
            std.debug.print(
                "Cannot free {} in current context. It is being used for diagnostics in {} places",
                .{self.file, refs}
            );
            return;
        }

        self.allocator.free(self.file);
        for (self.statements) |*statement| statement.deinit(self.allocator);
        self.allocator.free(self.statements);

    }

    pub const Operator = enum {
        Assign,
        AddAssign,
        SubAssign,
    };

    pub const Value = union(enum) {
        array: []const Value,
        str:   []const u8,
        i64:   i64,
        i32:   i32,
        f32:   f32,
        expr:  []const u8,

        pub fn deinit(self: *Value, allocator: Allocator) void {
            switch (self.*) {
                .array => |arr| {
                    for (arr) |*val| val.deinit(allocator);
                    allocator.free(arr);
                },
                .str => |str| allocator.free(str),
                .expr => |expr| allocator.free(expr),
                else => {},
            }
        }
    };

    pub const Parameter = struct {
        name:  []const u8,
        op:    Operator,
        val:   Value,

        pub fn deinit(self: *Parameter, allocator: Allocator) void {
            allocator.free(self.name);
            self.val.deinit(allocator);
        }
    };

    pub const Statement = union {
        delete:     []const u8,
        exec:       []const u8,
        external:   []const u8,
        class:      Class,
        param:      Parameter,
        enumerable: []const EnumValue,

        pub fn deinit(self: *Statement, allocator: Allocator) void {
            switch (self.*) {
                .delete => |str| allocator.free(str),
                .exec => |str| allocator.free(str),
                .external => |str| allocator.free(str),
                .class => |class| class.deinit(allocator),
                .param => |param| param.deinit(allocator),
                .enumerable => |enums| {
                    for (enums) |*enum_val| enum_val.deinit(allocator);
                    allocator.free(enums);
                },
            }

        }
    };

    pub const EnumValue = struct {
        name: []const u8,
        value: f32,

        pub fn deinit(self: *EnumValue, allocator: Allocator) void {
            allocator.free(self.name);
        }
    };

    pub const Class = struct {
        name:       []const u8,
        base:       ?[]const u8,
        statements: []const Statement,
        pub fn deinit(self: *Class, allocator: Allocator) void {
            allocator.free(self.name);
            if (self.base) |base| allocator.free(base);

            for (self.statements) |*statement| statement.deinit(allocator);
        }

    };

};



pub const ParamPreproc = struct {
    allocator: Allocator,

    pub const PreprocOutput = struct {
        text: []const u8,
    };

    pub fn preprocess(self: *ParamPreproc, parseAlloc: Allocator, name: []const u8, text: []const u8) !PreprocOutput {
        _ = self;
        _ = name;
        _ = parseAlloc;
        return PreprocOutput {
            .text = text,
        };
    }
};

pub const ParamParser = struct {
    allocator: Allocator,
    index: usize = 0,
    stack: std.ArrayList(MutableClass),
    currentContext: MutableClass,
    procOutput: ParamPreproc.PreprocOutput,

    const MutableClass = struct {
        name:       []const u8,
        base:       ?[]const u8,
        statements: std.ArrayList(MonolithicParam.Statement),
    };

    pub fn isWhitespace(char: u8) bool {
        char == ' ' or char == '\n' or char == '\t' or char == '\r' or char == 0x000B or char == 0x000C;
    }

    pub fn skipWhitespace(self: *ParamParser) void {
        while (self.index < self.procOutput.text.len and isWhitespace(self.procOutput.text[self.index])) : (self.index += 1){}
    }

    pub fn getWord(self: *ParamParser) ![]u8 {
        self.skipWhitespace();
        const start = self.index;
        while (std.ascii.isAlphanumeric(self.procOutput.text[self.index]) or self.procOutput.text[self.index] ) : (self.index += 1){ }

        return self.allocator.dupe(u8, self.procOutput.text[start..self.index]);
    }

    pub fn parseArray(self: *ParamParser) !MonolithicParam.Value {
        _ = self;
    }

    pub fn parse(allocator: Allocator, path: []const u8, text: []const u8, preproc: ParamPreproc) !MonolithicParam {
        const self = ParamParser {
            .allocator = allocator,
            .index = 0,
            .stack = std.ArrayList(MonolithicParam.Statement).init(allocator),
            .currentContext = undefined,
            .procOutput = try preproc.preprocess(allocator, path, text),
        };

        try self.stack.append(MutableClass {
            .name = path,
            .base = null,
            .statements = std.ArrayList(MonolithicParam.Statement).init(allocator),
        });
        self.currentContext = self.stack.getLast();

        while (self.stack.items.len > 0) {
            self.skipWhitespace();

            if(self.index >= text.len) {
                if (self.stack.items.len > 1)  {
                    std.debug.print("Missing '}'", {});
                    return error.ParseFail;
                } else break;
            }

            switch (self.procOutput.text[self.index]) {
                '#' => {
                    //todo line
                    continue;
                },
                '}' => {
                    self.index += 1;
                    while (
                        self.index < self.procOutput.text.len and
                            (isWhitespace(self.procOutput.text[self.index]) or self.procOutput.text[self.index] == ';')
                    ) : (self.index += 1) {}
                    //semicolon enforcement
                    if (self.stack.items.len > 1)  {
                        const class: MutableClass = self.stack.pop();
                        self.currentContext = self.stack.getLast();
                        try self.currentContext.statements.append(MonolithicParam.Statement {
                            .class = MonolithicParam.Class {
                                .name = class.name,
                                .base = class.base,
                                .statements = try class.statements.toOwnedSlice()
                            }
                        });
                        continue;
                    } else {
                        std.debug.print("Invalid '}'", {});
                        return error.ParseFail;
                    }
                },
                else => {
                    const word = try self.getWord();
                    if(word.len == 0) {
                        std.debug.print("Expected word", {});
                        return error.ParseFail;
                    }
                    if(std.mem.eql(u8, word, "delete")) {
                        allocator.free(word);
                        word = try self.getWord();
                        if(word.len == 0) {
                            std.debug.print("Expected word", {});
                            return error.ParseFail;
                        }

                        self.skipWhitespace();
                        if (self.procOutput.text[self.index] != ';') {
                            std.debug.print("Expected semicolon.", {});
                            return error.ParseFail;
                        }

                        self.index += 1;

                        self.currentContext.statements.append(MonolithicParam.Statement {
                            .delete = word
                        });
                    } else if(std.mem.eql(u8, word, "class")) {
                        allocator.free(word);
                        word = try self.getWord();
                        if(word.len == 0) {
                            std.debug.print("Expected word", {});
                            return error.ParseFail;
                        }
                        self.skipWhitespace();

                        if (self.procOutput.text[self.index] == ';') {
                            self.index += 1;
                            self.currentContext.statements.append(MonolithicParam.Statement {
                                .external = word
                            });
                            continue;
                        }
                        const base: ?[]u8 = null;
                        if (self.procOutput.text[self.index] == ':') {
                            self.index += 1;
                            //visibility test
                            base = try self.getWord();
                            if(base.?.len == 0) {
                                std.debug.print("Expected word", {});
                                return error.ParseFail;
                            }

                            self.skipWhitespace();
                        }

                        if (self.procOutput.text[self.index] != '{') {
                            std.debug.print("Expected '{'", {});
                            return error.ParseFail;
                        }
                        self.index += 1;
                        try self.stack.append(MutableClass {
                            .name = word,
                            .base = base,
                            .statements = std.ArrayList(MonolithicParam.Statement).init(allocator)
                        });
                        self.currentContext = self.stack.getLast();
                        continue;
                    } else if(std.mem.eql(u8, word, "enum")) {
                        allocator.free(word);

                    } else if(std.mem.eql(u8, word, "__EXEC")) {
                        allocator.free(word);

                    } else { //this word is a parameter name; dont free, allocator still holds ownership
                        if(self.procOutput.text[self.index] == '[') {
                            self.index += 1;
                            self.skipWhitespace();
                            if(self.procOutput.text[self.index] != ']') {
                                std.debug.print("Expected ']'", {});
                                return error.ParseFail;
                            }

                            self.index += 1;
                            self.skipWhitespace();

                            var op = MonolithicParam.Operator.Assign;
                            if(self.procOutput.text[self.index] == '+') {
                                self.index += 1;
                                self.skipWhitespace();
                                op = .AddAssign;
                            } else if(self.procOutput.text[self.index] == '-') {
                                self.index += 1;
                                self.skipWhitespace();
                                op = .SubAssign;
                            }

                            if(self.procOutput.text[self.index] != '=') {
                                std.debug.print("Expected '='", {});
                                return error.ParseFail;
                            }
                            const value = try self.parseArray();

                            self.skipWhitespace();
                            if(self.procOutput.text[self.index] != ';') {
                                self.index += 1;
                                std.debug.print("Expected ';'", {});
                                return error.ParseFail;
                            }

                            self.currentContext.statements.append(MonolithicParam.Statement {
                                .param = MonolithicParam.Parameter {
                                    .name = word ,
                                    .op = op,
                                    .val = value
                                }
                            });
                            continue;
                        }
                        self.skipWhitespace();
                        if(self.procOutput.text[self.index] != '=') {
                            std.debug.print("Expected '='", {});
                            return error.ParseFail;
                        }
                        self.index += 1;

                    }

                }
            }
        }
    }
};