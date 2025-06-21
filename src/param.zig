const std = @import("std");
const Allocator = std.mem.Allocator;

// pub const ParamDatabase = struct {
//     allocator:  Allocator,
//     sources:    std.ArrayList(MonolithicParam.Source),
//     context:    Context,
//
    // pub const Access = enum(i3) {
    //     Default = -1, //basically read write
    //     ReadWrite = 0,
    //     ReadCreate = 1, //Only can add class members
    //     ReadOnly = 2,
    //     ReadOnlyVerified = 3
    // };
//
//     pub const Source = union {
//         diag: *MonolithicParam,
//         file: []const u8,
//         programatic: void
//     };
//
//     pub const Value = struct {
//         value: ValueType,
//         owner: *Source,
//
//         pub const ValueType = union {
//             array:      std.ArrayList(Value),
//             nest_array: std.ArrayList(ValueType),
//             string:     []u8,
//             i64:        i64,
//             i32:        i32,
//             f32:        f32,
//
//             pub fn deinit(self: *ValueType, allocator: Allocator) void {
//                 switch (self.value) {
//                     .array => |*arr| {
//                         for (arr.items) |*item| item.deinit(allocator);
//                         arr.deinit();
//                     },
//                     .nest_array => | *arr | {
//                         for (arr.items) |*item| item.deinit(allocator);
//                         arr.deinit();
//                     },
//                     .string => |str| allocator.free(str),
//                     .i64, .i32, .f32 => {},
//                 }
//             }
//         };
//
//         pub fn deinit(self: *Value, allocator: Allocator) void {
//             self.value.deinit(allocator);
//         }
//     };
//
//     pub const Context = struct {
//         name:        []u8,
//         database:    *ParamDatabase,
//         access:      Access = Access.Default,
//         parameters:  std.StringHashMap(Value),
//         classes:     std.StringHashMap(Context),
//         base:        ?*Context,
//         parent:      ?*Context,
//         references:  std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
//         owner:       *Source,
//
//         fn addRef(self: *Context) void {
//             _ = self.references.fetchAdd(1, .monotonic);
//         }
//
//         fn outerReferences(self: *Context) u32 {
//             self.references.load(.monotonic) - self.classes.count();
//         }
//
//         fn release(self: *Context) void {
//             _ = self.references.fetchSub(1, .monotonic);
//         }
//
//         fn toValueType(alloc: Allocator, astValue: MonolithicParam.Value, inArray: bool) !Value {
//             return switch (astValue) {
//                 .string => |s| Value.ValueType{ .string = try alloc.dupe(u8, s) },
//                 .i64 => |v| Value.ValueType{ .i64 = v },
//                 .i32 => |v| Value.ValueType{ .i32 = v },
//                 .f32 => |v| Value.ValueType{ .f32 = v },
//                 .array =>| values | {
//                     if(inArray) {
//                         const innerArray = std.ArrayList(Value.ValueType).init(alloc);
//                         errdefer innerArray.deinit();
//
//                         for(values) | v | try innerArray.append(
//                             toValueType(alloc, v, true)
//                         );
//
//                         return Value.ValueType {
//                             .nest_array = innerArray
//                         };
//                     }
//                     const array = std.ArrayList(Value).init(alloc);
//                     for(values) | v | try array.append(toValueType(alloc, v, true));
//                     return Value.ValueType {
//                         .array = array
//                     };
//                 },
//             };
//         }
//
//         fn convertValue(alloc: Allocator, source: *Source, ast: MonolithicParam.Value, inArray: bool) !Value {
//             return Value{
//                 .value = toValueType(alloc, ast, inArray),
//                 .owner = source
//             };
//         }
//
//         fn addParamAst(self: *Context, ast: *MonolithicParam.Parameter, source: *Source) !void {
//             if (self.access >= Access.ReadOnly) {
//                 std.debug.print(
//                     "Cannot add {s} in current context. The accesss is restricted",
//                     .{ast.name}
//                 );
//                 return error.InvalidAccess;
//             }
//             const alloc = self.database.allocator;
//
//             switch (ast.op) {
//                 .Assign => {
//                     // if this is access we should hyjack it and set access
//                     if(std.mem.eql(u8 , ast.name, "access")) {
//                         if(ast.val == .i32) {
//                             self.access = @enumFromInt(ast.val.i32); //int to enum value
//                         } else {
//                             std.debug.print(
//                                 "Invalid Access {}",
//                                 .{ast.val.i32}
//                             );
//                             return error.WrongAccessInt;
//                         }
//
//                         return;
//                     }
//
//                     if (self.parameters.get(ast.name.*)) | existing | {
//                         if(self.access >= Access.ReadCreate) {
//                             std.debug.print(
//                                 "Cannot update {s} in current context. The accesss is restricted",
//                                 .{ast.name}
//                             );
//                             return error.InvalidAccess;
//                         }
//
//                         self.parameters.removeByPtr(ast.name.*);
//                         existing.deinit(alloc);
//                     }
//
//                     const nameCopy = try alloc.dupe(u8, ast.name.*);
//                     const value: Value = convertValue(alloc, source, ast.val, false);
//                     self.parameters.put(nameCopy, value);
//                 },
//                 .AddAssign => {
//                     if (ast.val != .array) {
//                         return error.InvalidAddAssign;
//                     }
//                     const array = try self.getOrCreateArrayAst(
//                         ast.name,
//                         source,
//                         ast.val.array.len
//                     );
//                     for(ast.val.array) |val| try array.value.array.append(convertValue(alloc, source,val, true));
//                 },
//                 .SubAssign => {
//                     if (ast.val != .array) {
//                         return error.InvalidSubAssign;
//                     }
//                     const array = try self.getOrCreateArrayAst(ast.name, source, 0);
//                     if(array.value.array.items.len == 0) return;
//
//                     return error.SubAssignNotImplemented;//TODO: Lets sub here; we need to test how the tools do this
//                 }
//             }
//         }
//
//         fn getOrCreateArrayAst(self: *Context, name: []const u8, source: *Source, capacity: usize) !*Value {
//             if (self.parameters.getPtr(name)) | array | if(array != .array) {
//                 error.ValueNotArray;
//             } else array;
//
//             const newArray = Value {
//                 .owner = source,
//                 .value = Value.ValueType {
//                     .array = std.ArrayList(Value).initCapacity(Allocator, capacity)
//                 }
//             };
//             const nameCopy = try self.database.allocator.dupe(u8, name);
//             try self.parameters.put(nameCopy, newArray);
//             return self.parameters.getPtr(nameCopy);
//         }
//
//         fn addExternalAst(self: *Context, name: []const u8, source: *Source) !void {
//             if(self.access >= Access.ReadOnly) {
//                 std.debug.print(
//                     "Cannot add {s} in current context. The accesss is restricted",
//                     .{name}
//                 );
//                 return error.InvalidAccess;
//             }
//             const alloc = self.database.allocator;
//
//             if (!self.classes.contains(name.*)) {
//                 const nameCopy = try alloc.dupe(u8, name.*);
//                 self.addRef();
//                 try self.classes.put(nameCopy, Context{
//                     .database = &self.database,
//                     .access = Access.Default,
//                     .parameters = std.StringHashMap(Value).init(alloc),
//                     .classes = std.StringHashMap(Context).init(alloc),
//                     .base = null,
//                     .name = nameCopy,
//                     .owner = source
//                 });
//             }
//         }
//
//         fn addClassAst(self: *Context, ast: *MonolithicParam.Class, source: *Source) !void {
//             if(self.access >= Access.ReadOnly) {
//                 std.debug.print(
//                     "Cannot add {s} in current context. The accesss is restricted",
//                     .{ast.name}
//                 );
//                 return error.InvalidAccess;
//             }
//             const alloc = self.database.allocator;
//             const context: Context = blk: {
//                 if (self.classes.get(ast.name.*)) |existing| {
//                     break :blk existing;
//                 } else {
//                     const base: ?*Context = if (ast.base) blkBase: {
//                         const base_entry = try self.findEntry(ast.base.?.name, true, true);
//                         if( base_entry == null or base_entry.?.* != .class) {
//                             std.debug.print("Failed to find base class {s}", .{ast.base.?.name});
//                             return error.UndefinedBase;
//                         }
//                         break :blkBase base_entry.?.class;
//                     } else null;
//
//                     if(base) | valid_base | valid_base.addRef();
//                     const nameCopy = try alloc.dupe(u8, ast.name.*);
//
//                     const newContext = Context{
//                         .database = &self.database,
//                         .access = Access.Default,
//                         .parameters = std.StringHashMap(Value).init(alloc),
//                         .classes = std.StringHashMap(Context).init(alloc),
//                         .base = base,
//                         .name = nameCopy,
//                         .owner = source
//                     };
//                     self.addRef();
//                     try self.classes.put(nameCopy, newContext);
//
//                     break :blk newContext;
//                 }
//             };
//             try context.addStatementsAst(ast.statements, source);
//             if (context.access == .Default) {
//                 if(context.base != null and context.base.?.access > .Default) {
//                     context.access = context.base.?.access;
//                 } else if( context.parent) | parent | {
//                     var ctx: ?*Context = parent;
//                     while (ctx) {
//                         if(ctx.access > .Default) {
//                             context.access = ctx.access;
//                             break;
//                         }
//                         if(ctx.base and ctx.base.?.access > .Default) {
//                             context.access = ctx.base.?.access;
//                             break;
//                         }
//                         ctx = parent.parent;
//                     }
//                 }
//             }
//         }
//
//         fn deleteClassAst(self: *Context, className: []const u8) !void {
//             if(self.access >= Access.ReadOnly) {
//                 std.debug.print(
//                     "Cannot delete {s} in current context. The accesss is restricted",
//                     .{className}
//                 );
//                 return error.InvalidAccess;
//             }
//
//             if(self.getClass(className)) | class | {
//                 const remainingLinks = class.outerReferences();
//                 if (remainingLinks > 0) {
//                     std.debug.print(
//                         "Cannot delete {s} in current context. The target is still being referenced in {} places.",
//                         .{className, remainingLinks}
//                     );
//                     return error.InvalidDelete;
//                 }
//                 self.release();
//                 self.classes.removeByPtr(class.name);
//                 class.deinit();
//             }
//         }
//
//         fn addStatementsAst(self: *Context, statements: []const MonolithicParam.Statement, source: *Source) !void {
//             for (statements) | statement | {
//                 switch (statement) {
//                     .external   => | external | try self.addExternalAst(external, source),
//                     .class      => | class | try self.addClassAst(class, source),
//                     .param      => | param | try self.addParamAst(param, source),
//                     .delete     => | class | try self.deleteClassAst(class),
//                     .exec       => return error.NotImplemented,
//                     .enumerable => return error.NotImplemented
//                 }
//             }
//         }
//
//         pub const Entry = union {
//             class: *Context,
//             param: *Value
//         };
//
//         pub fn getClass(self: *Context, name: []const u8) ?*Context {
//             if (self.classes.get(name)) |*context| {
//                 return context;
//             }
//
//             return null;
//         }
//
//         pub fn findEntry(self: *Context, name: []const u8, parent: bool, base: bool) !?Entry {
//             if (self.getClass(name)) | clazz | return Entry {
//                 .class = clazz
//             } else if (self.getParam(name)) | param | return Entry {
//                 .param = param
//             } else if (base and self.base) {
//                 return self.base.?.findEntry(name, false, true);
//             } else if(parent and self.parent) {
//                 return self.parent.?.findEntry(name, parent, base);
//             } else return null;
//         }
//
//         pub fn derivedFrom(self: *Context, parent: *Context) bool {
//             const base: ?*Context = self;
//             while (base) | found| {
//                 if(found == parent) return true;
//                 base = found.base;
//             }
//             return false;
//         }
//
//         pub fn getParam(self: *Context, name: []const u8) ?*Value {
//             if (self.parameters.getPtr(name)) |parameter| {
//                 return parameter;
//             }
//
//             return null;
//         }
//
//         pub fn getParamOwner(self: *Context, name: []const u8) ?*Source {
//             if (try self.getParam(name)) | param | {
//                 return param.owner;
//             }
//
//             return null;
//         }
//
//         pub fn getString(self: *Context, name: []const u8) ?[]u8 {
//             if (self.getParam(name)) | param | {
//                 if(param.value != .string) return null;
//                 return param.value.string;
//             }
//             return null;
//         }
//
//         pub fn getInt32(self: *Context, name: []const u8) ?*i32 {
//             if (self.getParam(name)) | param | {
//                 if(param.value != .i32) return null;
//                 return param.value.i32;
//             }
//
//             return null;
//         }
//
//         pub fn getInt64(self: *Context, name: []const u8) ?*i64 {
//             if (self.getParam(name)) | param | {
//                 if(param.value != .i64) return null;
//                 return param.value.i64;
//             }
//
//             return null;
//         }
//
//         pub fn getFloat(self: *Context, name: []const u8) ?*f32 {
//             if (self.getParam(name)) | param | {
//                 if(param.value != .f32) return null;
//                 return param.value.f32;
//             }
//
//             return null;
//         }
//
//         pub fn addSource(self: *Context, ast: *MonolithicParam, diag: bool) !void {
//             const source = if (diag) {
//                 ast.addRef();
//                 MonolithicParam.Source {
//                     .diag = &ast,
//                 };
//             } else {
//                 MonolithicParam.Source {
//                     .file = try self.database.allocator.dupe(u8, ast.file)
//                 };
//             };
//
//             try self.database.sources.append(source);
//             try self.addStatementsAst(ast.statements, &source);
//         }
//
//         pub fn deinit(self: *Context) void {
//             const alloc = self.database.allocator;
//
//             alloc.free(self.name);
//
//             var parameter_iterator = self.parameters.iterator();
//             while (parameter_iterator.next()) |entry| {
//                 entry.value_ptr.deinit(alloc);
//                 alloc.free(entry.key_ptr.*);
//             }
//             self.parameters.deinit();
//
//             var class_iterator = self.classes.iterator();
//
//             while (class_iterator.next()) |entry| {
//                 self.release();
//                 entry.value_ptr.deinit(alloc);
//                 alloc.free(entry.key_ptr.*);
//             }
//             std.debug.assert(self.references.load(.monotonic) == 0);
//             if(self.parent) | parent | {
//                 parent.children -= 1;
//             }
//             self.classes.deinit();
//         }
//     };
//
//     pub fn deinit(self: *ParamDatabase) void {
//         self.context.deinit();
//         for (self.sources.items) |source| {
//             switch (source.*) {
//                 .diag => |diag| {
//                     diag.release();
//                     diag.deinit();
//                 },
//                 .file => |file| self.allocator.free(file),
//                 .programatic => {},
//             }
//         }
//         self.sources.deinit();
//
//     }
// };
//
// pub const MonolithicParam = struct {
//     allocator:  Allocator,
//     statements: std.ArrayList(Statement),
//     file:       []const u8,
//     references: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
//
//     fn addRef(self: *MonolithicParam) void {
//         _ = self.references.fetchAdd(1, .monotonic);
//     }
//
//     fn release(self: *MonolithicParam) void {
//         _ = self.references.fetchSub(1, .monotonic);
//     }
//
//     pub fn read(allocator: Allocator, path: []const u8, text: []const u8, preproc: *ParamPreproc) !MonolithicParam {
//         return ParamParser.parse(
//             allocator,
//             path,
//             text,
//             preproc
//         );
//     }
//
//     pub fn deinit(self: *MonolithicParam) void {
//         const refs = self.references.load(.monotonic);
//         if(refs > 1) {
//             std.debug.print(
//                 "Cannot free {s} in current context. It is being used for diagnostics in {} places",
//                 .{self.file, refs}
//             );
//             return;
//         }
//
//         self.allocator.free(self.file);
//         for (self.statements.items) |*statement| statement.deinit(self.allocator);
//         self.allocator.free(self.statements);
//
//     }
//
//     pub const Operator = enum {
//         Assign,
//         AddAssign,
//         SubAssign,
//     };
//
//     pub const Value = union(enum) {
//         array: []Value,
//         str:   []const u8,
//         i64:   i64,
//         i32:   i32,
//         f32:   f32,
//         expr:  []const u8,
//
//         pub fn deinit(self: *Value, allocator: Allocator) void {
//             switch (self.*) {
//                 .array => |arr| {
//                     for (arr) |*val| val.deinit(allocator);
//                     allocator.free(arr);
//                 },
//                 .str => |str| allocator.free(str),
//                 .expr => |expr| allocator.free(expr),
//                 else => {},
//             }
//         }
//     };
//
//     pub const Parameter = struct {
//         name:  []const u8,
//         op:    Operator,
//         val:   Value,
//
//         pub fn deinit(self: *Parameter, allocator: Allocator) void {
//             allocator.free(self.name);
//             self.val.deinit(allocator);
//         }
//     };
//
//     pub const Statement = union(enum) {
//         delete:     []const u8,
//         exec:       []const u8,
//         external:   []const u8,
//         class:      Class,
//         param:      Parameter,
//         enumerable: []EnumValue,
//
//         pub fn deinit(self: *Statement, allocator: Allocator) void {
//             switch (self.*) {
//                 .delete => |str| allocator.free(str),
//                 .exec => |str| allocator.free(str),
//                 .external => |str| allocator.free(str),
//                 .class => |*class| class.deinit(allocator),
//                 .param => |*param| param.deinit(allocator),
//                 .enumerable => |enums| {
//                     for (enums) |*enum_val| enum_val.deinit(allocator);
//                     allocator.free(enums);
//                 },
//             }
//
//         }
//     };
//
//     pub const EnumValue = struct {
//         name: []const u8,
//         value: f32,
//
//         pub fn deinit(self: *EnumValue, allocator: Allocator) void {
//             allocator.free(self.name);
//         }
//     };
//
//     pub const Class = struct {
//         name:       []const u8,
//         base:       ?*Class,
//         parent:     ?*Class,
//         statements: std.ArrayList(Statement),
//
//         pub fn deinit(self: *Class, allocator: Allocator) void {
//             allocator.free(self.name);
//             if (self.base) |base| allocator.free(base);
//
//             for (self.statements.items) |*statement| statement.deinit(allocator);
//             self.statements.deinit();
//         }
//
//         pub fn getParam(self: *Class, name: []const u8) ?*Statement {
//             for(self.statements.items) |*statement| {
//                 if(statement.* == .param) {
//                     if(std.mem.eql(u8, statement.param.name, name)) {
//                         return statement;
//                     }
//                 }
//             }
//
//             return null;
//         }
//
//         pub fn getClass(self: *Class, name: []const u8) ?*Statement {
//             for(self.statements.items) |*statement| {
//                 if(statement.* == .class) {
//                     if(std.mem.eql(u8, statement.class.name, name)) {
//                         return statement;
//                     }
//                 }
//             }
//
//             return null;
//         }
//
//         pub fn findEntry(self: *Class, name: []const u8, parent: bool, base: bool) !?*Statement {
//             if (self.getClass(name)) | clazz | return clazz else
//             if (self.getParam(name)) | param | return param else
//             if (base and self.base != null) return self.base.?.findEntry(name, false, true) else
//             if (parent and self.parent != null) return self.parent.?.findEntry(name, parent, base) else
//             return null;
//         }
//     };
//
// };
//
// pub const ParamPreproc = struct {
//     allocator: Allocator,
//
//     pub const PreprocOutput = struct {
//         text: []const u8,
//     };
//
//     pub fn preprocess(self: *ParamPreproc, parseAlloc: Allocator, name: []const u8, text: []const u8) !PreprocOutput {
//         _ = self;
//         _ = name;
//         _ = parseAlloc;
//         return PreprocOutput {
//             .text = text,
//         };
//     }
// };
//
// pub const ParamParser = struct {
//     allocator: Allocator,
//     index: usize = 0,
//     stack: std.ArrayList(MonolithicParam.Class),
//     currentContext: *MonolithicParam.Class,
//     procOutput: ParamPreproc.PreprocOutput,
//
//
//     pub fn isWhitespace(char: u8) bool {
//         return char == ' ' or char == '\n' or char == '\t' or char == '\r' or char == 0x000B or char == 0x000C;
//     }
//
//     pub fn skipWhitespace(self: *ParamParser) void {
//         while (self.index < self.procOutput.text.len and isWhitespace(self.procOutput.text[self.index])) : (self.index += 1){}
//     }
//
//     pub fn getWord(self: *ParamParser) ![]u8 {
//         self.skipWhitespace(); //1024 max
//         const start = self.index;
//         while (std.ascii.isAlphanumeric(self.procOutput.text[self.index]) or self.procOutput.text[self.index] == '_') : (self.index += 1){ }
//
//         return self.allocator.dupe(u8, self.procOutput.text[start..self.index]);
//     }
//
//     pub fn parseArray(self: *ParamParser) !MonolithicParam.Value {
//         _ = self;
//         return error.NotImplemented;
//     }
//
//     pub fn parse(allocator: Allocator, path: []const u8, text: []const u8, preproc: *ParamPreproc) !MonolithicParam {
//         var self = ParamParser {
//             .allocator = allocator,
//             .index = 0,
//             .stack = std.ArrayList(MonolithicParam.Class).init(allocator),
//             .currentContext = undefined,
//             .procOutput = try preproc.preprocess(allocator, path, text),
//         };
//         var context = MonolithicParam.Class {
//             .name = path,
//             .base = null,
//             .parent = null,
//             .statements = std.ArrayList(MonolithicParam.Statement).init(allocator),
//         };
//         try self.stack.append(context);
//         self.currentContext = &context;
//
//         while (self.stack.items.len > 0) {
//             self.skipWhitespace();
//
//             if(self.index >= text.len) {
//                 if (self.stack.items.len > 1)  {
//                     std.debug.print("Missing '}}'", .{});
//                     return error.ParseFail;
//                 } else break;
//             }
//
//             switch (self.procOutput.text[self.index]) {
//                 '#' => {
//                     //todo line
//                     continue;
//                 },
//                 '}' => {
//                     self.index += 1;
//                     while (
//                         self.index < self.procOutput.text.len and
//                             (isWhitespace(self.procOutput.text[self.index]) or self.procOutput.text[self.index] == ';')
//                     ) : (self.index += 1) {}
//                     //semicolon enforcement
//                     if (self.stack.items.len > 1)  {
//                         const class: MonolithicParam.Class = self.stack.pop().?;
//                         self.currentContext = class.parent.?;
//                         try self.currentContext.statements.append(MonolithicParam.Statement {
//                             .class = class
//                         });
//                         continue;
//                     } else {
//                         std.debug.print("Invalid '}}'", .{});
//                         return error.ParseFail;
//                     }
//                 },
//                 else => {
//                     var word = try self.getWord();
//                     if(word.len == 0) {
//                         std.debug.print("Expected word", .{});
//                         return error.ParseFail;
//                     }
//                     if(std.mem.eql(u8, word, "delete")) {
//                         allocator.free(word);
//                         word = try self.getWord();
//                         if(word.len == 0) {
//                             std.debug.print("Expected word", .{});
//                             return error.ParseFail;
//                         }
//
//                         self.skipWhitespace();
//                         if (self.procOutput.text[self.index] != ';') {
//                             std.debug.print("Expected semicolon.", .{});
//                             return error.ParseFail;
//                         }
//
//                         self.index += 1;
//
//                         try self.currentContext.statements.append(MonolithicParam.Statement {
//                             .delete = word
//                         });
//                     } else if(std.mem.eql(u8, word, "class")) {
//                         allocator.free(word);
//                         word = try self.getWord();
//                         if(word.len == 0) {
//                             std.debug.print("Expected word", .{});
//                             return error.ParseFail;
//                         }
//                         self.skipWhitespace();
//
//                         if (self.procOutput.text[self.index] == ';') {
//                             self.index += 1;
//                             try self.currentContext.statements.append(MonolithicParam.Statement {
//                                 .external = word
//                             });
//                             continue;
//                         }
//                         const base = if (self.procOutput.text[self.index] == ':') blk: {
//                             self.index += 1;
//                             //visibility test
//                             const base_name = try self.getWord();
//                             if(base_name.len == 0) {
//                                 std.debug.print("Expected word", .{});
//                                 return error.ParseFail;
//                             }
//                             const base_entry = try self.currentContext.findEntry(base_name, true, true);
//                             if( base_entry == null or base_entry.?.* != .class) {
//                                 std.debug.print("Failed to find base class {s}", .{base_name});
//                                 return error.ParseFail;
//                             }
//
//                             self.skipWhitespace();
//                             break :blk &base_entry.?.class;
//                         } else null;
//
//                         if (self.procOutput.text[self.index] != '{') {
//                             std.debug.print("Expected '{{'", .{});
//                             return error.ParseFail;
//                         }
//                         self.index += 1;
//                         var next = MonolithicParam.Class {
//                             .name = word,
//                             .parent = self.currentContext,
//                             .base = base,
//                             .statements = std.ArrayList(MonolithicParam.Statement).init(allocator)
//                         };
//                         try self.stack.append(next);
//                         self.currentContext = &next;
//                         continue;
//                     } else if(std.mem.eql(u8, word, "enum")) {
//                         allocator.free(word);
//
//                     } else if(std.mem.eql(u8, word, "__EXEC")) {
//                         allocator.free(word);
//
//                     } else {
//                         if(self.procOutput.text[self.index] == '[') {
//                             self.index += 1;
//                             self.skipWhitespace();
//                             if(self.procOutput.text[self.index] != ']') {
//                                 std.debug.print("Expected ']'", .{});
//                                 return error.ParseFail;
//                             }
//
//                             self.index += 1;
//                             self.skipWhitespace();
//
//                             var op = MonolithicParam.Operator.Assign;
//                             if(self.procOutput.text[self.index] == '+') {
//                                 self.index += 1;
//                                 self.skipWhitespace();
//                                 op = .AddAssign;
//                             } else if(self.procOutput.text[self.index] == '-') {
//                                 self.index += 1;
//                                 self.skipWhitespace();
//                                 op = .SubAssign;
//                             }
//
//                             if(self.procOutput.text[self.index] != '=') {
//                                 std.debug.print("Expected '='", .{});
//                                 return error.ParseFail;
//                             }
//                             const value = try self.parseArray();
//
//                             self.skipWhitespace();
//                             if(self.procOutput.text[self.index] != ';') {
//                                 self.index += 1;
//                                 std.debug.print("Expected ';'", .{});
//                                 return error.ParseFail;
//                             }
//
//                             try self.currentContext.statements.append(MonolithicParam.Statement {
//                                 .param = MonolithicParam.Parameter {
//                                     .name = word ,
//                                     .op = op,
//                                     .val = value
//                                 }
//                             });
//                             continue;
//                         }
//
//                         self.skipWhitespace();
//                         if(self.procOutput.text[self.index] != '=') {
//                             std.debug.print("Expected '='", .{});
//                             return error.ParseFail;
//                         }
//                         self.index += 1;
//
//                     }
//
//                 }
//             }
//         }
//         if(self.stack.pop()) |file | {
//             return MonolithicParam {
//                 .allocator = allocator,
//                 .file = file.name,
//                 .statements = file.statements
//             };
//         }
//         std.debug.print("File was popped...", .{});
//         return error.ParseFail;
//
//     }
// };

