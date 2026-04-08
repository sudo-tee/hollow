const std = @import("std");
const builtin = @import("builtin");

const recover = @import("./recover.zig");
const z = @import("zluajit");

const testing = std.testing;
const recoverCall = recover.call;

var panic_msg: []const u8 = "";

/// Execute provided test case with a memory limited allocator, increasing it's
/// limit each time test case returns an [OutOfMemory] error or panics.
fn withProgressiveAllocator(tcase: fn (*std.mem.Allocator) anyerror!void) !void {
    std.debug.assert(builtin.is_test);

    var palloc = ProgressiveAllocator.init();
    var alloc = palloc.allocator();
    defer palloc.deinit();

    while (true) {
        tcase(&alloc) catch |err| {
            if (err == std.mem.Allocator.Error.OutOfMemory or err == error.Panic) {
                if (err == error.Panic) {
                    if (!std.mem.eql(u8, "not enough memory", panic_msg))
                        @panic(panic_msg);
                    std.heap.c_allocator.free(panic_msg);
                    panic_msg = "";
                }

                palloc.progress();
                continue;
            }

            return err;
        };

        break;
    }
}

/// Recoverable panic function called by lua. This should be used in tests only.
fn recoverableLuaPanic(lua: ?*z.c.lua_State) callconv(.c) c_int {
    std.debug.assert(builtin.is_test);

    const th = z.State.initFromCPointer(lua.?);

    if (th.popAnyType([]const u8)) |msg| {
        panic_msg = std.heap.c_allocator.dupe(u8, msg) catch @panic("OOM");
        recover.panic.call(panic_msg, @returnAddress());
    } else {
        recover.panic.call("lua panic", @returnAddress());
    }
    return 0;
}

fn recoverGetGlobalValue(state: z.State, name: [*c]const u8) !z.Value {
    std.debug.assert(builtin.is_test);

    return recover.call(struct {
        fn getGlobalAnyType(st: z.State, n: [*c]const u8) z.Value {
            return st.globalRef().get(n, z.Value).?;
        }
    }.getGlobalAnyType, .{ state, name });
}

/// ProgressiveAllocator is a wrapper around [std.heap.DebugAllocator] that
/// tracks requested memory. This enables progressively incrementing memory
/// limit until a test succeed.
const ProgressiveAllocator = struct {
    const Self = @This();

    dbg: std.heap.DebugAllocator(.{ .enable_memory_limit = true }),
    requested: usize = 0,

    pub fn init() Self {
        var dbg =
            std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
        dbg.requested_memory_limit = 0;
        return .{ .dbg = dbg };
    }

    pub fn deinit(self: *Self) void {
        _ = self.dbg.detectLeaks();
        _ = self.dbg.deinit();
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn progress(self: *Self) void {
        _ = self.dbg.deinit();
        self.dbg =
            std.heap.DebugAllocator(.{ .enable_memory_limit = true }).init;
        self.dbg.requested_memory_limit = self.requested;
        self.requested = 0;
    }

    pub fn alloc(
        ptr: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.requested += len;

        const dalloc = self.dbg.allocator();
        return dalloc.rawAlloc(len, alignment, ret_addr);
    }

    pub fn resize(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.requested += new_len - memory.len;

        const dalloc = self.dbg.allocator();
        return dalloc.rawResize(
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    pub fn remap(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.requested += new_len - memory.len;

        const dalloc = self.dbg.allocator();
        return dalloc.rawRemap(
            memory,
            alignment,
            new_len,
            ret_addr,
        );
    }

    pub fn free(
        ptr: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const dalloc = self.dbg.allocator();
        return dalloc.rawFree(
            memory,
            alignment,
            ret_addr,
        );
    }
};

test "State.init" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = null,
            });
            state.deinit();
        }
    }.testCase);
}

test "State.newThread" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = try recoverCall(z.State.newThread, .{state});
            try testing.expect(!thread.isMain());
            try testing.expectEqual(0, thread.top());
            try testing.expectEqual(.ok, thread.status());
        }
    }.testCase);
}

