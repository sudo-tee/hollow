//! Unopiniated Zig bindings for LuaJIT.
//!
//! This library provides a zero-cost, idiomatic and convenient API to interact
//! with Lua C API using Zig.

const std = @import("std");
const builtin = @import("builtin");

pub const c = @import("./c.zig").c;

const zig0_15 = builtin.zig_version.major == 0 and builtin.zig_version.minor == 15;

/// State defines an ergonomic Zig wrapper around C Lua state.
pub const State = struct {
    const Self = @This();

    /// State status.
    pub const Status = enum(c_int) {
        ok = 0,
        yield = c.LUA_YIELD,
    };

    pub const Options = struct {
        /// Allocator used by Lua runtime. Pointer must outlive state.
        allocator: *std.mem.Allocator = @constCast(&std.heap.c_allocator),
        /// Panic handler used by Lua runtime.
        panicHandler: ?CFunction = luaPanic,
    };

    fn statusFromInt(code: c_int) Status {
        return switch (code) {
            0 => Status.ok,
            c.LUA_YIELD => Status.yield,
            else => unreachable,
        };
    }

    lua: *c.lua_State,

    /// Creates a new main lua state. Allocator is used by Lua runtime so
    /// pointer must outlive lua state.
    pub fn init(options: Options) std.mem.Allocator.Error!Self {
        const lua = c.lua_newstate(
            luaAlloc,
            @ptrCast(@constCast(options.allocator)),
        ) orelse {
            return std.mem.Allocator.Error.OutOfMemory;
        };
        if (options.panicHandler != null) {
            _ = c.lua_atpanic(lua, options.panicHandler);
        }

        return .{ .lua = lua };
    }

    /// Creates a new State wrapping provided C Lua state pointer.
    pub fn initFromCPointer(lua: *c.lua_State) Self {
        return .{ .lua = lua };
    }

    /// Destroys lua state. You must not use state nor data owned by it after
    /// calling this method.
    pub fn deinit(self: Self) void {
        c.lua_close(self.lua);
    }

    /// Creates a new thread, pushes it on the stack, and returns a state
    /// that represents this new thread. The new thread returned by this
    /// function shares with the original thread its global environment, but has
    /// an independent execution stack.
    ///
    /// There is no explicit function to close or to destroy a thread. Threads
    /// are subject to garbage collection, like any Lua object.
    ///
    /// This function doesn't return an `error.OutOfMemory` as lua_newthread
    /// calls panic handler instead of returning null.
    ///
    /// This is the same as lua_newthread.
    pub fn newThread(self: Self) Self {
        // lua_newthread never returns a null pointer.
        return Self.initFromCPointer(c.lua_newthread(self.lua).?);
    }

    /// Returns the index of the top element in the stack. Because indices start
    /// at 1, this result is equal to the number of elements in the stack (and
    /// so 0 means an empty stack).
    ///
    /// This is the same as lua_gettop.
    pub fn top(self: Self) c_int {
        return c.lua_gettop(self.lua);
    }

    /// Accepts any index, or 0, and sets the stack top to this index. If the
    /// new top is larger than the old one, then the new elements are filled
    /// with nil. If index is 0, then all stack elements are removed.
    ///
    /// This is the same as lua_settop.
    pub fn setTop(self: Self, idx: c_int) void {
        c.lua_settop(self.lua, idx);
    }

    /// Removes the element at the given valid index, shifting down the elements
    /// above this index to fill the gap. This function cannot be called with a
    /// pseudo-index, because a pseudo-index is not an actual stack position.
    ///
    /// This is the same as lua_remove.
    pub fn remove(self: Self, idx: c_int) void {
        c.lua_remove(self.lua, idx);
    }

    /// Moves the top element into the given valid index, shifting up the
    /// elements above this index to open space. This function cannot be called
    /// with a pseudo-index, because a pseudo-index is not an actual stack
    /// position.
    ///
    /// This is the same as lua_insert.
    pub fn insert(self: Self, idx: c_int) void {
        c.lua_insert(self.lua, idx);
    }

    /// Moves the top element into the given valid index without shifting any
    /// element (therefore replacing the value at the given index), and then
    /// pops the top element.
    ///
    /// This is the same as lua_replace.
    pub fn replace(self: Self, idx: c_int) void {
        c.lua_replace(self.lua, idx);
    }

    /// Copies the element at index fromIdx into the valid index toIdx,
    /// replacing the value at that position. Values at other positions are not
    /// affected.
    ///
    /// This is the same as lua_copy.
    pub fn copy(self: Self, fromIdx: c_int, toIdx: c_int) void {
        c.lua_copy(self.lua, fromIdx, toIdx);
    }

    /// Ensures that there are at least extra free stack slots in the stack. It
    /// returns false if it cannot fulfill the request, because it would cause
    /// the stack to be larger than a fixed maximum size (typically at least a
    /// few thousand elements) or because it cannot allocate memory for the new
    /// stack size. This function never shrinks the stack; if the stack is
    /// already larger than the new size, it is left unchanged.
    ///
    /// This is the same as lua_checkstack.
    pub fn checkStack(self: Self, sz: c_int) bool {
        return c.lua_checkstack(self.lua, sz) != 0;
    }

    /// Exchange values between different threads of the same state.
    /// This function pops n values from the stack from, and pushes them onto
    /// the stack to.
    ///
    /// This is the same as lua_xmove.
    pub fn xMove(self: Self, to: State, n: c_int) void {
        c.lua_xmove(self.lua, to.lua, n);
    }

    /// Returns the type of the value in the given valid index, or null for
    /// a non-valid (but acceptable) index.
    ///
    /// This is the same as lua_type.
    pub fn valueType(self: Self, idx: c_int) ?ValueType {
        const t = c.lua_type(self.lua, idx);
        if (t == c.LUA_TNONE) return null;

        return @enumFromInt(t);
    }

    /// Returns the name of the type encoded by the value `tp`.
    ///
    /// This is the same as lua_typename.
    pub fn typeName(self: Self, tp: ValueType) [*c]const u8 {
        return c.lua_typename(self.lua, @intFromEnum(tp));
    }

    /// Pushes onto the stack the value of the global `name`.
    ///
    /// This is the same as lua_getglobal.
    pub fn getGlobal(self: Self, name: [*c]const u8) void {
        c.lua_getglobal(self.lua, name);
    }

    /// Pops a value from the stack and sets it as the new value of global `name`.
    ///
    /// This is the same as lua_setglobal.
    pub fn setGlobal(self: Self, name: [*c]const u8) void {
        c.lua_setglobal(self.lua, name);
    }

    /// Returns true if the value at the given acceptable index has type
    /// boolean, and false otherwise.
    ///
    /// This is the same as lua_isboolean.
    pub fn isBoolean(self: Self, idx: c_int) bool {
        return c.lua_isboolean(self.lua, idx);
    }

    /// Returns true if the value at the given acceptable index is a CFunction,
    /// and false otherwise.
    ///
    /// This is the same as lua_iscfunction.
    pub fn isCFunction(self: Self, idx: c_int) bool {
        return c.lua_iscfunction(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a function (
    /// either C or Lua), and false otherwise.
    ///
    /// This is the same as lua_isfunction.
    pub fn isFunction(self: Self, idx: c_int) bool {
        return c.lua_isfunction(self.lua, idx);
    }

    /// Returns true if the value at the given acceptable index is nil, and
    /// false otherwise.
    ///
    /// This is the same as lua_isnil.
    pub fn isNil(self: Self, idx: c_int) bool {
        return c.lua_isnil(self.lua, idx);
    }

    /// Returns true if the given acceptable index is not valid (that is, it
    /// refers to an element outside the current stack), and false otherwise.
    ///
    /// This is the same as lua_isnone.
    pub fn isNone(self: Self, idx: c_int) bool {
        return c.lua_isnone(self.lua, idx);
    }

    /// Returns true if the given acceptable index is not valid (that is, it
    /// refers to an element outside the current stack) or if the value at this
    /// index is nil, and false otherwise.
    ///
    /// This is the same as lua_isnoneornil.
    pub fn isNoneOrNil(self: Self, idx: c_int) bool {
        return c.lua_isnoneornil(self.lua, idx);
    }

    /// Returns true if the value at the given acceptable index is a number or a
    /// string convertible to a number, and false otherwise.
    ///
    /// This is the same as lua_isnumber.
    pub fn isNumber(self: Self, idx: c_int) bool {
        return c.lua_isnumber(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a string or a
    /// number (which is always convertible to a string), and false otherwise.
    ///
    /// This is the same as lua_isstring.
    pub fn isString(self: Self, idx: c_int) bool {
        return c.lua_isstring(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a table, and
    /// false otherwise.
    ///
    /// This is the same as lua_istable.
    pub fn isTable(self: Self, idx: c_int) bool {
        return c.lua_istable(self.lua, idx);
    }

    /// Returns true if the value at the given acceptable index is a thread, and
    /// false otherwise.
    ///
    /// This is the same as lua_isthread.
    pub fn isThread(self: Self, idx: c_int) bool {
        return c.lua_isthread(self.lua, idx);
    }

    /// Returns true if the value at the given acceptable index is a userdata
    /// (either full or light), and false otherwise.
    ///
    /// This is the same as lua_isuserdata.
    pub fn isUserData(self: Self, idx: c_int) bool {
        return c.lua_isuserdata(self.lua, idx) != 0;
    }

    /// Returns true if the value at the given acceptable index is a light
    /// userdata, and false otherwise.
    ///
    /// This is the same as lua_islightuserdata.
    pub fn isLightUserData(self: Self, idx: c_int) bool {
        return c.lua_islightuserdata(self.lua, idx);
    }

    /// This function works like State.checkUserDataWithName, except that,
    /// when the test fails, it returns NULL instead of throwing an error.
    ///
    /// This is the same as luaL_testudata.
    pub fn testUserDataWithName(
        self: Self,
        idx: c_int,
        tname: [*:0]const u8,
        comptime T: type,
    ) ?*T {
        return @ptrCast(@alignCast(c.luaL_testudata(self.lua, idx, tname)));
    }

    /// This function works like State.checkUserData, except that,
    /// when the test fails, it returns NULL instead of throwing an error.
    ///
    /// This is similar to luaL_testudata.
    pub fn testUserData(self: Self, idx: c_int, comptime T: type) ?*T {
        return self.testUserDataWithName(idx, tName(T), T);
    }

    /// Returns true if the two values in acceptable indices `index1` and
    /// `index2` are equal, following the semantics of the Lua == operator
    /// (that is, may call metamethods). Otherwise returns false. Also returns
    /// false if any of the indices is non valid.
    ///
    /// This is the same as lua_equal.
    pub fn equal(self: Self, index1: c_int, index2: c_int) bool {
        return c.lua_equal(self.lua, index1, index2) != 0;
    }

    /// Returns true if the two values in acceptable indices `index1` and
    /// `index2` are primitively equal (that is, without calling metamethods).
    /// Otherwise returns false. Also returns false if any of the indices are
    /// non valid.
    ///
    /// This is the same as lua_rawequal.
    pub fn rawEqual(self: Self, index1: c_int, index2: c_int) bool {
        return c.lua_rawequal(self.lua, index1, index2) != 0;
    }

    /// Returns true if the value at acceptable index `index1` is smaller than
    /// the value at acceptable index `index2`, following the semantics of the
    /// Lua < operator (that is, may call metamethods). Otherwise returns false.
    /// Also returns false if any of the indices is non valid.
    ///
    /// This is the same as lua_lessthan.
    pub fn lessThan(self: Self, index1: c_int, index2: c_int) bool {
        return c.lua_lessthan(self.lua, index1, index2) != 0;
    }

    /// Converts the Lua value at the given acceptable index to the C type
    /// lua_Number (see lua_Number). The Lua value must be a number or a string
    /// convertible to a number; otherwise, lua_tonumber returns 0.
    ///
    /// This is the same as lua_tonumber.
    pub fn toNumber(self: Self, idx: c_int) Number {
        return c.lua_tonumber(self.lua, idx);
    }

    /// Converts the Lua value at the given acceptable index to the signed
    /// integral type lua_Integer. The Lua value must be a number or a string
    /// convertible to a number; otherwise, lua_tointeger returns 0.
    /// If the number is not an integer, it is truncated in some non-specified way.
    ///
    /// This is the same as lua_tointeger.
    pub fn toInteger(self: Self, idx: c_int) Integer {
        return c.lua_tointeger(self.lua, idx);
    }

    /// Converts the Lua value at the given acceptable index to a boolean
    /// value. Like all tests in Lua, toBoolean returns true for any Lua value
    /// different from false and nil; otherwise it returns 0. It also returns
    /// false when called with a non-valid index. (If you want to accept only
    /// actual boolean values, use isBoolean to test the value's type.)
    ///
    /// This is the same as lua_toboolean.
    pub fn toBoolean(self: Self, idx: c_int) bool {
        return c.lua_toboolean(self.lua, idx) != 0;
    }

    /// Converts the Lua value at the given acceptable index to a []const u8.
    /// The Lua value must be a string or a number; otherwise, the function
    /// returns null. If the value is a number, then toString also changes the
    /// actual value in the stack to a string. (This change confuses
    /// State.next when toString is applied to keys during a table
    /// traversal.)
    ///
    /// toString returns a fully aligned pointer to a string inside the Lua
    /// state. This string always has a zero ('\0') after its last character
    /// (as in C), but can contain other zeros in its body. Because Lua has
    /// garbage collection, there is no guarantee that the pointer returned by
    /// toString will be valid after the corresponding value is removed from the
    /// stack.
    ///
    /// This is the same as lua_tolstring.
    pub fn toString(self: Self, idx: c_int) ?[]const u8 {
        var len: usize = 0;
        const str = c.lua_tolstring(self.lua, idx, &len) orelse return null;
        return str[0..len];
    }

    /// Converts a value at the given acceptable index to a CFunction. That
    /// value must be a CFunction; otherwise, returns null.
    ///
    /// This is the same as lua_tocfunction.
    pub fn toCFunction(self: Self, idx: c_int) ?CFunction {
        return c.lua_tocfunction(self.lua, idx);
    }

    /// Converts the value at the given acceptable index to a generic opaque
    /// pointer. The value can be a userdata, a table, a thread, or a function;
    /// otherwise, lua_topointer returns NULL. Different objects will give
    /// different pointers. There is no way to convert the pointer back to its
    /// original value.
    ///
    /// Typically this function is used only for debug information.
    ///
    /// This is the same as lua_topointer.
    pub fn toPointer(self: Self, idx: c_int) ?*const anyopaque {
        return c.lua_topointer(self.lua, idx);
    }

    /// Converts the value at the given acceptable index to a Lua state.
    /// This value must be a thread; otherwise, the function returns null.
    ///
    /// This is the same as lua_tothread.
    pub fn toState(self: Self, idx: c_int) ?State {
        const lua = c.lua_tothread(self.lua, idx) orelse return null;
        return State.initFromCPointer(lua);
    }

    /// If the value at the given acceptable index is a full userdata, returns
    /// its block address. If the value is a light userdata, returns its
    /// pointer. Otherwise, returns null.
    ///
    /// This is the same as lua_touserdata.
    pub fn toUserData(self: Self, idx: c_int, comptime T: type) ?*T {
        return @ptrCast(@alignCast(c.lua_touserdata(self.lua, idx)));
    }

    /// If the value at the given acceptable index is a cdata, returns its
    /// address.
    pub fn toCData(self: Self, idx: c_int) CData {
        return @as(*CData, @ptrCast(
            @alignCast(@constCast(self.toPointer(idx) orelse return null)),
        )).*;
    }

    /// Returns the "length" of the value at the given acceptable index: for
    /// strings, this is the string length; for tables, this is the result of
    /// the length operator ('#'); for userdata, this is the size of the block
    /// of memory allocated for the userdata; for other values, it is false.
    ///
    /// This is the same as lua_objlen.
    pub fn objLen(self: Self, idx: c_int) usize {
        return c.lua_objlen(self.lua, idx);
    }

    /// This is the same as State.objLen.
    pub fn strLen(self: Self, idx: c_int) usize {
        return c.lua_strlen(self.lua, idx);
    }

    /// Gets a value of type T at position `idx` from Lua stack without popping
    /// it. Values on the stack may be converted to type T (e.g. "1" becomes 1
    /// if T is f64).
    ///
    /// Type mapping between Zig and Lua:
    /// - bool            <- bool
    /// - CFunction       <- a native C function
    /// - f32, f64        <- number, coercible strings
    /// - Integer         <- number, coercible strings
    /// - c_int           <- number, coercible strings
    /// - int             <- number, coercible strings
    /// - []const u8      <- string, number
    /// - TableRef        <- table
    /// - ValueRef        <- any Lua type
    /// - *c.lua_State    <- thread / coroutine
    /// - *anyopaque      <- lightuserdata
    /// - State           <- thread / coroutine
    /// - Value           <- any Lua type
    ///
    /// Special cases:
    /// - [*c]T           <- C Data
    /// - *T              <- userdata of type T
    /// - enum            <- string containing @tagName(t)
    pub fn toAnyType(self: Self, idx: c_int, comptime T: type) ?T {
        return switch (T) {
            bool => self.toBoolean(idx),
            FunctionRef => FunctionRef.init(ValueRef.init(self, idx)),
            f32, f64 => @floatCast(self.toNumber(idx)),
            Integer => self.toInteger(idx),
            []const u8 => self.toString(idx),
            TableRef => {
                const vref = ValueRef.init(self, idx);
                if (vref.valueType() != .table) {
                    return null;
                }
                return TableRef.init(vref);
            },
            *c.lua_State => c.lua_tothread(self.lua, idx),
            CData => self.toCData(idx),
            State => self.toState(idx),
            Value => {
                return switch (self.valueType(idx) orelse return null) {
                    .thread => .{
                        .thread = self.toAnyType(idx, State).?,
                    },
                    .boolean => .{ .boolean = self.toAnyType(idx, bool).? },
                    .nil => .nil,
                    .proto => .proto,
                    .string => .{ .string = self.toAnyType(idx, []const u8).? },
                    .number => .{ .number = self.toAnyType(idx, f64).? },
                    .function => .{
                        .function = self.toAnyType(idx, FunctionRef).?,
                    },
                    .table => .{ .table = self.toAnyType(idx, TableRef).? },
                    .userdata => .{
                        .userdata = self.toAnyType(idx, *anyopaque).?,
                    },
                    .lightuserdata => .{
                        .lightuserdata = self.toAnyType(idx, *anyopaque).?,
                    },
                    .cdata => .{
                        .cdata = self.toAnyType(idx, CData) orelse null,
                    },
                };
            },
            ValueRef => ValueRef.init(self, idx),
            else => {
                switch (@typeInfo(T)) {
                    .pointer => |info| switch (info.size) {
                        .one => return self.toUserData(idx, info.child),
                        .c => return @as(*T, @ptrCast(
                            @constCast(self.toPointer(idx) orelse return null),
                        )).*,
                        else => @compileError("pointer type of size " ++ @tagName(info.size) ++ " is not supported (" ++ @typeName(T) ++ ")"),
                    },
                    .@"enum" => |info| {
                        if (self.valueType(idx) != .string) return null;
                        const str = self.toString(idx);
                        inline for (info.fields) |f| {
                            if (std.mem.eql(u8, str, f.name)) {
                                return @enumFromInt(f.value);
                            }
                        }
                        return null;
                    },
                    .int => return @intCast(self.toInteger(idx)),
                    else => @compileError("can't get value of type " ++ @typeName(T) ++ " from Lua stack"),
                }
            },
        };
    }

    /// Pops `n` elements from the stack.
    ///
    /// This is the same as lua_pop.
    pub fn pop(self: Self, n: c_int) void {
        c.lua_pop(self.lua, n);
    }

    /// Pops a value of type T from top of Lua stack. If returned value is null
    /// nothing was popped from the stack.
    ///
    /// Type mapping between Zig and Lua:
    /// - bool            <- bool
    /// - CFunction       <- a native C function
    /// - f32, f64        <- number, coercible strings
    /// - Integer         <- number, coercible strings
    /// - c_int           <- number, coercible strings
    /// - int             <- number, coercible strings
    /// - []const u8      <- string, number
    /// - TableRef        <- table
    /// - ValueRef        <- any Lua type
    /// - *c.lua_State    <- thread / coroutine
    /// - *anyopaque      <- lightuserdata
    /// - State           <- thread / coroutine
    /// - Value           <- any Lua type
    ///
    /// Special cases:
    /// - *T              <- userdata of type T
    /// - enum            <- string containing @tagName(t)
    pub fn popAnyType(self: Self, comptime T: type) ?T {
        if (T == ValueRef or T == FunctionRef or T == TableRef) {
            @compileError("can't pop stack reference from lua stack");
        }

        const v = self.toAnyType(-1, T);
        if (v != null)
            self.pop(1);
        return v;
    }

    /// Find or create a module table with a given name. The function first
    /// looks at the LOADED table and, if that fails, try a global variable with
    /// that name. In any case, leaves on the stack the module table.
    ///
    /// This is the same as luaL_pushmodule.
    pub fn pushModule(self: Self, name: [*c]const u8, sizeHint: c_int) void {
        c.luaL_pushmodule(self.lua, name, sizeHint);
    }

    /// Pushes a boolean value with value b onto the stack.
    ///
    /// This is the same as lua_pushbool.
    pub fn pushBool(self: Self, b: bool) void {
        c.lua_pushboolean(self.lua, @intFromBool(b));
    }

    /// Pushes a copy of the element at the given index onto the stack.
    ///
    /// This is the same as lua_pushvalue.
    pub fn pushValue(self: Self, idx: c_int) void {
        c.lua_pushvalue(self.lua, idx);
    }

    /// Pushes a nil value onto the stack.
    ///
    /// This is the same as lua_pushnil.
    pub fn pushNil(self: Self) void {
        c.lua_pushnil(self.lua);
    }

    /// Pushes a number with value `n` onto the stack.
    ///
    /// This is the same as lua_pushnumber.
    pub fn pushNumber(self: Self, n: Number) void {
        c.lua_pushnumber(self.lua, n);
    }

    /// Pushes a number with value `n` onto the stack.
    ///
    /// This is the same as lua_pushinteger.
    pub fn pushInteger(self: Self, n: Integer) void {
        c.lua_pushinteger(self.lua, n);
    }

    /// Pushes the string pointed to by `s` with size len onto the stack. Lua
    /// makes (or reuses) an internal copy of the given string, so the memory at
    /// `s` can be freed or reused immediately after the function returns. The
    /// string can contain embedded zeros.
    ///
    /// This is the same as lua_pushlstring.
    pub fn pushString(self: Self, s: []const u8) void {
        c.lua_pushlstring(self.lua, s.ptr, s.len);
    }

    /// Pushes the zero-terminated string pointed to by `s` onto the stack. Lua
    /// makes (or reuses) an internal copy of the given string, so the memory at
    /// `s` can be freed or reused immediately after the function returns. The
    /// string cannot contain embedded zeros; It is assumed to end at the first
    /// zero.
    ///
    /// This is the same as lua_pushstring.
    pub fn pushCString(self: Self, s: [*c]const u8) void {
        c.lua_pushstring(self.lua, s);
    }

    /// Pushes a new C closure onto the stack.
    ///
    /// When a CFunction is created, it is possible to associate some values
    /// with it, thus creating a C closure; these values are then accessible to
    /// the function whenever it is called. To associate values with a
    /// CFunction, first these values should be pushed onto the stack
    /// (when there are multiple values, the first value is pushed first). Then
    /// State.pushCClosure is called to create and push the CFunction onto
    /// the stack, with the argument `n` telling how many values should be
    /// associated with the function. State.pushCClosure also pops these values
    /// from the stack.
    ///
    /// This is the same as lua_pushcclosure.
    pub fn pushCClosure(self: Self, cfn: CFunction, n: c_int) void {
        c.lua_pushcclosure(self.lua, cfn, n);
    }

    /// Pushes a CFunction onto the stack.
    ///
    /// This function receives a pointer to a CFunction and pushes onto the
    /// stack a Lua value of type function that, when called, invokes the
    /// corresponding CFunction.
    ///
    /// Any function to be registered in Lua must follow the correct protocol to
    /// receive its parameters and return its results (see CFunction).
    ///
    /// This is the same as lua_pushcfunction.
    pub fn pushCFunction(self: Self, cfn: CFunction) void {
        c.lua_pushcfunction(self.lua, cfn);
    }

    /// Pushes a Zig function onto the stack.
    ///
    /// This function receives a pointer to a State and pushes onto the
    /// stack a Lua value of type function that, when called, invokes the
    /// corresponding Zig function.
    ///
    /// Any function to be registered in Lua must follow the correct protocol to
    /// receive its parameters and return its results (see CFunction).
    ///
    /// This is similar to lua_pushcfunction.
    pub fn pushZFunction(self: Self, zfn: anytype) void {
        self.pushCFunction(wrapFn(zfn));
    }

    /// Pushes a light userdata onto the stack.
    ///
    /// Userdata represent C values in Lua. A light userdata represents a
    /// pointer. It is a value (like a number): you do not create it, it has no
    /// individual metatable, and it is not collected (as it was never created).
    /// A light userdata is equal to "any" light userdata with the same C address.
    ///
    /// This is the same as lua_pushlightuserdata
    pub fn pushLightUserData(self: Self, p: *anyopaque) void {
        c.lua_pushlightuserdata(self.lua, p);
    }

    /// Pushes the thread represented by self onto the stack. Returns true if this
    /// thread is the main thread of its state.
    ///
    /// This is the same as lua_pushthread.
    pub fn pushState(self: Self) bool {
        return c.lua_pushthread(self.lua) != 0;
    }

    /// Pushes value `v` onto Lua stack.
    /// This functions uses appropriate push function at comptime based on type
    /// of `v`.
    ///
    /// Type mapping between Zig and Lua:
    /// - bool            -> bool
    /// - CFunction       -> function
    /// - *anyopaque      -> light userdata
    /// - f32, f64        -> number
    /// - Integer, iN, uN -> number
    /// - []const u8      -> string
    /// - ValueRef        -> copy of referenced value
    /// - TableRef        -> same as ValueRef
    /// - FunctionRef     -> same as ValueRef
    /// - *c.lua_State    -> thread
    /// - State           -> thread
    /// - Value           -> depends on Value variant
    ///
    /// Special cases:
    /// - *T              -> pushAnyType(v.*) so *bool is pushed as a boolean
    /// - ?T              -> nil if T is null and T otherwise
    /// - enum T          -> @tagName(t) as a string
    /// - fn              -> converts fn to CFunction using wrapFn()
    ///
    /// There is no way to push a new userdata using this function because
    /// userdata are subject to garbage collection so they must be allocated by
    /// Lua. See State.newUserData.
    pub fn pushAnyType(self: Self, v: anytype) void {
        self.pushT(@TypeOf(v), v);
    }

    /// Pushes a value of type T on Lua stack using comptime reflection.
    fn pushT(self: Self, comptime T: type, v: T) void {
        if ((T == ValueType or T == Value) and v == .nil) {
            return self.pushNil();
        }

        switch (T) {
            bool => return c.lua_pushboolean(self.lua, @intFromBool(v)),
            CFunction => return self.pushCFunction(v),
            *anyopaque => return self.pushLightUserData(v),
            f32, f64 => return self.pushNumber(v),
            Integer => return self.pushInteger(v),
            [*c]const u8 => return self.pushCString(v),
            []const u8, [:0]const u8 => return self.pushString(v),
            TableRef, FunctionRef => return self.pushAnyType(v.ref),
            ValueRef => return self.pushValue(v.idx),
            *c.lua_State => return self.pushAnyType(State.initFromCPointer(v)),
            State => {
                _ = v.pushState();
                if (v.lua != self.lua) v.xMove(self, 1);
                return;
            },
            Value => return switch (v) {
                .boolean => self.pushAnyType(v.boolean),
                .function => self.pushAnyType(v.function),
                .lightuserdata => self.pushAnyType(v.lightuserdata),
                .nil => self.pushNil(),
                .proto, .cdata => @panic(
                    "can't push proto / cdata on Lua stack",
                ),
                .number => self.pushAnyType(v.number),
                .string => self.pushAnyType(v.string),
                .table => self.pushAnyType(v.table),
                .thread => self.pushAnyType(v.thread),
                .userdata => self.pushAnyType(v.userdata),
            },
            else => {
                switch (@typeInfo(T)) {
                    .pointer => |info| {
                        return switch (info.size) {
                            .one => return self.pushT(info.child, v.*),
                            else => @compileError(
                                "pointer type of size " ++
                                    @tagName(info.size) ++
                                    " is not supported (" ++
                                    @typeName(T) ++
                                    ")",
                            ),
                        };
                    },
                    .array => |info| {
                        if (info.child == u8) {
                            return self.pushString(v[0..]);
                        }
                    },
                    .optional => |info| {
                        if (v == null) {
                            c.lua_pushnil(self.lua);
                            return;
                        } else {
                            self.pushT(info.child, v.?);
                            return;
                        }
                    },
                    .@"enum" => return self.pushString(@tagName(v)),
                    .int => return self.pushInteger(@intCast(v)),
                    .@"fn" => return self.pushZFunction(v),
                    else => {},
                }
            },
        }

        @compileError("can't push value of type " ++ @typeName(T) ++ " on Lua stack");
    }

    /// Checks whether the function has an argument of any type (including nil)
    /// at position `narg`.
    ///
    /// This is the same as luaL_checkany.
    pub fn checkAny(self: Self, narg: c_int) void {
        return c.luaL_checkany(self.lua, narg);
    }

    /// Checks whether the function argument `narg` is a number and returns this
    /// number cast to a c_int.
    ///
    /// This is the same as luaL_checkint.
    pub fn checkInt(self: Self, narg: c_int) c_int {
        return c.luaL_checkint(self.lua, narg);
    }

    /// Checks whether the function argument `narg` is a number and returns this
    /// number cast to an Integer.
    ///
    /// This is the same as luaL_checkinteger.
    pub fn checkInteger(self: Self, narg: c_int) Integer {
        return c.luaL_checkinteger(self.lua, narg);
    }

    /// Checks whether the function argument `narg` is a number and returns this
    /// number cast to a c_long.
    ///
    /// This is the same as luaL_checklong.
    pub fn checkLong(self: Self, narg: c_int) c_long {
        return c.luaL_checklong(self.lua, narg);
    }

    /// Checks whether the function argument `narg` is a string and returns this
    /// string
    /// This function uses State.toString to get its result, so all conversions
    /// and caveats of that function apply here.
    ///
    /// This is the same as luaL_checkstring.
    pub fn checkString(self: Self, narg: c_int) []const u8 {
        var len: usize = 0;
        const str = c.luaL_checklstring(self.lua, narg, &len).?;
        return str[0..len];
    }

    /// Checks whether the function argument `narg` has type `vtype`.
    ///
    /// This is the same as luaL_checktype.
    pub fn checkValueType(self: Self, narg: c_int, vtype: ValueType) void {
        return c.luaL_checktype(self.lua, narg, @intFromEnum(vtype));
    }

    /// Checks whether the function argument `narg` is a number and returns this
    /// number.
    ///
    /// This is the same as luaL_checknumber.
    pub fn checkNumber(self: Self, narg: c_int) Number {
        return c.luaL_checknumber(self.lua, narg);
    }

    /// Checks whether the function argument `narg` is a string and searches for
    /// this string in the possible variants of enum T. Returns the variant with
    /// name matching the string. Raises an error if the argument is not a
    /// string or if the string cannot be found.
    ///
    /// If def is not null, the function uses def as a default value when there
    /// is no argument narg or if this argument is nil.
    ///
    /// This is a useful function for mapping strings to enums. (The usual
    /// convention in Lua libraries is to use strings instead of numbers to
    /// select options.)
    ///
    /// This is the same as luaL_checkoption.
    pub fn checkOption(
        self: Self,
        narg: c_int,
        def: [*c]const u8,
        lst: [*c]const [*c]const u8,
    ) c_int {
        return c.luaL_checkoption(self.lua, narg, def, lst);
    }

    /// Checks whether the function argument `narg` is a string and searches for
    /// this string in the possible variants of enum T. Returns the variant with
    /// name matching the string. Raises an error if the argument is not a
    /// string or if the string cannot be found.
    ///
    /// If def is not null, the function uses def as a default value when there
    /// is no argument narg or if this argument is nil.
    ///
    /// This is a useful function for mapping strings to Zig enums. (The usual
    /// convention in Lua libraries is to use strings instead of numbers to
    /// select options.)
    ///
    /// This is similar to luaL_checkoption.
    pub fn checkEnum(
        self: Self,
        narg: c_int,
        comptime T: type,
        def: ?T,
    ) T {
        const info = @typeInfo(T).@"enum";

        var enum_values: [info.fields.len:0]usize = undefined;
        var lst: [info.fields.len:0][*c]const u8 = undefined;
        inline for (&lst, &enum_values, info.fields) |*l, *v, f| {
            l.* = f.name;
            v.* = f.value;
        }

        const idx = self.checkOption(
            narg,
            if (def != null) @tagName(def.?) else null,
            lst[0..],
        );

        return @enumFromInt(enum_values[@as(usize, @intCast(idx))]);
    }

    /// Checks whether the function argument narg is a userdata of the type
    /// `tname` (see State.newMetaTable).
    ///
    /// See State.checkUserData for a more Zig friendly version.
    ///
    /// This is the same as luaL_checkudata.
    pub fn checkUserDataWithName(
        self: Self,
        narg: c_int,
        tname: [*:0]const u8,
        comptime T: type,
    ) *T {
        return @ptrCast(@alignCast(c.luaL_checkudata(self.lua, narg, tname).?));
    }

    /// Checks whether the function argument narg is a userdata of type T
    /// (see State.newMetaTable).
    ///
    /// This is similar to luaL_checkudata.
    pub fn checkUserData(
        self: Self,
        narg: c_int,
        comptime T: type,
    ) *T {
        return self.checkUserDataWithName(narg, tName(T), T);
    }

    /// Checks whether the function argument narg is a cdata.
    pub fn checkCData(self: Self, narg: c_int) CData {
        self.checkValueType(narg, .cdata);
        return self.toCData(narg);
    }

    /// Checks whether the argument `narg` is of type T or coercible and returns
    /// it.
    ///
    /// Type mapping between Zig and Lua:
    /// - bool            <- bool
    /// - CFunction       <- a native C function
    /// - f32, f64        <- number, coercible strings
    /// - Integer         <- number, coercible strings
    /// - c_int           <- number, coercible strings
    /// - int             <- number, coercible strings
    /// - []const u8      <- string, number
    /// - TableRef        <- table
    /// - ValueRef        <- any Lua type
    /// - *c.lua_State    <- thread / coroutine
    /// - *anyopaque      <- lightuserdata
    /// - State           <- thread / coroutine
    /// - Value           <- any Lua type
    ///
    /// Special cases:
    /// - [*c]T           <- C Data
    /// - *T              <- userdata of type T
    /// - enum            <- string containing @tagName(t)
    /// - ?T              <- nil if T is null and T otherwise
    pub fn checkAnyType(self: Self, narg: c_int, comptime T: type) T {
        switch (T) {
            bool => {
                if (!self.isBoolean(narg)) self.typeError(narg, "boolean");
                return self.toAnyType(narg, bool).?;
            },
            CData => self.checkCData(narg),
            CFunction => {
                self.isCFunction(narg) or self.argError(
                    narg,
                    "native C function expected",
                );
                return self.toCFunction(narg).?;
            },
            f32, f64 => return @floatCast(self.checkNumber(narg)),
            Integer => return self.checkInteger(narg),
            c_int => return self.checkInt(narg),
            []const u8 => return self.checkString(narg),
            TableRef => {
                self.checkValueType(narg, .table);
                return self.toAnyType(narg, TableRef).?;
            },
            ValueRef => {
                self.checkAny(narg);
                return self.toAnyType(narg, ValueRef).?;
            },
            *c.lua_State => {
                self.checkValueType(narg, .thread);
                return self.toState(narg).?.lua;
            },
            *anyopaque => {
                self.checkValueType(narg, .lightuserdata);
                return self.toAnyType(narg, T).?;
            },
            State => {
                self.checkValueType(narg, .thread);
                return self.toState(narg).?;
            },
            Value => {
                self.checkAny(narg);
                return self.toAnyType(narg, Value);
            },
            else => {
                switch (@typeInfo(T)) {
                    .pointer => |info| {
                        return switch (info.size) {
                            .one => return self.checkUserData(narg, info.child),
                            .c => {
                                self.checkValueType(narg, .cdata);
                                return self.toAnyType(narg, T) orelse null;
                            },
                            else => @compileError("pointer type of size " ++ @tagName(info.size) ++ " is not supported (" ++ @typeName(T) ++ ")"),
                        };
                    },
                    .@"enum" => return self.checkEnum(narg, T, null),
                    .optional => |info| {
                        if (self.isNoneOrNil(narg)) {
                            return null;
                        }
                        return self.checkAnyType(narg, info.child);
                    },
                    .int => return @intCast(self.checkInteger(narg)),
                    else => {},
                }
            },
        }

        @compileError("can't check value of type " ++ @typeName(T) ++ " on Lua stack");
    }

    /// If the function argument arg is an integer (or convertible to an
    /// integer), returns this integer. If this argument is absent or is nil,
    /// returns `def`. Otherwise, raises an error.
    ///
    /// This is the same as luaL_optinteger.
    pub fn optInteger(self: Self, arg: c_int, def: Integer) Integer {
        return c.luaL_optinteger(self.lua, arg, def);
    }

    /// If the function argument arg is a string, returns this string. If this
    /// argument is absent or is nil, returns `def`. Otherwise, raises an error.
    ///
    /// This function uses State.toString to get its result, so all
    /// conversions and caveats of that function apply here.
    ///
    /// This is the same as luaL_optlstring.
    pub fn optString(self: Self, arg: c_int, def: [*c]const u8) []const u8 {
        var len: usize = 0;
        const str = c.luaL_optlstring(self.lua, arg, def, &len).?;
        return str[0..len];
    }

    /// If the function argument arg is a number, returns this number. If this
    /// argument is absent or is nil, returns `def`. Otherwise, raises an error.
    ///
    /// This is the same as luaL_optnumber.
    pub fn optNumber(self: Self, arg: c_int, def: Number) Number {
        c.luaL_optnumber(self.lua, arg, def);
    }

    /// Generates an error with a message like the following:
    /// ```
    ///     location: bad argument narg to 'func' (tname expected, got rt)
    /// ```
    /// where location is produced by State.where, func is the name of the
    /// current function, and `rt` is the type name of the actual argument.
    pub fn typeError(self: Self, narg: c_int, tname: [*c]const u8) noreturn {
        _ = c.luaL_typerror(self.lua, narg, tname);
        unreachable;
    }

    /// Raises an error with the following message, where func is retrieved from
    /// the call stack:
    /// ```
    ///     bad argument #<narg> to <func> (<extramsg>)
    /// ```
    ///
    /// This is the same as luaL_argerror.
    pub fn argError(self: Self, narg: c_int, extramsg: [*c]const u8) noreturn {
        _ = c.luaL_argerror(self.lua, narg, extramsg);
        unreachable;
    }

    /// Dumps Lua stack using std.debug.print.
    pub fn dumpStack(self: Self) void {
        var map = std.AutoHashMap(usize, void).init(std.heap.c_allocator);
        defer map.deinit();

        map.put(@intFromPtr(self.lua), {}) catch @panic("OOM");
        self.dumpNestedStack(&map, 0);
    }

    fn dumpNestedStack(self: Self, visited: *std.AutoHashMap(usize, void), depth: usize) void {
        const print = std.debug.print;

        // Padding.
        for (0..depth) |_| print("  ", .{});
        print("lua stack size {}\n", .{self.top()});
        for (1..@as(usize, @intCast(self.top())) + 1) |i| {
            for (0..depth) |_| print("  ", .{});
            print("  [{d}] ", .{i});
            self.dumpNestedValue(@intCast(i), visited, depth + 1);
            print("\n", .{});
        }
    }

    /// Recursively dumps value on Lua stack at index `t` using std.debug.print.
    pub fn dumpValue(self: Self, idx: c_int) void {
        var map = std.AutoHashMap(usize, void).init(std.heap.c_allocator);
        defer map.deinit();
        self.dumpNestedValue(idx, &map, 0);
    }

    fn dumpNestedValue(self: Self, i: c_int, visited: *std.AutoHashMap(usize, void), depth: usize) void {
        const print = std.debug.print;

        var idx = i;
        if (idx < 0 and idx > Registry) idx = self.top() + idx + 1;

        const val = self.toAnyType(idx, Value);
        if (val == null) {
            print("null", .{});
            return;
        }

        var ptr: usize = 0;
        if (self.toPointer(idx)) |p| ptr = @intFromPtr(p);

        switch (val.?) {
            .boolean => |v| print("{}", .{v}),
            .function => print("function@{x}", .{ptr}),
            .lightuserdata => print("lightuserdata@{x}", .{ptr}),
            .nil => print("nil", .{}),
            .number => |n| print("{d}", .{n}),
            .string => |s| print("'{s}'", .{s}),
            .table => {
                if (visited.get(ptr)) |_| {
                    print("table@{x}", .{ptr});
                    return;
                }

                visited.put(ptr, {}) catch @panic("OOM");

                _ = self.checkStack(2);
                print("table@{x} {s}\n", .{ ptr, "{" });
                self.pushNil(); // first key
                while (self.next(idx)) {
                    // Padding.
                    for (0..depth + 1) |_| print("  ", .{});

                    // Key.
                    {
                        if (self.valueType(-2) != .string) print("[", .{});
                        self.dumpNestedValue(-2, visited, depth + 1);
                        if (self.valueType(-2) != .string) print("]", .{});
                    }

                    print(" = ", .{});

                    // Value.
                    self.dumpNestedValue(-1, visited, depth + 1);

                    print(",\n", .{});

                    // removes 'value'; keeps 'key' for next iteration
                    self.pop(1);
                }

                // Padding.
                for (0..depth) |_| print("  ", .{});
                print("{s}", .{"}"});
            },
            .thread => |thread| {
                if (visited.get(ptr)) |_| {
                    if (ptr == @intFromPtr(self.lua)) {
                        print("thread@{x} (current)", .{ptr});
                    } else print("thread@{x}", .{ptr});
                    return;
                }

                visited.put(ptr, {}) catch @panic("OOM");

                print("thread@{x}\n", .{ptr});
                thread.dumpNestedStack(visited, depth + 1);
            },
            .userdata => print("userdata@{x}", .{ptr}),
            .proto => print("proto", .{}),
            .cdata => print("cdata@{x}", .{
                @intFromPtr(@as(**anyopaque, @ptrFromInt(ptr)).*),
            }),
        }
    }

    /// Pushes onto the stack a string identifying the current position of the
    /// control at level lvl in the call stack. Typically this string has the
    /// following format:
    /// ```
    ///     chunkname:currentline:
    /// ```
    ///
    /// Level 0 is the running function, level 1 is the function that called the
    /// running function, etc.
    ///
    /// This function is used to build a prefix for error messages.
    ///
    /// This is the same as luaL_where.
    pub fn where(self: Self, lvl: c_int) void {
        c.luaL_where(self.lua, lvl);
    }

    /// Returns true if is is the main state and false otherwise.
    pub fn isMain(self: Self) bool {
        const main = c.lua_pushthread(self.lua) == 1;
        c.lua_pop(self.lua, 1);
        return main;
    }

    /// Pushes onto the stack the value `t[k]`, where t is the value at the given
    /// valid index and k is the value at the top of the stack.
    /// This function pops the key from the stack (putting the resulting value
    /// in its place). As in Lua, this function may trigger a metamethod for
    /// the "index" event.
    ///
    /// This is the same as lua_gettable.
    pub fn getTable(self: Self, index: c_int) void {
        c.lua_gettable(self.lua, index);
    }

    /// Pushes onto the stack the value `t[k]`, where t is the value at the given
    /// valid index. As in Lua, this function may trigger a metamethod for the
    /// "index" event.
    ///
    /// This is the same as lua_getfield.
    pub fn getField(self: Self, index: c_int, k: [*c]const u8) void {
        c.lua_getfield(self.lua, index, k);
    }

    /// Similar to lua_gettable, but does a raw access (i.e., without
    /// metamethods).
    ///
    /// This is the same as lua_rawget.
    pub fn rawGet(self: Self, index: c_int) void {
        c.lua_rawget(self.lua, index);
    }

    /// Pushes onto the stack the value `t[n]`, where t is the value at the given
    /// valid index. The access is raw; that is, it does not invoke metamethods.
    ///
    /// This is the same as lua_rawgeti.
    pub fn rawGeti(self: Self, index: c_int, n: c_int) void {
        c.lua_rawgeti(self.lua, index, n);
    }

    /// Creates a new empty table and pushes it onto the stack. The new table
    /// has space pre-allocated for narr array elements and nrec non-array
    /// elements. This pre-allocation is useful when you know exactly how many
    /// elements the table will have. Otherwise you can use the function
    /// lua_newtable.
    ///
    /// This is the same as lua_createtable.
    pub fn createTable(self: Self, narr: c_int, nrec: c_int) void {
        c.lua_createtable(self.lua, narr, nrec);
    }

    /// Creates a new empty table and pushes it onto the stack. It is equivalent
    /// to State.createTable(0, 0).
    ///
    /// This is the same as lua_newtable.
    pub fn newTable(self: Self) void {
        c.lua_newtable(self.lua);
    }

    /// Creates a new empty table, pushes it onto the stack and return a
    /// TableRef.
    ///
    /// This is similar to lua_newtable.
    pub fn newTableRef(self: Self) TableRef {
        self.newTable();
        return TableRef.init(ValueRef.init(self, -1));
    }

    /// This function allocates a new block of memory for type T, pushes onto
    /// the stack a new full userdata with the block address, and returns this
    /// address.
    ///
    /// Userdata represent C values in Lua. A full userdata represents a block
    /// of memory. It is an object (like a table): you must create it, it can
    /// have its own metatable, and you can detect when it is being collected.
    /// A full userdata is only equal to itself (under raw equality).
    ///
    /// When Lua collects a full userdata with a gc metamethod, Lua calls the
    /// metamethod and marks the userdata as finalized. When this userdata is
    /// collected again then Lua frees its corresponding memory.
    ///
    /// This is the same as lua_newuserdata.
    pub fn newUserData(self: Self, comptime T: type) *T {
        // LuaJIT panic if not enough memory.
        return @ptrCast(@alignCast(c.lua_newuserdata(self.lua, @sizeOf(T)).?));
    }

    /// Pushes onto the stack the metatable of the value at the given acceptable
    /// index. If the index is not valid, or if the value does not have a
    /// metatable, the function returns false and pushes nothing on the stack.
    ///
    /// This is the same as lua_getmetatable.
    pub fn getMetaTable(self: Self, objindex: c_int) bool {
        return c.lua_getmetatable(self.lua, objindex) != 0;
    }

    /// Pushes onto the stack the environment table of the value at the given
    /// index.
    ///
    /// This is the same as lua_getfenv.
    pub fn getFEnv(self: Self, idx: c_int) void {
        c.lua_getfenv(self.lua, idx);
    }

    /// Does the equivalent to `t[k] = v`, where t is the value at the given
    /// valid index, v is the value at the top of the stack, and k is the value
    /// just below the top.
    ///
    /// This function pops both the key and the value from the stack. As in Lua,
    /// this function may trigger a metamethod for the "newindex" event.
    ///
    /// This is the same as lua_settable.
    pub fn setTable(self: Self, idx: c_int) void {
        c.lua_settable(self.lua, idx);
    }

    /// Does the equivalent to `t[k] = v`, where t is the value at the given
    /// valid index and v is the value at the top of the stack.
    /// This function pops the value from the stack. As in Lua, this function
    /// may trigger a metamethod for the "newindex" event.
    ///
    /// This is the same as lua_setfield.
    pub fn setField(self: Self, idx: c_int, k: [*c]const u8) void {
        c.lua_setfield(self.lua, idx, k);
    }

    /// Similar to lua_settable, but does a raw assignment (i.e., without
    /// metamethods).
    ///
    /// This is the same as lua_rawset.
    pub fn rawSet(self: Self, idx: c_int) void {
        c.lua_rawset(self.lua, idx);
    }

    /// Does the equivalent of `t[n] = v`, where t is the value at the given
    /// valid index and v is the value at the top of the stack.
    /// This function pops the value from the stack. The assignment is raw; that
    /// is, it does not invoke metamethods.
    ///
    /// This is the same as lua_rawseti.
    pub fn rawSeti(self: Self, idx: c_int, n: c_int) void {
        c.lua_rawseti(self.lua, idx, n);
    }

    /// Pops a table from the stack and sets it as the new metatable for the
    /// value at the given acceptable index.
    ///
    /// This is the same as lua_setmetatable.
    pub fn setMetaTable(self: Self, objindex: c_int) void {
        _ = c.lua_setmetatable(self.lua, objindex);
    }

    /// Pops a table from the stack and sets it as the new environment for the
    /// value at the given index. If the value at the given index is neither a
    /// function nor a thread nor a userdata, lua_setfenv returns false.
    /// Otherwise it returns true.
    ///
    /// This is the same as lua_setfenv.
    pub fn setFEnv(self: Self, idx: c_int) bool {
        return c.lua_setfenv(self.lua, idx) != 0;
    }

    /// Calls a function.
    ///
    /// To call a function you must use the following protocol: first, the
    /// function to be called is pushed onto the stack; then, the arguments to
    /// the function are pushed in direct order; that is, the first argument is
    /// pushed first. Finally you call lua_call; nargs is the number of
    /// arguments that you pushed onto the stack. All arguments and the function
    /// value are popped from the stack when the function is called. The
    /// function results are pushed onto the stack when the function returns.
    /// The number of results is adjusted to nresults, unless nresults is
    /// MULTRET. In this case, all results from the function are pushed. Lua
    /// takes care that the returned values fit into the stack space. The
    /// function results are pushed onto the stack in direct order (the first
    /// result is pushed first), so that after the call the last result is on
    /// the top of the stack.
    ///
    /// Any error inside the called function is propagated upwards (with a
    /// longjmp).
    ///
    /// The following example shows how the host program can do the equivalent
    /// to this Lua code:
    /// ```
    ///      a = f("how", t.x, 14)
    /// ```
    ///
    /// Here it is in Zig:
    /// ```
    ///      var state: zluajit.State = ...;
    ///      state.getGlobal("f");                     // function to be called
    ///      state.pushString("how");                           // 1st argument
    ///      state.getGlobal("t");                       // table to be indexed
    ///      state.getField(-1, "x");           // push result of t.x (2nd arg)
    ///      state.remove(-2);                     // remove 't' from the stack
    ///      state.pushInteger(14);                             // 3rd argument
    ///      state.call(3, 1);        // call 'f' with 3 arguments and 1 result
    ///      state.setGlobal("a");                            // set global 'a'
    /// ```
    ///
    /// Note that the code above is "balanced": at its end, the stack is back
    /// to its original configuration. This is considered good programming
    /// practice.
    ///
    /// This is the same as lua_call.
    pub fn call(self: Self, nargs: c_int, nresults: c_int) void {
        c.lua_call(self.lua, nargs, nresults);
    }

    /// Calls a function in protected mode.
    ///
    /// Both nargs and nresults have the same meaning as in lua_call. If there
    /// are no errors during the call, lua_pcall behaves exactly like lua_call.
    /// However, if there is any error, lua_pcall catches it, pushes a single
    /// value on the stack (the error message), and returns an error code. Like
    /// lua_call, lua_pcall always removes the function and its arguments from
    /// the stack.
    ///
    /// If errfunc is 0, then the error message returned on the stack is exactly
    /// the original error message. Otherwise, errfunc is the stack index of an
    /// error handler function. (In the current implementation, this index
    /// cannot be a pseudo-index.) In case of runtime errors, this function will
    /// be called with the error message and its return value will be the
    /// message returned on the stack by lua_pcall.
    ///
    /// Typically, the error handler function is used to add more debug
    /// information to the error message, such as a stack traceback. Such
    /// information cannot be gathered after the return of lua_pcall, since by
    /// then the stack has unwound.
    pub fn pCall(
        self: Self,
        nargs: c_int,
        nresults: c_int,
        errfunc: c_int,
    ) CallError!void {
        const code = c.lua_pcall(self.lua, nargs, nresults, errfunc);
        try callErrorFromInt(code);
        std.debug.assert(code == 0);
    }

    /// Calls the C function func in protected mode. func starts with only one
    /// element in its stack, a light userdata containing ud. In case of errors,
    /// lua_cpcall returns the same error codes as lua_pcall, plus the error
    /// object on the top of the stack; otherwise, it returns zero, and does not
    /// change the stack. All values returned by func are discarded.
    ///
    /// This is the same as lua_cpcall.
    pub fn cPCall(
        self: Self,
        func: CFunction,
        udata: ?*anyopaque,
    ) CallError!void {
        return callErrorFromInt(c.lua_cpcall(self.lua, func, udata));
    }

    /// Calls a metamethod.
    ///
    /// If the object at index obj has a metatable and this metatable has a
    /// field e, this function calls this field and passes the object as its
    /// only argument. In this case this function returns true and pushes onto
    /// the stack the value returned by the call. If there is no metatable or no
    /// metamethod, this function returns 0 (without pushing any value on the
    /// stack).
    ///
    /// This is the same as luaL_callmeta.
    pub fn callMeta(self: Self, obj: c_int, e: [*c]const u8) bool {
        return c.luaL_callmeta(self.lua, obj, e) != 0;
    }

    /// Loads a Lua chunk. If there are no errors, State.load pushes the
    /// compiled chunk as a Lua function on top of the stack. Otherwise, it
    /// pushes an error message.
    ///
    /// This function only loads a chunk; it does not run it.
    /// State.load automatically detects whether the chunk is text or binary,
    /// and loads it accordingly.
    ///
    /// The State.load function uses a user-supplied reader function to read
    /// the chunk (see Reader). The data argument is an opaque value passed to
    /// the reader function.
    ///
    /// The chunkname argument gives a name to the chunk, which is used for
    /// error messages and in debug information.
    ///
    /// This is the same as lua_load.
    pub fn load(
        self: Self,
        reader: Reader,
        dt: ?*anyopaque,
        chunkname: [*c]const u8,
    ) LoadError!void {
        return loadErrorFromInt(c.lua_load(self.lua, reader, dt, chunkname));
    }

    /// Loads a string as a Lua chunk. This function uses lua_load to load the
    /// chunk in the zero-terminated string s.
    /// This function returns the same results as lua_load.
    ///
    /// Also as State.load, this function only loads the chunk; it does not run
    /// it.
    ///
    /// This is the same as luaL_loadbuffer.
    pub fn loadString(self: Self, s: []const u8, name: [*c]const u8) LoadError!void {
        return loadErrorFromInt(c.luaL_loadbuffer(self.lua, s.ptr, s.len, name));
    }

    /// Loads a file as a Lua chunk. This function uses lua_load to load the
    /// chunk in the file named filename. If filename is NULL, then it loads
    /// from the standard input. The first line in the file is ignored if it
    /// starts with a #.
    ///
    /// This function returns the same results as State.load, but it has an
    /// extra error code LUA_ERRFILE if it cannot open/read the file.
    ///
    /// As State.load, this function only loads the chunk; it does not run it.
    ///
    /// This is the same as luaL_loadfile.
    pub fn loadFile(self: Self, filename: [*c]const u8) LoadFileError!void {
        return loadFileErrorFromInt(c.luaL_loadfile(self.lua, filename));
    }

    /// Loads and runs the given string.
    ///
    /// This is similar to luaL_dostring.
    pub fn doString(
        self: Self,
        s: []const u8,
        name: [*c]const u8,
    ) (LoadError || CallError)!void {
        try self.loadString(s, name);
        try self.pCall(0, Multiple, 0);
    }

    /// Loads and runs the given file.
    ///
    /// This is similar to luaL_dofile.
    pub fn doFile(
        self: Self,
        filename: [*c]const u8,
    ) (LoadFileError || CallError)!void {
        try self.loadFile(filename);
        try self.pCall(0, Multiple, 0);
    }

    /// Dumps a function as a binary chunk. Receives a Lua function on the top
    /// of the stack and produces a binary chunk that, if loaded again, results
    /// in a function equivalent to the one dumped. As it produces parts of the
    /// chunk, lua_dump calls function writer (see lua_Writer) with the given
    /// data to write them.
    ///
    /// The value returned is the error code returned by the last call to the
    /// writer.
    ///
    /// This function does not pop the Lua function from the stack.
    ///
    /// This is the same as lua_dump.
    pub fn dump(self: Self, writer: Writer, data: ?*anyopaque) !void {
        const err = c.lua_dump(self.lua, writer, data);
        if (err != 0) return @errorFromInt(err);
    }

    /// Returns true if the given coroutine can yield, and false otherwise.
    ///
    /// This is the same as c.lua_isyieldable.
    pub fn isYieldable(self: Self) bool {
        return c.lua_isyieldable(self.lua) != 0;
    }

    /// Yields a coroutine.
    ///
    /// This function should only be called as the return expression of a
    /// CFunction, as follows:
    /// ```zig
    ///     return thread.yield(nresults);
    /// ```
    ///
    /// When a CFunction calls State.yield in that way, the running
    /// coroutine suspends its execution, and the call to State.@"resume"
    /// that started this coroutine returns.
    ///
    /// The parameter nresults is the number of values from the stack that are
    /// passed as results to State.@"resume".
    ///
    /// This is the same as lua_yield.
    pub fn yield(self: Self, nresults: c_int) c_int {
        return c.lua_yield(self.lua, nresults);
    }

    /// Starts and resumes a coroutine in a given thread.
    ///
    /// To start a coroutine, you first create a new thread (see
    /// State.newThread); then you push onto its stack the main function plus
    /// any arguments; then you call State.@"resume", with narg being the
    /// number of arguments. This call returns when the coroutine suspends or
    /// finishes its execution. When it returns, the stack contains all values
    /// passed to State.yield, or all values returned by the body function.
    /// State.@"resume" returns State.Status.yield if the coroutine yields,
    /// State.Status.ok if the coroutine finishes its execution without errors,
    /// or an error code in case of errors (see State.pCall). In case of
    /// errors, the stack is not unwound, so you can use the debug API over it.
    /// The error message is on the top of the stack. To restart a coroutine,
    /// you put on its stack only the values to be passed as results from yield,
    /// and then call State.@"resume".
    ///
    /// This is the same as lua_resume.
    pub fn @"resume"(self: Self, narg: c_int) (CallError)!Status {
        const code = c.lua_resume(self.lua, narg);
        try callErrorFromInt(code);
        return statusFromInt(code);
    }

    /// Returns the status of the thread.
    ///
    /// The status can be ok for a normal thread, an error code if the thread
    /// finished its execution with an error, or yield if the thread is
    /// suspended.
    ///
    /// This is the same as lua_status.
    pub fn status(self: Self) CallError!Status {
        const code = c.lua_status(self.lua);
        try callErrorFromInt(code);
        return statusFromInt(code);
    }

    /// Controls the garbage collector.
    ///
    /// This function performs several tasks, according to the value of the
    /// parameter what:
    ///
    /// * GcOp.stop: stops the garbage collector.
    /// * GcOp.restart: restarts the garbage collector.
    /// * GcOp.collect: performs a full garbage-collection cycle.
    /// * GcOp.count: returns the current amount of memory (in Kbytes) in use by
    /// Lua.
    /// * GcOp.countb: returns the remainder of dividing the current amount of
    /// bytes of memory in use by Lua by 1024.
    /// * GcOp.step: performs an incremental step of garbage collection. The
    /// step "size" is controlled by data (larger values mean more steps) in a
    /// non-specified way. If you want to control the step size you must
    /// experimentally tune the value of data. The function returns 1 if the
    /// step finished a garbage-collection cycle.
    /// * GcOp.setpause: sets data as the new value for the pause of the
    /// collector. The function returns the previous value of the pause.
    /// * GcOp.setstepmul: sets data as the new value for the step multiplier of
    /// the collector. The function returns the previous value of the step
    /// multiplier.
    ///
    /// This is the same as lua_gc.
    pub fn gc(self: Self, what: GcOp, data: c_int) c_int {
        return c.lua_gc(self.lua, @intFromEnum(what), data);
    }

    /// Generates a Lua error. The error message (which can actually be a Lua
    /// value of any type) must be on the stack top. This function does a long
    /// jump, and therefore never returns.
    ///
    /// This is the same as lua_error.
    pub fn @"error"(self: Self) noreturn {
        _ = c.lua_error(self.lua);
        unreachable;
    }

    /// Converts provided Zig error into a Lua error and raise it.
    pub fn raiseError(self: Self, err: anyerror) noreturn {
        self.pushString(@errorName(err)[0..]);
        self.@"error"();
        unreachable;
    }

    /// Pops a key from the stack, and pushes a key-value pair from the table at
    /// the given index (the "next" pair after the given key). If there are no
    /// more elements in the table, then lua_next returns 0 (and pushes
    /// nothing).
    ///
    /// A typical traversal looks like this:
    ///
    /// ```zig
    ///     // table is in the stack at index 't'
    ///     state.pushNil(); // first key
    ///     while (state.next(t)) {
    ///         // uses 'key' (at index -2) and 'value' (at index -1)
    ///         std.debug.print("{s} - {s}\n", .{
    ///             state.typeName(state.valueType(-2).?),
    ///             state.typeName(state.valueType(-1).?),
    ///         });
    ///         // removes 'value'; keeps 'key' for next iteration
    ///         state.pop(1);
    ///     }
    /// ```
    ///
    /// While traversing a table, do not call State.toString directly on a
    /// key, unless you know that the key is actually a string. Recall that
    /// State.toString changes the value at the given index; this confuses
    /// the next call to State.next.
    ///
    /// This is the same as lua_next.
    pub fn next(self: Self, idx: c_int) bool {
        return c.lua_next(self.lua, idx) != 0;
    }

    /// Concatenates the n values at the top of the stack, pops them, and leaves
    /// the result at the top. If n is 1, the result is the single value on the
    /// stack (that is, the function does nothing); if n is 0, the result is the
    /// empty string. Concatenation is performed following the usual semantics
    /// of Lua.
    ///
    /// This is the same as lua_concat.
    pub fn concat(self: Self, n: c_int) void {
        return c.lua_concat(self.lua, n);
    }

    /// Returns the memory-allocation function of a given state. If ud is not
    /// null, Lua stores in *ud the opaque pointer passed to State.init.
    ///
    /// This is the same as lua_getallocf.
    pub fn allocator(self: Self) *std.mem.Allocator {
        var ud: ?*std.mem.Allocator = null;
        _ = c.lua_getallocf(self.lua, @ptrCast(@alignCast(&ud)));
        if (ud == null) return @constCast(&std.heap.c_allocator);
        return ud.?;
    }

    /// Changes the allocator of a given state to f with user data ud.
    ///
    /// This is the same as lua_setallocf.
    pub fn setAllocator(self: Self, alloc: ?*std.mem.Allocator) void {
        if (alloc == null) {
            c.lua_setallocf(self.lua, null, null);
        } else {
            c.lua_setallocf(self.lua, luaAlloc, alloc);
        }
    }

    /// Sets the CFunction f as the new value of global name.
    ///
    /// This is the same as c.lua_register.
    pub fn register(self: Self, name: [*c]const u8, cfunc: CFunction) void {
        c.lua_register(self.lua, name, cfunc);
    }

    fn open(self: Self, loader: CFunction) void {
        self.pushCFunction(loader);
        self.call(0, 0);
    }

    /// Opens and loads base library which includes globals such as print and
    /// the coroutine sub-library.
    pub fn openBase(self: Self) void {
        self.open(c.luaopen_base);
    }

    /// Opens and loads package library.
    pub fn openPackage(self: Self) void {
        self.open(c.luaopen_package);
    }

    /// Opens and loads string library.
    pub fn openString(self: Self) void {
        self.open(c.luaopen_string);
    }

    /// Opens and loads table library.
    pub fn openTable(self: Self) void {
        self.open(c.luaopen_table);
    }

    /// Opens and loads math library.
    pub fn openMath(self: Self) void {
        self.open(c.luaopen_math);
    }

    /// Opens and loads input / output library.
    pub fn openIO(self: Self) void {
        self.open(c.luaopen_io);
    }

    /// Opens and loads OS library.
    pub fn openOS(self: Self) void {
        self.open(c.luaopen_os);
    }

    /// Opens and loads debug library.
    ///
    /// This is the same a luaL_openlibs.
    pub fn openDebug(self: Self) void {
        self.open(c.luaopen_debug);
    }

    /// Opens all standard Lua libraries into the given state.
    ///
    /// This is the same a luaL_openlibs.
    pub fn openLibs(self: Self) void {
        c.luaL_openlibs(self.lua);
    }

    /// If the registry already has a the key `tname`, returns false.
    /// Otherwise, creates a new table to be used as a metatable for userdata,
    /// adds it to the registry with key `tname`, and returns true.
    ///
    /// In both cases pushes onto the stack the final value associated with
    /// `tname` in the registry.
    ///
    /// See State.newMetaTable for a more Zig friendly version.
    ///
    /// This is the same as luaL_newmetatable.
    pub fn newMetaTableWithName(
        self: Self,
        tname: [*:0]const u8,
    ) bool {
        return c.luaL_newmetatable(self.lua, tname) != 0;
    }

    /// If the registry already has a table for tname of T, returns false.
    /// Otherwise, creates a new table to be used as a metatable for userdata,
    /// adds it to the registry, and returns true.
    ///
    /// In both cases pushes onto the stack the final value associated with
    /// T in the registry.
    ///
    /// This is similar to State.newMetaTableWithName where `tname` is
    /// T.zluajitTName if it exists or @typeName(T).
    ///
    /// ```
    /// // In file foo.zig
    ///
    /// const Foo = struct {
    ///     pub const zluajitTName = "foo.Bar";
    /// };
    ///
    /// const Bar = struct {};
    ///
    /// pub fn main() {
    ///     // ....
    ///     var state: zluajit.State = ...;
    ///
    ///     var exists = state.newMetaTable(Foo);
    ///     // exists is false
    ///
    ///     exists = state.newMetaTable(Bar);
    ///     // exists is true as Foo.zluajitTName == @typeName(Bar)
    ///     // Foo and Bar shares the same metatable.
    /// }
    /// ```
    pub fn newMetaTable(self: Self, comptime T: type) bool {
        return self.newMetaTableWithName(tName(T));
    }

    /// If the registry already has a table for tname of T, returns null.
    /// Otherwise, creates a new table to be used as a metatable for userdata,
    /// adds it to the registry, and returns a TableRef.
    ///
    /// In both cases pushes onto the stack the final value associated with
    /// T in the registry.
    ///
    /// This is similar to State.newMetaTable.
    pub fn newMetaTableRef(self: Self, comptime T: type) ?TableRef {
        if (self.newMetaTable(T)) {
            return self.toAnyType(-1, TableRef);
        }
        return null;
    }

    /// Creates and returns a reference, in the table at index `t`, for the
    /// object at the top of the stack (and pops the object).
    ///
    /// A reference is a unique integer key. As long as you do not manually add
    /// integer keys into table `t`, State.ref ensures the uniqueness of the key
    /// it returns. You can retrieve an object referred by reference `r` by
    /// calling `State.rawGeti(t, r)`. Function State.unref frees a reference
    /// and its associated object.
    ///
    /// If the object at the top of the stack is nil, State.ref returns the
    /// constant RefNil. The constant NoRef is guaranteed to be different from
    /// any reference returned by luaL_ref.
    ///
    /// This is the same as luaL_ref.
    pub fn ref(self: Self, t: c_int) RefError!c_int {
        return switch (c.luaL_ref(self.lua, t)) {
            c.LUA_NOREF => RefError.NoRef,
            c.LUA_REFNIL => RefError.NilRef,
            else => |r| r,
        };
    }

    /// Creates and returns a reference, in the table at index `t`, for the
    /// object at stack index `idx`.
    /// A reference is a unique integer key. As long as you do not manually add
    /// integer keys into table `t`, State.ref ensures the uniqueness of the key
    /// it returns. You can retrieve an object referred by reference `r` by
    /// calling `State.rawGeti(t, r)`. Function State.unref frees a reference
    /// and its associated object.
    ///
    /// If the object at the top of the stack is nil, State.ref returns the
    /// constant RefNil. The constant NoRef is guaranteed to be different from
    /// any reference returned by luaL_ref.
    ///
    /// This is similar to luaL_ref.
    pub fn refValue(self: Self, t: c_int, idx: c_int) RefError!c_int {
        self.pushValue(idx);
        return self.ref(t);
    }

    /// Releases reference ref from the table at index t (see State.ref). The
    /// entry is removed from the table, so that the referred object can be
    /// collected. The reference ref is also freed to be used again.
    ///
    /// This is the same as luaL_unref.
    pub fn unref(self: Self, t: c_int, r: c_int) void {
        c.luaL_unref(self.lua, t, r);
    }

    /// Returns global table as a TableRef.
    pub fn globalRef(self: Self) TableRef {
        return TableRef.init(ValueRef.init(self, Global));
    }

    /// Returns registry table as a TableRef.
    pub fn registryRef(self: Self) TableRef {
        return TableRef.init(ValueRef.init(self, Registry));
    }

    /// Returns environment table as a TableRef.
    pub fn environmentRef(self: Self) TableRef {
        return TableRef.init(ValueRef.init(self, Environment));
    }

    /// Creates and pushes a traceback of the stack `L1`. If msg is not null
    /// it is appended at the beginning of the traceback. The level parameter
    /// tells at which level to start the traceback.
    ///
    /// This is the same as luaL_traceback.
    pub fn traceBack(
        self: Self,
        L1: Self,
        msg: [*c]const u8,
        level: c_int,
    ) void {
        c.luaL_traceback(self.lua, L1.lua, msg, level);
    }
};

/// RefError defines possible error returned by State.ref.
pub const RefError = error{
    NilRef,
    NoRef,
};

/// State.gc() operations.
pub const GcOp = enum(c_int) {
    stop = c.LUA_GCSTOP,
    restart = c.LUA_GCRESTART,
    collect = c.LUA_GCCOLLECT,
    count = c.LUA_GCCOUNT,
    countb = c.LUA_GCCOUNTB,
    step = c.LUA_GCSTEP,
    setpause = c.LUA_GCSETPAUSE,
    setstepmul = c.LUA_GCSETSTEPMUL,
};

/// LoadError defines possible error returned by loading a chunk of Lua code /
/// bytecode.
pub const LoadError = error{
    /// LUA_ERRSYNTAX
    InvalidSyntax,
    /// LUA_ERRMEM
    OutOfMemory,
};

fn loadErrorFromInt(code: c_int) LoadError!void {
    return switch (code) {
        c.LUA_ERRSYNTAX => LoadError.InvalidSyntax,
        c.LUA_ERRMEM => LoadError.OutOfMemory,
        else => {},
    };
}

/// LoadError defines possible error returned by loading a chunk of Lua code /
/// bytecode.
pub const LoadFileError = error{
    /// LUA_ERRSYNTAX
    InvalidSyntax,
    /// LUA_ERRMEM
    OutOfMemory,
};

fn loadFileErrorFromInt(code: c_int) LoadFileError!void {
    return switch (code) {
        c.LUA_ERRSYNTAX => LoadFileError.InvalidSyntax,
        c.LUA_ERRMEM => LoadFileError.OutOfMemory,
        c.LUA_ERRFILE => unreachable,
        else => {},
    };
}

/// Special `nreturns` value to use when calling function that returns an
/// unknown number of value.
pub const Multiple = c.LUA_MULTRET;

/// CallError defines possible error returned by a protected call to a Lua
/// function.
pub const CallError = error{
    /// LUA_ERRRUN
    Runtime,
    /// LUA_ERRMEM
    OutOfMemory,
    /// LUA_ERRERR
    Handler,
};

fn callErrorFromInt(code: c_int) CallError!void {
    return switch (code) {
        c.LUA_ERRRUN => CallError.Runtime,
        c.LUA_ERRMEM => CallError.OutOfMemory,
        c.LUA_ERRERR => CallError.Handler,
        else => {},
    };
}

/// ValueType enumerates all Lua type.
pub const ValueType = enum(c_int) {
    boolean = c.LUA_TBOOLEAN,
    function = c.LUA_TFUNCTION,
    lightuserdata = c.LUA_TLIGHTUSERDATA,
    nil = c.LUA_TNIL,
    number = c.LUA_TNUMBER,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    thread = c.LUA_TTHREAD,
    userdata = c.LUA_TUSERDATA,
    proto = c.LUA_TTHREAD + 1,
    cdata = c.LUA_TTHREAD + 2,
};

/// Value is a union over all Lua value types.
pub const Value = union(ValueType) {
    boolean: bool,
    function: FunctionRef,
    lightuserdata: *anyopaque,
    nil: void,
    number: f64,
    string: []const u8,
    table: TableRef,
    thread: State,
    userdata: *anyopaque,
    proto: void,
    cdata: CData,
};

/// CData defines a LuaJIT C data structure. You may need this to interact with
/// FFI values or string buffers.
pub const CData = [*c]u8;

/// ValueRef is a reference to a Lua value on the stack of a state. state
/// must outlive ValueRef and stack position must remain stable.
pub const ValueRef = struct {
    const Self = @This();
    const zluajitPoppable = false;

    L: State,
    idx: c_int,

    /// Initializes a new reference of value at index `idx` on stack of
    /// `thread`. If `idx` is a relative index, it is converted to an absolute
    /// index.
    pub fn init(L: State, idx: c_int) Self {
        return .{
            .L = L,
            .idx = if (idx < 0 and idx > Registry) L.top() + idx + 1 else idx,
        };
    }

    /// Returns the type of the value referenced or null for
    /// a non-valid (but acceptable) reference.
    pub fn valueType(self: Self) ?ValueType {
        return self.L.valueType(self.idx);
    }

    /// Returns a TableRef, a specialized reference for table values. If
    /// referenced value isn't a table, this function panics.
    pub fn toTable(self: Self) TableRef {
        std.debug.assert(self.valueType() == .table);
        return TableRef.init(self);
    }

    /// Returns a FunctionRef, a specialized reference for function values. If
    /// referenced value isn't a function, this function panics.
    pub fn toFunction(self: Self) FunctionRef {
        std.debug.assert(self.valueType() == .function);
        return FunctionRef.init(self);
    }

    /// Converts referenced value to a pointer.
    ///
    /// Typically this function is used only for debug information.
    pub fn toPointer(self: Self) ?*const anyopaque {
        return self.L.toPointer(self.idx);
    }
};

/// Pseudo-index of table holding global variables.
pub const Global = c.LUA_GLOBALSINDEX;
/// Pseudo-index of environment of the running C function.
pub const Environment = c.LUA_ENVIRONINDEX;
/// Pseudo-index of registry table.
pub const Registry = c.LUA_REGISTRYINDEX;

/// The type used by the Lua API to represent integral values.
pub const Integer = c.lua_Integer;

/// The type of numbers in Lua. By default, it is double, but that can be
/// changed in luaconf.h.
/// Through the configuration file you can change Lua to operate with another
/// type for numbers (e.g., float or long).
pub const Number = c.lua_Number;

/// TableRef is a reference to a table value on the stack of a state.
/// state must outlive TableRef and stack position must remain stable.
pub const TableRef = struct {
    const Self = @This();

    ref: ValueRef,

    pub fn init(ref: ValueRef) Self {
        std.debug.assert(ref.valueType() == .table);
        return .{ .ref = ref };
    }

    /// Does the equivalent to `t[k] = v`. Stack remains unchanged.
    /// As in Lua, this function may trigger a metamethod for the "newindex"
    /// event.
    pub fn setField(self: Self, k: [*c]const u8, v: anytype) void {
        self.ref.L.pushAnyType(v);
        self.ref.L.setField(self.ref.idx, k);
    }

    /// Does the equivalent to `t[k] = v`. Stack remains unchanged.
    /// As in Lua, this function may trigger a metamethod for the "newindex"
    /// event.
    pub fn set(self: Self, k: anytype, v: anytype) void {
        self.ref.L.pushAnyType(k);
        self.ref.L.pushAnyType(v);
        self.ref.L.setTable(self.ref.idx);
    }

    /// Does the equivalent to `t[k] = v`. Stack remains unchanged.
    /// This perform a raw access and doesn't trigger "index" event (no
    /// metamethod is called).
    pub fn rawSet(self: Self, k: anytype, v: anytype) void {
        self.ref.L.pushAnyType(k);
        self.ref.L.pushAnyType(v);
        self.ref.L.rawSet(self.ref.idx);
    }

    /// Pushes onto the stack the value `t[k]` and returns it.
    /// As in Lua, this function may trigger a metamethod for the "index"
    /// event.
    pub fn getField(self: Self, k: [*c]const u8, comptime T: type) ?T {
        self.ref.L.getField(self.ref.idx, k);
        return self.ref.L.toAnyType(-1, T);
    }

    /// Pushes onto the stack the value `t[k]` and returns it.
    /// As in Lua, this function may trigger a metamethod for the "index" event.
    pub fn get(self: Self, k: anytype, comptime T: type) ?T {
        self.ref.L.pushAnyType(k);
        self.ref.L.getTable(self.ref.idx);
        return self.ref.L.toAnyType(-1, T);
    }

    /// Pushes onto the stack the value `t[k]` and returns it.
    /// This perform a raw access and doesn't trigger "index" event (no
    /// metamethod is called).
    pub fn rawGet(self: Self, k: anytype, comptime T: type) ?T {
        self.ref.L.pushAnyType(k);
        self.ref.L.rawGet(self.ref.idx);
        return self.ref.L.toAnyType(-1, T);
    }

    /// Pushes onto the stack the value `t[k]`, pops, and returns it.
    /// As in Lua, this function may trigger a metamethod for the "index"
    /// event.
    pub fn pop(self: Self, k: anytype, comptime T: type) ?T {
        self.ref.L.pushAnyType(k);
        self.ref.L.getTable(self.ref.idx);
        return self.ref.L.popAnyType(T);
    }

    /// Does equivalent to `setmetatable(t, mt)` where `mt` is this table and
    /// `t` is table / userdata at index `idx`.
    pub fn asMetaTableOf(self: Self, idx: c_int) void {
        self.ref.L.pushValue(self.ref.idx);
        self.ref.L.setMetaTable(idx);
    }

    /// Pushes metatable associated to this table onto the stack and returns a
    /// reference to it.
    pub fn getMetaTable(self: Self) ?TableRef {
        if (self.ref.L.getMetaTable(self.ref.idx)) {
            return self.ref.L.toAnyType(-1, TableRef).?;
        }

        return null;
    }

    /// Retrieves length of table sequence.
    pub fn length(self: Self) usize {
        return self.ref.L.objLen(self.ref.idx);
    }

    /// Appends value v at end of table.
    pub fn append(self: Self, v: anytype) void {
        self.set(@as(c_int, @intCast(self.length())), v);
    }
};

/// FunctionRef is a reference to a function on the stack of a state.
/// state must outlive FunctionRef and stack position must remain stable.
pub const FunctionRef = struct {
    const Self = @This();

    ref: ValueRef,

    pub fn init(ref: ValueRef) Self {
        std.debug.assert(ref.valueType() == .function);
        return .{ .ref = ref };
    }

    /// Calls the Lua function with provided arguments and returns the number of
    /// result on the stack.
    pub fn call(self: *Self, args: anytype, nresult: c_int) void {
        const info = @typeInfo(@TypeOf(args)).@"struct";

        self.ref.L.pushValue(self.ref.idx);

        inline for (0..info.fields.len) |i| {
            self.ref.L.pushAnyType(args[i]);
        }

        self.ref.L.call(info.fields.len, nresult);
    }
};

/// Type for C functions.
/// In order to communicate properly with Lua, a C function must use the
/// following protocol, which defines the way parameters and results are passed:
/// a C function receives its arguments from Lua in its stack in direct order
/// (the first argument is pushed first). So, when the function starts,
/// State.top() returns the number of arguments received by the function. The
/// first argument (if any) is at index 1 and its last argument is at index
/// State.top(). To return values to Lua, a C function just pushes them onto
/// the stack, in direct order (the first result is pushed first), and returns
/// the number of results. Any other value in the stack below the results will
/// be properly discarded by Lua. Like a Lua function, a C function called by
/// Lua can also return many results.
pub const CFunction = *const fn (?*c.lua_State) callconv(.c) c_int;

/// Type for Zig function.
/// Zig functions are automatically converted to C functions.
/// See CFunction for more details.
pub const ZFunction = *const fn (State) c_int;

/// The reader function used by State.load. Every time it needs another piece
/// of the chunk, State.load calls the reader, passing along its data
/// parameter.
/// The reader must return a pointer to a block of memory with a new piece of
/// the chunk and set size to the block size. The block must exist until the
/// reader function is called again. To signal the end of the chunk, the reader
/// must return null or set size to zero. The reader function may return pieces
/// of any size greater than zero.
pub const Reader = *const fn (
    ?*c.lua_State,
    ?*anyopaque,
    [*c]usize,
) callconv(.c) [*c]const u8;

/// The type of the writer function used by lua_dump. Every time it produces
/// another piece of chunk, lua_dump calls the writer, passing along the buffer
/// to be written (p), its size (sz), and the data parameter supplied to
/// State.dump.
//
/// The writer returns an error code: 0 means no errors; any other value means
/// an error and stops State.dump from calling the writer again.
pub const Writer = *const fn (
    ?*c.lua_State,
    ?*const anyopaque,
    usize,
    ?*anyopaque,
) callconv(.c) c_int;

/// c.lua_Alloc function to enable Lua VM to allocate memory using zig
/// allocator.
fn luaAlloc(
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*align(@sizeOf(std.c.max_align_t)) anyopaque {
    const alloc: *std.mem.Allocator = @ptrCast(@alignCast(ud.?));

    if (@as(?[*]align(@sizeOf(std.c.max_align_t)) u8, @ptrCast(@alignCast(ptr)))) |aligned_ptr| {
        var slice = aligned_ptr[0..osize];
        slice = alloc.realloc(slice, nsize) catch return null;
        return slice.ptr;
    } else {
        const slice = alloc.alignedAlloc(
            u8,
            if (zig0_15) std.mem.Alignment.fromByteUnits(@sizeOf(std.c.max_align_t)) else @sizeOf(std.c.max_align_t),
            nsize,
        ) catch return null;
        return slice.ptr;
    }
}

/// Panic function called by lua before aborting. This functions dumps lua stack
/// before panicking.
pub fn luaPanic(lua: ?*c.lua_State) callconv(.c) c_int {
    const state = State.initFromCPointer(lua.?);
    state.dumpStack();
    @panic("lua panic");
}

/// Wraps a Zig function into a CFunction at comptime that takes care of
/// extracting argument from stack and pushing result onto the stack.
/// Zig errors are converted to string.
///
/// If function first argument is of type state, this state will be passed
/// as argument. If you want to receive a coroutine as first argument, your
/// function must take 2 state argument:
///     fn myZigFunction(callingState: State, argState: State) void {
///         //...
///     }
///
/// If function returns a value of type c_int.
pub fn wrapFn(func: anytype) CFunction {
    const Func = @TypeOf(func);
    const info = @typeInfo(Func).@"fn";

    return struct {
        fn cfunc(lua: ?*c.lua_State) callconv(.c) c_int {
            const th = State.initFromCPointer(lua.?);

            var args: std.meta.ArgsTuple(Func) = undefined;

            comptime var thread_forwarded = false;
            comptime var i = 1;
            inline for (
                &args,
                info.params,
            ) |*arg, p| {
                if (!thread_forwarded and p.type == State and i == 1) {
                    arg.* = th;
                    thread_forwarded = true;
                    continue;
                } else arg.* = th.checkAnyType(i, p.type.?);
                i += 1;
            }

            const result = @call(.auto, func, args);
            switch (@typeInfo(info.return_type.?)) {
                .error_union => |err_union| {
                    if (result) |r| {
                        if (err_union.payload != void) {
                            if (err_union.payload == c_int) {
                                return r;
                            }
                            th.pushAnyType(r);
                            return 1;
                        } else {
                            return 0;
                        }
                    } else |err| {
                        th.raiseError(err);
                    }
                },
                else => {},
            }
            if (info.return_type != void) {
                if (info.return_type == c_int) {
                    return result;
                }

                th.pushAnyType(result);
                return 1;
            }

            return 0;
        }
    }.cfunc;
}

/// Returns T.zluajitTName if it exists and @typeName(T) otherwise.
///
/// This function is used by State.newMetaTable and State.checkUserData.
pub fn tName(comptime T: type) [*:0]const u8 {
    const tnameField = "zluajitTName";
    if (@typeInfo(T) == .@"struct" and @hasDecl(T, tnameField)) {
        return @field(T, tnameField);
    }
    return @typeName(T);
}

/// Lua nil value.
pub const nil = Value.nil;