const smartptr = @import("smartptr.zig");

pub const ParamValue = union(enum) {
    array:      []ParamValue,
    str:        []const u8,
    i64:        i64,
    i32:        i32,
    f32:        f32,
    expr:       []const u8,
};
const InnerHandle = smartptr.Arc(ParamFile.Class);
pub const ParamHandleWeak = InnerHandle.Weak;
pub const ParamHandle = struct {
    arc: smartptr.Arc(ParamContext),
    //helper for zls - comptime abstraction
    pub const acquireClass = ParamContext.acquireClass;
    pub const getClass = ParamContext.getClass;
    pub const acquireParent = ParamContext.acquireParent;
    pub const acquireBase = ParamContext.acquireBase;
    pub const acquireSelf = ParamContext.acquireSelf;
    pub const getSelf = ParamContext.getSelf;

    pub usingnamespace @typeInfo(ParamContext).Struct;

    pub fn release(self: *const ParamHandle) void {
        for (self.arc.value.ancestor_counters) |counter_ptr| {
            _ = @atomicRmw(usize, counter_ptr, .Sub, 1, .AcqRel);
        }

        var ctx = self.arc.releaseUnwrap() orelse return;
        ctx.deinit();
    }

    pub fn createClass(self: *const ParamHandle, name: []const u8) !ParamHandle {
        const parent_ctx = self.arc.value;
        const alloc = self.arc.value.file.alloc;

        parent_ctx.mutex.lock();
        defer parent_ctx.mutex.unlock();

        if (parent_ctx.classes.get(name)) |existing_arc| {
            for (existing_arc.value.outer_strong_ctrs) |counter_ptr| {
                _ = @atomicRmw(usize, counter_ptr, .Add, 1, .AcqRel);
            }
            return ParamHandle{ .arc = existing_arc.retain() };
        }
        const child_ctx = try alloc.create(ParamContext);
        errdefer alloc.destroy(child_ctx);

        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);

        const parent_outer = parent_ctx.outer_strong_ctrs;
        const new_outer = try alloc.alloc(*volatile usize, parent_outer.len + 1);
        errdefer alloc.free(new_outer);

        @memcpy(new_outer[0..parent_outer.len], parent_outer);
        new_outer[parent_outer.len] = &child_ctx.outer_strong;

        child_ctx.* = .{
            .name = owned_name,
            .parent = self.arc.downgrade(),
            .extends = null,
            .file = parent_ctx.file,
            .access = .Default,
            .classes = std.StringHashMap(smartptr.Arc(ParamContext)).init(alloc),
            .parameters = std.StringHashMap(Parameter).init(alloc),
            .outer_strong = 0,
            .outer_strong_ctrs = new_outer,
            .mutex = .{},
        };

        const child_arc = try smartptr.arc(alloc, child_ctx);

        try parent_ctx.classes.put(child_ctx.name.*, child_arc);

        for (child_ctx.outer_strong_ctrs) |counter_ptr| {
            _ = @atomicRmw(usize, counter_ptr, .Add, 1, .AcqRel);
        }

        return ParamHandle{ .arc = child_arc.retain() };
    }
};