test "State.pushAnyType/Thread.popAnyType/Thread.valueType" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            // Bool.
            {
                try recoverCall(z.State.pushAnyType, .{ state, true });
                try testing.expectEqual(state.valueType(-1), .boolean);
                try testing.expectEqual(true, state.popAnyType(bool));

                try recoverCall(z.State.pushAnyType, .{ state, false });
                try testing.expectEqual(state.valueType(-1), .boolean);
                try testing.expectEqual(false, state.popAnyType(bool));
            }

            // Function.
            {
                const ns = struct {
                    fn cfn(_: ?*z.c.lua_State) callconv(.c) c_int {
                        return 0;
                    }
                    fn zfn(_: z.State) c_int {
                        return 0;
                    }
                };

                try recoverCall(z.State.pushAnyType, .{ state, &ns.cfn });
                try testing.expectEqual(state.valueType(-1), .function);
                try testing.expectEqual(
                    z.FunctionRef.init(z.ValueRef.init(state, state.top())),
                    state.toAnyType(-1, z.FunctionRef),
                );
                state.pop(1);

                try recoverCall(z.State.pushAnyType, .{ state, ns.zfn });
                try testing.expectEqual(state.valueType(-1), .function);
                try testing.expectEqual(
                    z.FunctionRef.init(z.ValueRef.init(state, state.top())),
                    state.toAnyType(-1, z.FunctionRef),
                );
                state.pop(1);
            }

            // State / c.lua_State
            {
                try recoverCall(z.State.pushAnyType, .{ state, state });
                try testing.expectEqual(state.valueType(-1), .thread);
                try testing.expectEqual(
                    state,
                    state.popAnyType(z.State),
                );

                try recoverCall(z.State.pushAnyType, .{ state, state.lua });
                try testing.expectEqual(state.valueType(-1), .thread);
                try testing.expectEqual(
                    state.lua,
                    state.popAnyType(*z.c.lua_State),
                );

                try recoverCall(z.State.pushAnyType, .{ state, state.lua });
                try testing.expectEqual(state.valueType(-1), .thread);
                try testing.expectEqual(
                    state,
                    state.popAnyType(z.State),
                );
            }

            // Strings.
            {
                try recoverCall(z.State.pushAnyType, .{
                    state, @as([]const u8, "foo bar baz"),
                });
                try recoverCall(z.State.pushAnyType, .{
                    state, @as([:0]const u8, "foo bar baz"),
                });
                try recoverCall(z.State.pushAnyType, .{ state, "foo bar baz" });
                try testing.expectEqual(state.valueType(-1), .string);
                try testing.expectEqualStrings(
                    "foo bar baz",
                    state.popAnyType([]const u8).?,
                );

                try recoverCall(z.State.pushAnyType, .{ state, @as(f64, 1) });
                try testing.expectEqualStrings(
                    "1",
                    (try recoverCall(struct {
                        fn popString(th: z.State) ?[]const u8 {
                            return th.popAnyType([]const u8);
                        }
                    }.popString, .{state})).?,
                );
            }

            // Floats.
            {
                try recoverCall(
                    z.State.pushAnyType,
                    .{ state, @as(f32, 1) },
                );
                try testing.expectEqual(state.valueType(-1), .number);
                try testing.expectEqual(1, state.popAnyType(f32));

                try recoverCall(
                    z.State.pushAnyType,
                    .{ state, @as(f64, 1) },
                );
                try testing.expectEqual(state.valueType(-1), .number);
                try testing.expectEqual(1, state.popAnyType(f64));

                try recoverCall(z.State.pushAnyType, .{ state, @as(f32, 1) });
                try testing.expectEqual(state.valueType(-1), .number);
                try testing.expectEqual(1, state.popAnyType(f64));

                try recoverCall(z.State.pushAnyType, .{ state, @as(f64, 1) });
                try testing.expectEqual(state.valueType(-1), .number);
                try testing.expectEqual(1, state.popAnyType(f32));
            }

            // Light userdata.
            {
                const pi: f64 = std.math.pi;
                const piPtr: *anyopaque = @ptrCast(@constCast(&pi));
                try recoverCall(z.State.pushAnyType, .{ state, piPtr });
                try testing.expectEqual(
                    state.valueType(-1),
                    .lightuserdata,
                );
                try testing.expectEqual(piPtr, state.popAnyType(*anyopaque).?);
            }

            // User data.
            {
                const UserData = struct {
                    a: i32,
                };

                _ = try recoverCall(struct {
                    pub fn newUserData(th: z.State) *UserData {
                        const ptr = th.newUserData(UserData);
                        ptr.a = 10;
                        return ptr;
                    }
                }.newUserData, .{state});

                const udata: *UserData = state.toAnyType(-1, *UserData).?;
                try testing.expectEqual(10, udata.a);
            }

            // Pointers.
            {
                const pi: f64 = std.math.pi;
                try recoverCall(z.State.pushAnyType, .{ state, pi });
                try testing.expectEqual(state.valueType(-1), .number);
                try testing.expectEqual(pi, state.popAnyType(f64));
            }

            // Value.
            {
                const value: z.Value = .{ .number = std.math.pi };
                try recoverCall(z.State.pushAnyType, .{ state, value });
                try testing.expectEqual(state.valueType(-1), .number);
                try testing.expectEqual(
                    value,
                    state.popAnyType(z.Value),
                );

                try recoverCall(z.State.pushAnyType, .{ state, value });
                try testing.expectEqual(state.valueType(-1), .number);
                try testing.expectEqual(
                    value.number,
                    state.popAnyType(f64),
                );
            }
        }
    }.testCase);
}

