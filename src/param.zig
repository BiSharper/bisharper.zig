const std = @import("std");

pub const ParamAccess = enum(i3) {
    Default = -1, //basically read write
    ReadWrite = 0,
    ReadCreate = 1, //Only can add class members
    ReadOnly = 2,
    ReadOnlyVerified = 3
};


pub const ParamValue = struct {
    pub const ValueType =  union {
        array: std.ArrayList(ParamValue),
        str:   []u8,
        i64:   i64,
        i32:   i32,
        f32:   f32,
        expr:  []u8,

        fn deinit(self: *ValueType, allocator: std.mem.Allocator) void {
            switch (self) {
                .array => |arr| {
                    for (arr.items) |val| val.deinit(allocator);
                    arr.deinit();
                },
                .str => |str| allocator.free(str),
                .expr => |expr| allocator.free(expr),
                else => {},
            }
        }
    };
    owner: ParamOwner,
    value: *ValueType,

    // if AST points to ValueType in ast struct, if programatic points to value in heap
    fn deinit(self: *ParamValue, allocator: std.mem.Allocator) void {
        if(self.owner == .Programatic) {
            self.value.deinit(allocator);
            allocator.free(self.value);
        }
    }
};

pub const ParamOwner = union {
    AST:          *ParamAST,
    Programatic:  void
};

pub const ParamClass = struct {
    const ACCESS_PARAM = "access";
    name:    []u8,
    access:  ParamAccess,
    classes: std.StringHashMap(ParamClass),
    params:  std.StringHashMap(ParamValue),
    owner:   ParamOwner,
    root:    *ParamFile,
    parent:  ?*ParamClass,
    ast:     std.ArrayList(ParamAST),


    pub fn pushAST(self: *ParamClass, ast: ParamAST) !void {
        const allocator = self.root.alloc;
        if(ast.allocator != allocator) try ast.realloc(allocator);

        //todo

        try self.ast.append(ast);
    }
    //
    // pub fn pushParam(comptime realloc: bool) !void {
    //
    // }

    pub fn deinit(self: *ParamClass) void {
        const allocator = self.root.alloc;
        allocator.free(self.name);

        for (self.classes.keyIterator(), self.classes.valueIterator()) |key, *value| {
            allocator.free(key);
            value.deinit(allocator);
        }
        self.classes.deinit();

        for (self.params.keyIterator(), self.params.valueIterator()) |key, *value| {
            allocator.free(key);
            value.deinit(allocator);
        }
        self.params.deinit();

        for (self.ast.items) |ast| ast.deinit();
        self.ast.deinit();
    }
};

pub const ParamFile = struct {
    pub usingnamespace ParamClass;

    inner:  ParamClass,
    alloc:  std.mem.Allocator,

    pub fn class(self: *ParamFile) *ParamClass {
        return &self.inner;
    }

    pub fn deinit(self: *ParamFile) void {
        self.deinit(self.class(), self.alloc);
    }
};

pub const ParamAST = struct {
    allocator:  std.mem.Allocator,
    statements: []Statement,

    pub const Operator = enum {
        Assign,
        AddAssign,
        SubAssign,
    };

    pub const Parameter = struct {
        name:  []u8,
        op:    Operator,
        val:   ParamValue.ValueType,

        fn deinit(self: *Parameter, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            self.val.deinit(allocator);
        }

        fn realloc(self: *Parameter, old_allocator: std.mem.Allocator, new_allocator: std.mem.Allocator) !void {
            const new_name = try new_allocator.dupe(u8, self.name);
            old_allocator.free(self.name);
            self.name = new_name;
            try self.val.realloc(old_allocator, new_allocator);
        }
    };

    pub const Statement = union {
        delete:     []u8,
        exec:       []u8,
        external:   []u8,
        class:      Class,
        param:      Parameter,
        enumerable: std.StringHashMap(f32),

        fn deinit(self: *Statement, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .delete => |del| allocator.free(del),
                .exec => |exec| allocator.free(exec),
                .external => |ext| allocator.free(ext),
                .param => |*param| param.deinit(allocator),
                .enumerable => |*enum_map| {
                    for (enum_map.keys()) |key| allocator.free(key);
                    enum_map.deinit();
                },
                .class => |*class| class.deinit(allocator)
            }
        }
        fn realloc(self: *Statement, old_allocator: std.mem.Allocator, new_allocator: std.mem.Allocator) !void {
            switch (self.*) {
                .delete => |del| {
                    const new_del = try new_allocator.dupe(u8, del);
                    old_allocator.free(del);
                    self.delete = new_del;
                },
                .exec => |exec| {
                    const new_exec = try new_allocator.dupe(u8, exec);
                    old_allocator.free(exec);
                    self.exec = new_exec;
                },
                .external => |ext| {
                    const new_ext = try new_allocator.dupe(u8, ext);
                    old_allocator.free(ext);
                    self.external = new_ext;
                },
                .param => |*param| try param.realloc(old_allocator, new_allocator),
                .enumerable => |*enum_map| {
                    var new_enum_map = std.StringHashMap(f32).init(new_allocator);

                    for (enum_map.keyIterator(), enum_map.valueIterator()) |key, value| {
                        const new_key = try new_allocator.dupe(u8, key);
                        try new_enum_map.put(new_key, value);
                    }

                    enum_map.deinit();
                    self.enumerable = new_enum_map;
                },
                .class => |*class| try class.realloc(old_allocator, new_allocator)
            }

        }
    };

    pub const Class = struct {
        name:       []u8,
        base:       ?[]u8,
        statements: []Statement,

        fn deinit(self: *Class, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            if (self.base) |base| allocator.free(base);
            for (self.statements) |stmt| stmt.deinit(allocator);
        }

        fn realloc(self: *Class, old_allocator: std.mem.Allocator, new_allocator: std.mem.Allocator) !void {
            const new_name = try new_allocator.dupe(u8, self.name);
            old_allocator.free(self.name);
            self.name = new_name;

            if (self.base) |base| {
                const new_base = try new_allocator.dupe(u8, base);
                old_allocator.free(base);
                self.base = new_base;
            }

            var new_statements = try new_allocator.alloc(Statement, self.statements.len);
            for (self.statements, 0..) |*statement, i| {
                try statement.realloc(old_allocator, new_allocator);
                new_statements[i] = statement.*;
            }
            old_allocator.free(self.statements);
            self.statements = new_statements;
        }
    };


    pub fn realloc(self: *ParamAST, allocator: std.mem.Allocator) void {
        if (self.allocator == allocator) {
            return;
        }
        var new_statements = try allocator.alloc(Statement, self.statements.len);
        for (self.statements, 0..) |*statement, i| {
            try statement.realloc(self.allocator, allocator);
            new_statements[i] = statement.*;
        }
        self.allocator.free(self.statements);
        self.statements = new_statements;
        self.allocator = allocator;

    }

    pub fn deinit(self: *ParamAST) void {
        for (self.statements) |statement| statement.deinit(self.allocator);
    }
};