pub const Parameter = struct {
    parent:     ParamHandleWeak,
    name:       *[]const u8,
    value:      ParamValue,
};

pub const ParamContext = struct {
    mutex:             std.Thread.Mutex = std.Thread.Mutex{},
    name:              *[]const u8, //should already be freed when self::deinit called
    parent:            ?ParamHandleWeak,
    extends:           ?ParamHandleWeak = null,
    file:              *ParamFile,
    access:            Access = .Default,
    classes:           std.StringHashMap(InnerHandle),
    parameters:        std.StringHashMap(Parameter),
    outer_strong:      usize = 0,
    outer_strong_ctrs: []const *volatile usize,

    pub const Access = enum(i8) {
        Default = -1, //basically read write
        ReadWrite = 0,
        ReadCreate = 1, //Only can add class members
        ReadOnly = 2,
        ReadOnlyVerified = 3
    };

    pub fn acquireClass(self: *ParamContext, name: []const u8) ?ParamHandle {
        if (self.classes.get(name)) |class_arc| {
            for (class_arc.value.outer_strong_ctrs) |counter_ptr| {
                _ = @atomicRmw(usize, counter_ptr, .Add, 1, .AcqRel);
            }

            return ParamHandle{ .arc = class_arc.retain() };
        }

        return null;
    }

    pub fn getClass(self: *const ParamContext, name: []const u8) ?ParamHandleWeak {
        if (self.classes.get(name)) |class_arc| {
            return class_arc.downgrade();
        }

        return null;
    }

    pub fn acquireParent(self: *const ParamContext) ?ParamHandle {
        const parent_arc = (self.parent orelse return null).upgrade() orelse return null;

        for (parent_arc.value.outer_strong_ctrs) |counter_ptr| {
            _ = @atomicRmw(usize, counter_ptr, .Add, 1, .AcqRel);
        }

        return ParamHandle{ .arc = parent_arc };
    }

    pub fn acquireBase(self: *const ParamContext) ?ParamHandle {
        const base_arc = (self.extends orelse return null).upgrade() orelse return null;
        for (base_arc.value.outer_strong_ctrs) |counter_ptr| {
            _ = @atomicRmw(usize, counter_ptr, .Add, 1, .AcqRel);
        }
        return ParamHandle{ .arc = base_arc };
    }

    pub fn acquireSelf(self: *ParamContext) ParamHandle {
        if (self.parent == null) {
            for (self.file.context.value.outer_strong_ctrs) |counter_ptr| {
                _ = @atomicRmw(usize, counter_ptr, .Add, 1, .AcqRel);
            }

            return ParamHandle { .arc = self.file.context.retain() };
        }

        const parent_strong = self.acquireParent() orelse return error.NoParent;
        defer parent_strong.release();

        parent_strong.arc.value.acquireClass(self.name) orelse return error.WrongParent;
    }

    pub fn getSelf(self: *const ParamContext) ?ParamHandleWeak {
        if (self.parent == null) return self.file.context.downgrade();
        const parent_arc = (self.parent orelse return null).upgrade() orelse return null;
        defer parent_arc.release();

        if (parent_arc.value.classes.get(self.name)) |class_arc| {
            return class_arc.downgrade();
        }

        return null;
    }

    fn deinit(self: *ParamContext) void {
        const allocator = self.file.alloc;

        if(self.extends) |extends| extends.release();
        if(self.parent) |parent| parent.release();

        var param_iter = self.parameters.iterator();
        while (param_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);

            entry.value_ptr.parent.release();
            switch (entry.value_ptr.value.*) {
                .array => | array | {
                    for (array) |*item| item.deinit(allocator);
                    allocator.free(array);
                },
                .str, .expr => |str| allocator.free(str),
                .i64, .i32, .f32 => {},
            }
        }

        self.parameters.deinit();


        var class_iter = self.classes.iterator();
        while (class_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);

            const handle = entry.value_ptr.*;
            handle.value.deinit();
            allocator.destroy(handle.value);
            handle.release();
        }
        self.classes.deinit();
    }
};