test "State.error" {
    var state = try z.State.init(.{});
    defer state.deinit();

    const zfunc = struct {
        pub fn zfunc(th: z.State) f64 {
            th.pushString("a runtime error");
            th.@"error"();
        }
    }.zfunc;

    state.pushCFunction(z.wrapFn(zfunc));
    state.pCall(0, 0, 0) catch {
        try testing.expectEqualStrings(
            "a runtime error",
            state.popAnyType([]const u8).?,
        );
        return;
    };

    unreachable;
}

test "State.raiseError" {
    var state = try z.State.init(.{});
    defer state.deinit();

    const zfunc = struct {
        pub fn zfunc(th: z.State) f64 {
            th.raiseError(error.OutOfMemory);
        }
    }.zfunc;

    state.pushCFunction(z.wrapFn(zfunc));
    state.pCall(0, 0, 0) catch {
        try testing.expectEqualStrings(
            "OutOfMemory",
            state.popAnyType([]const u8).?,
        );
        return;
    };

    unreachable;
}

test "State.concat" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushNumber, .{ state, 100 });
            try recoverCall(z.State.pushString, .{ state, " foo" });
            try recoverCall(z.State.concat, .{ state, 2 });
            try testing.expectEqualStrings(
                "100 foo",
                state.popAnyType([]const u8).?,
            );
        }
    }.testCase);
}

test "State.next" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.newTable, .{state});
            const idx = state.top();

            try recoverCall(z.State.pushInteger, .{ state, 1 });
            try recoverCall(z.State.rawSeti, .{ state, idx, 1 });

            try recoverCall(z.State.pushInteger, .{ state, 2 });
            try recoverCall(z.State.rawSeti, .{ state, idx, 2 });

            try recoverCall(z.State.pushInteger, .{ state, 3 });
            try recoverCall(z.State.rawSeti, .{ state, idx, 3 });

            var i: z.Integer = 0;
            state.pushNil(); // first key
            while (state.next(idx)) {
                i += 1;
                try testing.expectEqual(
                    i,
                    // removes 'value'; keeps 'key' for next iteration
                    state.popAnyType(z.Integer),
                );
                try testing.expectEqual(
                    i,
                    state.toAnyType(-1, z.Integer),
                );
            }

            try testing.expectEqual(3, i);
        }
    }.testCase);
}

test "State.top/Thread.setTop" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = null,
            });
            defer state.deinit();

            try testing.expectEqual(0, state.top());
            state.setTop(10);
            try testing.expectEqual(10, state.top());
        }
    }.testCase);
}

test "State.pushValue" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try testing.expectEqual(2, state.top());

            try recoverCall(z.State.pushValue, .{ state, -2 });
            try testing.expectEqual(3, state.top());

            try testing.expectEqual(
                @as(f64, std.math.pi),
                state.popAnyType(f64),
            );
            try testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                state.popAnyType([]const u8).?,
            );
            try testing.expectEqual(
                @as(f64, std.math.pi),
                state.popAnyType(f64),
            );
            try testing.expectEqual(0, state.top());
        }
    }.testCase);
}

