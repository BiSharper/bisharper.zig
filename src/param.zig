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
    
    pub const ParamContext = struct {
        database:   *ParamDatabase,
        access:     ParamAccess,
        parameters: std.StringHashMap(PolylithicValue),
        classes:    std.StringHashMap(ParamContext),
        pub fn addSource(self: *ParamContext, statements: *[]MonolithicParam.Statement, alloc: std.mem.Allocator) !void {
            for (statements) | statement | {
                switch (statement) {
                    .delete      => | target | {
                        if (self.access >= ParamAccess.ReadCreate) {
                            std.debug.print(
                                "Cannot delete {} in current context. The accesss is restricted",
                                .{target}
                            );
                            return error.InvalidAccess;
                        }
                        //todo lets delete that target
                    },
                    .exec        => | _ | {
                        std.debug.print("Exec not implemented");
                        return error.NotImplemented; //todo: wayy too much work right now
                    },
                    .external    => | _ | return error.NotImplemented,
                    .class       => | class | try self.addSource(class, alloc),
                    .param       => | parameter | {
                        if (self.access >= ParamAccess.ReadOnly) {
                            std.debug.print(
                                "Cannot add {} in current context. The accesss is restricted",
                                .{parameter.name}
                            );
                            return error.InvalidAccess;
                        }

                        switch (parameter.op) {
                            .Assign => {
                                const name = self.database.allocator.dupe(u8,  parameter.name.*) catch unreachable;
                                alloc.free(parameter.name);
                                parameter.name = &name;

                                self.context.parameters.put(name, switch (parameter.val) {

                                });
                            },
                            .AddAssign => return error.NotImplemented,
                            .SubAssign => return error.NotImplemented

                        }
                    },
                    .enumerable  => | _ | return error.NotImplemented,
                }
            }
        }

    };
    
    pub const ParamOwner = union {
        ast: MonolithicSource,
        programatic: void,
    };

    //arrays inside of arrays shouldnt have owners since you can only add or remove to the param not its inner arrays
    //We can conserve space by making another array type maybe but this will be done later; for now this is fine.
    pub const PolylithicValue = struct {
        value: Value,
        owner: ParamOwner,

        pub const Value = union {
            array:  std.ArrayList(PolylithicValue),
            string: []u8,
            i64:    i64,
            i32:    i32,
            f32:    f32,
        };
    };

    pub fn addSource(self: *ParamDatabase, ast: *MonolithicParam, diag: bool) !void {
        const source = if (diag) MonolithicSource {
            .diag = &ast,
        } else MonolithicSource {
            .file = &ast.file
        };

        try self.sources.append(source);

        for (ast.statements) | statement | {
            switch (statement) {
                .exec => {
                    return error.NotImplemented;
                },
                .external => {
                    return error.NotImplemented;
                },
                .class => {
                    return error.NotImplemented;
                },
                .param => {
                    return error.NotImplemented;
                },
                .enumerable => {
                    return error.NotImplemented;
                }
            }
        }


        // if(diag) { //free all the stuff we dont really need
        //
        // }
    }

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