pub const ParamFile = struct {
    alloc: std.mem.Allocator,
    name:  []const u8,
    context: InnerHandle,
    pub usingnamespace @typeInfo(ParamContext).Struct;

    pub fn init(alloc: Allocator, name: []const u8) !ParamFile {
        const file = try alloc.create(ParamFile);
        errdefer alloc.destroy(file);

        file.alloc = alloc;
        file.name = try alloc.dupe(u8, name);
        errdefer alloc.free(file.name);

        const root_ctx = try alloc.create(ParamContext);
        errdefer alloc.destroy(root_ctx);

        file.context = try smartptr.arc(alloc, root_ctx);

        root_ctx.* = .{
            .name = &file.name,
            .file = file,
            .parent = null,
            .extends = null,
            .access = .Default,
            .classes = std.StringHashMap(smartptr.Arc(ParamContext)).init(alloc),
            .parameters = std.StringHashMap(Parameter).init(alloc),
            .outer_strong = 0,
            .outer_strong_ctrs = try alloc.alloc(*volatile usize, 1),
        };

        root_ctx.outer_strong_ctrs[0] = &root_ctx.outer_strong;

        return file;
    }

    pub fn deinit(self: *ParamFile) void {
        if(self.context.value.outer_strong == 0) {
            var ctx = self.context.releaseUnwrap() orelse return;
            self.alloc.free(self.name);
            ctx.deinit();
            self.alloc.destroy(ctx);
        }
    }
};