test "State.remove" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try testing.expectEqual(2, state.top());

            state.remove(1);

            try testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                state.popAnyType([]const u8).?,
            );
            try testing.expectEqual(0, state.top());
        }
    }.testCase);
}

test "State.insert" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try testing.expectEqual(2, state.top());

            state.insert(1);

            try testing.expectEqual(
                @as(f64, std.math.pi),
                state.popAnyType(f64),
            );
            try testing.expectEqual(1, state.top());
        }
    }.testCase);
}

test "State.replace" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as(f64, std.math.pi),
            });
            try testing.expectEqual(1, state.top());

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try testing.expectEqual(2, state.top());

            state.replace(1);

            try testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                state.popAnyType([]const u8).?,
            );
            try testing.expectEqual(0, state.top());
        }
    }.testCase);
}

test "State.copy" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushString, .{ state, "foo bar baz" });
            try recoverCall(z.State.pushNumber, .{ state, 123 });

            state.copy(-1, -2);

            try testing.expectEqual(
                123,
                state.popAnyType(z.Number),
            );
            try testing.expectEqual(
                123,
                state.popAnyType(z.Number),
            );
        }
    }.testCase);
}

test "State.checkStack" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try testing.expect(state.checkStack(1));
            try testing.expect(!state.checkStack(400000000));
        }
    }.testCase);
}

test "State.xMove" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread2 = try recoverCall(z.State.newThread, .{state});

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            state.xMove(thread2, 1);

            try testing.expectEqualStrings(
                @as([]const u8, "foo bar baz"),
                thread2.popAnyType([]const u8).?,
            );
            try testing.expectEqual(0, thread2.top());
            try testing.expectEqual(1, state.top());
        }
    }.testCase);
}

test "State.equal" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 1));
            state.pushAnyType(@as(f64, 2));

            try testing.expect(!state.equal(1, 2));
            try testing.expect(state.equal(1, 1));
            try testing.expect(state.equal(2, 2));
        }
    }.testCase);
}

test "State.rawEqual" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 1));
            state.pushAnyType(@as(f64, 2));

            try testing.expect(!state.rawEqual(1, 2));
            try testing.expect(state.rawEqual(1, 1));
            try testing.expect(state.rawEqual(2, 2));
        }
    }.testCase);
}

test "State.lessThan" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 1));
            state.pushAnyType(@as(f64, 2));

            try testing.expect(state.lessThan(1, 2));
            try testing.expect(!state.lessThan(2, 1));
            try testing.expect(!state.lessThan(1, 1));
            try testing.expect(!state.lessThan(2, 2));
        }
    }.testCase);
}

test "State.valueType" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            state.pushAnyType(@as(f64, 3.14));
            try testing.expectEqual(
                .number,
                state.valueType(1),
            );
            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try testing.expectEqual(
                .string,
                state.valueType(2),
            );
        }
    }.testCase);
}

test "State.typeName" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try testing.expectEqualStrings(
                "boolean",
                std.mem.span(state.typeName(.boolean)),
            );
            try testing.expectEqualStrings(
                "number",
                std.mem.span(state.typeName(.number)),
            );
            try testing.expectEqualStrings(
                "function",
                std.mem.span(state.typeName(.function)),
            );
            try testing.expectEqualStrings(
                "string",
                std.mem.span(state.typeName(.string)),
            );
        }
    }.testCase);
}

test "State.getGlobal" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});
            try recoverCall(z.State.getGlobal, .{ state, "_G" });
            try recoverCall(z.State.getGlobal, .{ state, "_G" });
            try testing.expect(state.equal(-1, -2));
        }
    }.testCase);
}

test "State.getGlobalAnyType" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});

            const value = try recoverGetGlobalValue(state, "_G");
            _ = value.table;
        }
    }.testCase);
}

test "State.isXXX" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});

            try testing.expect(!state.isBoolean(z.Global));
            try testing.expect(!state.isCFunction(z.Global));
            try testing.expect(!state.isFunction(z.Global));
            try testing.expect(!state.isNil(z.Global));
            try testing.expect(!state.isNone(z.Global));
            try testing.expect(!state.isNoneOrNil(z.Global));
            try testing.expect(!state.isNumber(z.Global));
            try testing.expect(state.isTable(z.Global));
            try testing.expect(!state.isThread(z.Global));
            try testing.expect(!state.isUserData(z.Global));
            try testing.expect(!state.isLightUserData(z.Global));
        }
    }.testCase);
}

