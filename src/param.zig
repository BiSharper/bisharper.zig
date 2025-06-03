const std = @import("std");


pub const ParamDatabase = struct {
    allocator:  std.mem.Allocator,
    sources:    std.ArrayList(MonolithicParam.Source),
    context:    Context,

    pub const Access = enum(i3) {
        Default = -1, //basically read write
        ReadWrite = 0,
        ReadCreate = 1, //Only can add class members
        ReadOnly = 2,
        ReadOnlyVerified = 3
    };

    pub const Owner = union {
        ast: MonolithicParam.Source,
        programatic: void,
    };

    pub const Value = struct {
        value: Value,
        owner: Owner,

        pub const ValueType = union {
            array:      std.ArrayList(Value),
            nest_array: std.ArrayList(ValueType),
            string:     []u8,
            i64:        i64,
            i32:        i32,
            f32:        f32,

            pub fn deinit(self: *ValueType, allocator: std.mem.Allocator) void {
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

        pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
            self.value.deinit(allocator);
        }
    };

    pub const Context = struct {
        name:       *[]u8,
        database:   *ParamDatabase,
        access:     Access,
        parameters: std.StringHashMap(Value),
        classes:    std.StringHashMap(Context),
        base:       ?*Context,
        parent:     ?*Context,
        children:   i32,


        pub fn getClass(self: *Context, name: []u8) ?*Context {
            if (self.classes.get(name)) |*context| {
                return context;
            }

            return null;
        }

        pub fn addSource(self: *Context, ast: *MonolithicParam, diag: bool) !void {
            const source = if (diag) MonolithicParam.Source {
                .diag = &ast,
            } else MonolithicParam.Source {
                .file = &ast.file
            };

            try self.database.sources.append(source);
            try self.addStatements(ast.statements, self.database.allocator);
        }

        pub fn deinit(self: *Context) void {
            const alloc = self.database.allocator;

            alloc.free(self.name.*);

            var parameter_iterator = self.parameters.iterator();
            while (parameter_iterator.next()) |entry| {
                entry.value_ptr.deinit(alloc);
                alloc.free(entry.key_ptr.*);
            }
            self.parameters.deinit();

            var class_iterator = self.classes.iterator();

            while (class_iterator.next()) |entry| {
                self.children -= 1;
                entry.value_ptr.deinit(alloc);
                alloc.free(entry.key_ptr.*);
            }
            std.debug.assert(self.children == 0);
            if(self.parent) | parent | {
                parent.children -= 1;
            }
            self.classes.deinit();
        }

        //TODO FIXME
        fn addParam(self: *Context, ast: *MonolithicParam.Parameter) !void {
            if (self.access >= Access.ReadOnly) {
                std.debug.print(
                    "Cannot add {} in current context. The accesss is restricted",
                    .{ast.name}
                );
                return error.InvalidAccess;
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
                existing.deinit(self.database.allocator);
            }

            //TODO: We need to add our value now. Conversion is annoying to write so do this later

        }

        fn addExternal(self: *Context, name: *[]u8) !void {
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

                try self.classes.put(nameCopy, Context{
                    .database = &self.database,
                    .access = Access.Default,
                    .parameters = std.StringHashMap(Value).init(alloc),
                    .classes = std.StringHashMap(Context).init(alloc),
                    .base = null,
                    .name = &nameCopy
                });
            }
        }

        fn addClass(self: *Context, ast: *MonolithicParam.Class) !void {
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
                    if(base) | valid_base | {
                        valid_base.children += 1;
                    }
                    const nameCopy = try alloc.dupe(u8, ast.name.*);

                    const newContext = Context{
                        .database = &self.database,
                        .access = Access.Default,
                        .parameters = std.StringHashMap(Value).init(alloc),
                        .classes = std.StringHashMap(Context).init(alloc),
                        .base = base,
                        .name = &nameCopy
                    };
                    self.children += 1;
                    try self.classes.put(nameCopy, newContext);

                    break :blk newContext;
                }
            };
            try context.addStatements(ast.statements);
        }

        fn deleteClass(self: *Context, className: []u8) !void {
            if(self.access >= Access.ReadOnly) {
                std.debug.print(
                    "Cannot delete {} in current context. The accesss is restricted",
                    .{className}
                );
                return error.InvalidAccess;
            }

            if(self.getClass(className)) | class | {
                const remainingLinks = class.children - @as(i32, class.classes.count());
                if (remainingLinks > 1) {
                    std.debug.print(
                        "Cannot delete {} in current context. The target is still being referenced in {} places.",
                        .{className, remainingLinks}
                    );
                    return error.InvalidDelete;
                }
                self.classes.removeByPtr(class.name);
                class.deinit();
            }
        }

        fn addStatements(self: *Context, statements: []MonolithicParam.Statement) !void {
            for (statements) | statement | {
                switch (statement) {
                    .external   => | external | try self.addExternal(external),
                    .class      => | class | try self.addClass(class),
                    .param      => | param | try self.addParam(param),
                    .delete     => | class | try self.deleteClass(class),
                    .exec       => return error.NotImplemented,
                    .enumerable => return error.NotImplemented
                }
            }
        }
    };
};

pub const MonolithicParam = struct {
    allocator:  std.mem.Allocator,
    statements: []Statement,
    file:       []u8,

    pub const Operator = enum {
        Assign,
        AddAssign,
        SubAssign,
    };

    pub const Source = union {
        diag: *MonolithicParam,
        file: *[]u8,
    };

    pub const Value = union(enum) {
        array: []*Value,
        str:   []u8,
        i64:   *i64,
        i32:   *i32,
        f32:   *f32,
        expr:  *[]u8,
    };

    pub const Parameter = struct {
        name:  *[]u8,
        op:    Operator,
        val:   Value,
    };

    pub const Statement = union {
        delete:     *[]u8, 
        exec:       *[]u8,
        external:   *[]u8,
        class:      Class,
        param:      Parameter,
        enumerable: std.StringHashMap(f32),
    };

    pub const Class = struct {
        name:       *[]u8,
        base:       *?[]u8,
        statements: []Statement,
    };

};