pub const ParamAst = struct {
    alloc: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    nodes: []Node,

    pub const Node = union(enum) {
        delete: []const u8,
        class: struct {
            name: []const u8,
            extends: ?[]const u8,
            nodes: []const Node,
        },
        parameter: struct {
            name: []const u8,
            op: enum(u8) {
                Assign = 0,
                AddAssign = 1,
                SubAssign = 2, //i forgot numbers for now we go with 0 1 2
            },
            value: ParamValue
        },
        exec: []const u8,
        external: []const u8,
        enumeration: []const struct {
            name: []const u8,
            value: f32,
        }
    };
};


/// Represents a parameter file configuration system for DayZ mod and game configurations
///
/// This implementation provides a robust parsing and management system for the paramfile format used in
/// Bohemia Interactive's game engines.
///
/// Key Features:
/// - Reference counting similar to game internal mechanism but safer
///
/// References:
/// - raP File Format [[1]](https://community.bistudio.com/wiki/raP_File_Format_-_Elite)
/// - CPP File Format [[2]](https://community.bohemia.net/wiki/CPP_File_Format)
///
/// Usage Example:
/// ```
/// // Creating a parameter file for a DayZ mod configuration
/// const param_file = try ParamFile.init(allocator);
/// defer param_file.deinit();
/// ```
const testing = std.testing;
//
// test "ParamFile arena deinitialization doesnt leak" {
//     const allocator = testing.allocator;
//
//     const param_file = try ParamFile.init(allocator);
//     defer param_file.deinit();
//     try testing.expectEqual(param_file.inner.strongCount(), 1);
// }