test "State.toXXX" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.openBase, .{state});

            try testing.expect(state.toBoolean(z.Global));
            try testing.expect(state.toCFunction(z.Global) == null);
            try testing.expect(state.toNumber(z.Global) == 0);
            try testing.expect(state.toState(z.Global) == null);
            try testing.expect(state.toUserData(z.Global, anyopaque) == null);
            try testing.expect(state.toPointer(z.Global) != null);
            try testing.expect(state.toString(z.Global) == null);
        }
    }.testCase);
}

test "State.objLen" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.pushAnyType, .{
                state,
                @as([]const u8, "foo bar baz"),
            });
            try testing.expectEqual(
                11,
                state.objLen(-1),
            );
        }
    }.testCase);
}

test "State.openXXX" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try testing.expect(
                try recoverGetGlobalValue(state, "_G") == .nil,
            );
            try testing.expect(
                try recoverGetGlobalValue(state, "coroutine") == .nil,
            );
            try recoverCall(z.State.openBase, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "_G") != .nil,
            );
            try testing.expect(
                try recoverGetGlobalValue(state, "coroutine") != .nil,
            );

            try testing.expect(
                try recoverGetGlobalValue(state, "package") == .nil,
            );
            try recoverCall(z.State.openPackage, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "package") != .nil,
            );

            try testing.expect(
                try recoverGetGlobalValue(state, "table") == .nil,
            );
            try recoverCall(z.State.openTable, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "table") != .nil,
            );

            try testing.expect(
                try recoverGetGlobalValue(state, "string") == .nil,
            );
            try recoverCall(z.State.openString, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "string") != .nil,
            );

            try testing.expect(
                try recoverGetGlobalValue(state, "io") == .nil,
            );
            try recoverCall(z.State.openIO, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "io") != .nil,
            );

            try testing.expect(
                try recoverGetGlobalValue(state, "os") == .nil,
            );
            try recoverCall(z.State.openOS, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "os") != .nil,
            );

            try testing.expect(
                try recoverGetGlobalValue(state, "math") == .nil,
            );
            try recoverCall(z.State.openMath, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "math") != .nil,
            );

            try testing.expect(
                try recoverGetGlobalValue(state, "debug") == .nil,
            );
            try recoverCall(z.State.openDebug, .{state});
            try testing.expect(
                try recoverGetGlobalValue(state, "debug") != .nil,
            );
        }
    }.testCase);
}

test "State.loadFile" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.loadFile, .{
                state,
                "src/testdata/add.lua",
            });
            try recoverCall(z.State.call, .{ state, 0, 0 });

            try recoverCall(z.State.getGlobal, .{ state, "add" });
            state.pushInteger(1);
            state.pushInteger(2);

            try recoverCall(z.State.call, .{ state, 2, 1 });
            try testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}

test "State.doFile" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.doFile, .{ state, "src/testdata/add.lua" });

            try recoverCall(z.State.getGlobal, .{ state, "add" });
            state.pushInteger(1);
            state.pushInteger(2);
            try recoverCall(z.State.call, .{ state, 2, 1 });
            try testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}

test "State.loadString" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try state.loadString("return 1 + 2", null);
            state.call(0, 1);
            try testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}

test "State.doString" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try state.doString("return 1 + 2", null);
            try testing.expectEqual(3, state.toInteger(-1));
        }
    }.testCase);
}

test "State.yield" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const thread = try recoverCall(z.State.newThread, .{state});
            try recoverCall(z.State.pushCFunction, .{
                thread, struct {
                    fn cfunc(lua: ?*z.c.lua_State) callconv(.c) c_int {
                        const th = z.State.initFromCPointer(lua.?);
                        return th.yield(0);
                    }
                }.cfunc,
            });

            const status = try thread.@"resume"(0);
            try testing.expectEqual(z.State.Status.yield, status);
        }
    }.testCase);
}

test "State.isYieldable" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try testing.expect(!state.isYieldable());

            const thread = try recoverCall(z.State.newThread, .{state});

            try recoverCall(z.State.pushCFunction, .{
                thread, z.wrapFn(struct {
                    fn zigFunc(th: z.State) bool {
                        return th.isYieldable();
                    }
                }.zigFunc),
            });

            _ = try thread.@"resume"(0);

            const yieldable = state.popAnyType(bool);
            try testing.expect(yieldable.?);
        }
    }.testCase);
}

