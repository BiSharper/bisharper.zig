const std = @import("std");

pub const ParamAccess = enum(i3) {
    Default = -1, //basically read write
    ReadWrite = 0,
    ReadCreate = 1, //Only can add class members
    ReadOnly = 2,
    ReadOnlyVerified = 3
};

pub const ParamDatabase = struct {
    allocator:  std.mem.Allocator,
    sources:    std.ArrayList(MonolithicSource),
    context:    ParamContext,


    pub const ParamOwner = union {
        ast: MonolithicSource,
        programatic: void,
    };

    pub const PolylithicValue = struct {
        value: Value,
        owner: ParamOwner,

        pub const Value = union {
            array:      std.ArrayList(PolylithicValue),
            nest_array: std.ArrayList(Value),
            string:     []u8,
            i64:        i64,
            i32:        i32,
            f32:        f32,
        };

        pub fn deinit(self: *PolylithicValue, allocator: std.mem.Allocator) void {
            switch (self.value) {
                .array => |*arr| {
                    for (arr.items) |*item| item.deinit(allocator);
                    arr.deinit();
                },
                .string => |str| allocator.free(str),
                .i64, .i32, .f32 => {},
            }
        }
    };

    pub const ParamContext = struct {
        database:   *ParamDatabase,
        access:     ParamAccess,
        parameters: std.StringHashMap(PolylithicValue),
        classes:    std.StringHashMap(ParamContext),
        base:       ?*ParamContext,

        fn addParam(self: *ParamContext, ast: *MonolithicParam.Parameter, alloc: std.mem.Allocator) !void {
            if (self.access >= ParamAccess.ReadOnly) {
                std.debug.print(
                    "Cannot add {} in current context. The accesss is restricted",
                    .{ast.name}
                );
                return error.InvalidAccess;
            }

            if (self.parameters.get(ast.name.*)) | existing | {
                if(self.access >= ParamAccess.ReadCreate) {
                    std.debug.print(
                        "Cannot update {} in current context. The accesss is restricted",
                        .{ast.name}
                    );
                    return error.InvalidAccess;
                }

                self.parameters.removeByPtr(ast.name.*);
                existing.deinit(alloc);
            }

            //TODO: We need to add our value now. Conversion is annoying to write so do this later

        }

        fn getClass(self: *ParamContext, name: []u8) ?*ParamContext {
            if (self.classes.get(name)) |*context| {
                return context;
            }

            return null;
        }

        fn addClass(self: *ParamContext, ast: *MonolithicParam.Class, alloc: std.mem.Allocator) !void {
            if(self.access >= ParamAccess.ReadOnly) {
                std.debug.print(
                    "Cannot add {} in current context. The accesss is restricted",
                    .{ast.name}
                );
                return error.InvalidAccess;
            }

            const context: ParamContext = blk: {
                if (self.classes.get(ast.name.*)) |existing| {
                    break :blk existing;
                } else {

                    const base: ?*ParamContext = if (ast.base.*) |baseName| self.getClass(baseName) else null;
                    if(ast.base and !base) {
                        std.debug.print(
                            "Undefined base class {}",
                            .{ast.base.?}
                        );
                        return error.UndefinedBase;
                    }

                    const newContext = ParamContext{
                        .database = &self.database,
                        .access = ParamAccess.Default,
                        .parameters = std.StringHashMap(PolylithicValue).init(self.database.allocator),
                        .classes = std.StringHashMap(ParamContext).init(self.database.allocator),
                        .base = base
                    };

                    try self.classes.put(ast.name.*, newContext);

                    break :blk newContext;
                }
            };

            _ = context;
            _ = alloc;

        }

        pub fn addSource(self: *ParamContext, ast: *MonolithicParam, diag: bool) !void {
            const source = if (diag) MonolithicSource {
                .diag = &ast,
            } else MonolithicSource {
                .file = &ast.file
            };

            try self.database.sources.append(source);

            for (ast.statements) | statement | {
                switch (statement) {
                    .exec => return error.NotImplemented,
                    .external => return error.NotImplemented,
                    .class => | class | try self.addClass(class, ast.allocator),
                    .param => | param | try self.addParam(param, ast.allocator),
                    .enumerable => return error.NotImplemented
                }
            }


            // if(diag) { //free all the stuff we dont really need
            //
            // }
        }

    };
};


pub const MonolithicSource = union {
    diag: *MonolithicParam,
    file: *[]u8,
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