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

                        for(values) | v | try innerArray.append(toValueType(alloc, v, true));

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
                    const array = try self.getOrCreateArrayAst(ast.name, source);
                    for(ast.val.array) |val| try array.value.array.append(convertValue(val, true));
                },
                .SubAssign => {
                    const array = try self.getOrCreateArrayAst(ast.name, source);

                    _ = array;
                    return error.SubAssignNotImplemented;//TODO: Lets sub here; we need to test how the tools do this
                }
            }
        }

        fn getOrCreateArrayAst(self: *Context, name: []const u8, source: *Source) !*Value {
            if (self.parameters.getPtr(name)) | array | if(array != .array) {
                error.ValueNotArray;
            } else array;

            const newArray = Value {
                .owner = source,
                .value = Value.ValueType {
                    .array = std.ArrayList(Value).init(self.database.allocator)
                }
            };
            const nameCopy = try self.database.allocator.dupe(u8, name);
            self.parameters.put(nameCopy, newArray);
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

        pub fn getClass(self: *Context, name: []u8) ?*Context {
            if (self.classes.get(name)) |*context| {
                return context;
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

    pub const Operator = enum {
        Assign,
        AddAssign,
        SubAssign,
    };

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
            try preproc.preprocess(allocator, path, text)
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
    processorAllocator: Allocator,

    pub fn preprocess(self: *ParamPreproc, allocator: Allocator, name: []const u8, text: []const u8) ![]const u8 {
        _ = self;
        _ = name;
        _ = allocator;
        return text;
    }
};

pub const ParamParser = struct {

    const MutableClass = struct {
        name:       []const u8,
        base:       ?[]const u8,
        statements: std.ArrayList(MonolithicParam.Statement),
    };

    pub fn isWhitespace(char: u8) bool {
        char == ' ' or char == '\n' or char == '\t' or char == '\r' or char == 0x000B or char == 0x000C;
    }

    pub fn parse(allocator: Allocator, path: []const u8, text: []const u8) !MonolithicParam {
        const index: usize = 0;
        const stack = std.ArrayList(MutableClass).init(allocator);
        defer stack.deinit();

        stack.append(MutableClass {
            .name = path,
            .base = null,
            .statements = std.ArrayList(MonolithicParam.Statement).init(allocator)
        });

        const currentContext: MutableClass = stack.getLast();
        while (stack.items.len > 0) {
            while (index < text.len and isWhitespace(text[index])) : (index += 1){}

            switch (text[index]) {
                '#' => {
                    //todo line
                    continue;
                },
                '}' => {
                    index += 1;
                    while (index < text.len and isWhitespace(text[index] or text[index] == ';')) : (index += 1){}
                    if (stack.items.len > 1) |last| {
                        const class: MutableClass = stack.pop();
                        currentContext = last;
                        try currentContext.statements.append(class);
                    } else {
                        break;
                    }
                }
            }
        }
    }


};