test "wrapFn" {
    var state = try z.State.init(.{});
    defer state.deinit();

    const zfunc = z.wrapFn(struct {
        pub fn zfunc(th: z.State, a: f64, b: f64) !f64 {
            try testing.expectEqual(a, th.checkNumber(-2));
            try testing.expectEqual(b, th.checkNumber(-1));

            return a + b;
        }
    }.zfunc);

    state.pushCFunction(zfunc);
    state.pushInteger(1);
    state.pushInteger(2);
    state.call(2, 1);
    try testing.expectEqual(3, state.toInteger(-1));

    // Missing argument.
    state.pushCFunction(zfunc);
    state.pushInteger(1);
    var result = state.pCall(1, 1, 0);
    if (result) {
        unreachable;
    } else |err| {
        try testing.expectEqual(error.Runtime, err);
        try testing.expectEqualStrings(
            "bad argument #2 to '?' (number expected, got no value)",
            state.popAnyType([]const u8).?,
        );
    }

    // Return Zig error.
    state.pushCFunction(z.wrapFn(struct {
        fn fail() !void {
            return std.mem.Allocator.Error.OutOfMemory;
        }
    }.fail));
    result = state.pCall(0, 0, 0);
    if (result) {
        unreachable;
    } else |err| {
        try testing.expectEqual(error.Runtime, err);
        try testing.expectEqualStrings(
            "OutOfMemory",
            state.popAnyType([]const u8).?,
        );
    }

    // Thread arguments.
    state.pushCFunction(z.wrapFn(struct {
        fn thread1(st: z.State, thread: z.State) z.State {
            _ = thread;
            return st;
        }
    }.thread1));
    const thread = state.newThread();
    state.call(1, 1);
    try testing.expectEqual(state.lua, state.popAnyType(z.State).?.lua);
    try testing.expect(thread.lua != state.lua);

    // Thread arguments.
    state.pushCFunction(z.wrapFn(struct {
        fn thread1(st: z.State, th: z.State) z.State {
            _ = st;
            return th;
        }
    }.thread1));
    state.pushAnyType(thread);
    state.call(1, 1);
    try testing.expectEqual(thread.lua, state.popAnyType(z.State).?.lua);
}

test "newUserData" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const UserData = struct {
                a: i32,
            };

            _ = try recoverCall(struct {
                fn func(st: z.State) *UserData {
                    return st.newUserData(UserData);
                }
            }.func, .{state});
            _ = try recoverCall(z.State.checkValueType, .{
                state,
                -1,
                .userdata,
            });
        }
    }.testCase);
}

test "State.checkEnum" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const Enum = enum { foo, bar };
            const checkEnum = struct {
                fn checkEnum(th: z.State) Enum {
                    return th.checkEnum(-1, Enum, .foo);
                }
            }.checkEnum;

            try recoverCall(z.State.pushString, .{ state, "bar" });
            try testing.expectEqual(
                .bar,
                try recoverCall(checkEnum, .{state}),
            );

            state.pop(1);
            try testing.expectEqual(
                .foo,
                try recoverCall(checkEnum, .{state}),
            );
        }
    }.testCase);
}

test "State.testUserData" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const UserData = struct {
                pub const zluajitTName = "MyUserData";

                a: i32,
            };

            const funcs = struct {
                fn newUserData(th: z.State) *UserData {
                    const ud = th.newUserData(UserData);
                    _ = th.newMetaTable(UserData);
                    ud.a = 123;
                    return ud;
                }

                fn testUserData(th: z.State) !?*UserData {
                    try testing.expect(
                        th.testUserDataWithName(-1, UserData.zluajitTName, anyopaque) != null,
                    );
                    return th.testUserData(-1, UserData);
                }
            };

            _ = try recoverCall(funcs.newUserData, .{state});
            state.setMetaTable(-2);
            const ud = try recoverCall(funcs.testUserData, .{state});
            try testing.expectEqual(123, ud.?.a);
        }
    }.testCase);
}

test "State.checkUserData" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            const UserData = struct {
                pub const zluajitTName = "MyUserData";

                a: i32,
            };

            const funcs = struct {
                fn newUserData(th: z.State) *UserData {
                    const ud = th.newUserData(UserData);
                    _ = th.newMetaTable(UserData);
                    ud.a = 123;
                    return ud;
                }

                fn checkUserData(th: z.State) *UserData {
                    _ = th.checkUserDataWithName(-1, UserData.zluajitTName, anyopaque);
                    return th.checkUserData(-1, UserData);
                }
            };

            _ = try recoverCall(funcs.newUserData, .{state});
            state.setMetaTable(-2);
            const ud = try recoverCall(funcs.checkUserData, .{state});
            try testing.expectEqual(123, ud.a);
        }
    }.testCase);
}

test "TableRef.asMetaTableOf/TableRef.getMetaTable" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.newTable, .{state});
            try recoverCall(z.State.newTable, .{state});

            const tab = state.toAnyType(-1, z.TableRef).?;
            const mt = state.toAnyType(-2, z.TableRef).?;
            mt.asMetaTableOf(tab.ref.idx);

            try testing.expect(
                tab.getMetaTable().?.ref.toPointer() == mt.ref.toPointer(),
            );
        }
    }.testCase);
}

test "TableRef.getField/TableRef.setField" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.newTable, .{state});

            const tab = state.toAnyType(-1, z.TableRef).?;

            try recoverCall(z.TableRef.setField, .{ tab, "foo", true });
            try testing.expect(tab.getField("foo", bool).?);
        }
    }.testCase);
}

test "TableRef.get/TableRef.set" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            try recoverCall(z.State.newTable, .{state});

            const tab = state.toAnyType(-1, z.TableRef).?;

            try recoverCall(z.TableRef.set, .{ tab, state, true });
            try testing.expect(tab.get(state, bool).?);
        }
    }.testCase);
}

var ref: c_int = -1;

test "State.refValue/State.unref" {
    try withProgressiveAllocator(struct {
        fn testCase(alloc: *std.mem.Allocator) anyerror!void {
            var state = try z.State.init(.{
                .allocator = alloc,
                .panicHandler = recoverableLuaPanic,
            });
            defer state.deinit();

            // Create reference.
            try recoverCall(z.State.pushCFunction, .{
                state, struct {
                    fn cfunc(lua: ?*z.c.lua_State) callconv(.c) c_int {
                        const th = z.State.initFromCPointer(lua.?);
                        th.pushNumber(123);
                        ref = th.refValue(z.Registry, -1) catch unreachable;
                        th.pushInteger(ref);
                        return 1;
                    }
                }.cfunc,
            });
            state.call(0, 0);

            // Use & free reference.
            try recoverCall(z.State.pushCFunction, .{
                state, struct {
                    fn cfunc(lua: ?*z.c.lua_State) callconv(.c) c_int {
                        const th = z.State.initFromCPointer(lua.?);
                        th.pushInteger(ref);
                        th.rawGeti(z.Registry, ref);
                        testing.expectEqual(123, th.toInteger(-1)) catch unreachable;
                        th.unref(z.Registry, ref);
                        return 0;
                    }
                }.cfunc,
            });
            state.call(0, 0);

            // Reference doesn't exist anymore.
            try recoverCall(z.State.pushCFunction, .{
                state, struct {
                    fn cfunc(lua: ?*z.c.lua_State) callconv(.c) c_int {
                        const th = z.State.initFromCPointer(lua.?);
                        th.rawGeti(z.Registry, ref);
                        testing.expectEqual(0, th.toInteger(-1)) catch unreachable;
                        return 0;
                    }
                }.cfunc,
            });
            state.call(0, 0);
        }
    }.testCase);
}

test "State.dumpValue" {
    const state = try z.State.init(.{});

    const thread = try recoverCall(z.State.newThread, .{state});
    thread.newTable();
    const tab1 = thread.toAnyType(-1, z.TableRef).?;
    tab1.setField("foo", @as([]const u8, "bar"));
    tab1.setField("bar", @as([]const u8, "baz"));

    thread.newTable();
    const tab2 = thread.toAnyType(-1, z.TableRef).?;
    tab2.setField("parent", tab1);
    tab1.setField("inner", tab2);

    // state.dumpValue(-1);
}
