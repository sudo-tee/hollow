//! Ghostty-compatible Shadertoy shaders: source prefix, uniform packing and
//! GLSL → SPIR-V → HLSL translation.
//!
//! Users write `mainImage(out vec4, in vec2)` against Ghostty's uniform names.
//! Ghostty's uniform block has more members than sokol's GL backend accepts,
//! so Hollow packs the scalar and vector uniforms into `hollow_globals` slots
//! and maps the public names to them with macros. Both backends share the
//! macros: D3D11 wraps the uniforms in a std140 block compiled by glslang and
//! SPIRV-Cross; GL passes the source through with plain uniforms.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("shaderc_c");

pub const Target = enum { glsl, hlsl };
pub const native_target: Target = if (builtin.target.os.tag == .windows) .hlsl else .glsl;

/// D3D11 and Metal put +Y down in fragment coordinates; GL puts it up.
/// Shaders see the native convention, as in Ghostty.
pub fn yIsDown(target: Target) bool {
    return target == .hlsl;
}

pub const max_source_bytes = 256 * 1024;
pub const max_log_bytes = 4096;
pub const slot_count = 16;

pub const CursorStyle = enum(i32) {
    block = 0,
    block_hollow = 1,
    bar = 2,
    underline = 3,
    lock = 4,
};

const macros =
    \\#define iResolution hollow_globals[0].xyz
    \\#define iTime hollow_globals[0].w
    \\#define iTimeDelta hollow_globals[1].x
    \\#define iFrameRate hollow_globals[1].y
    \\#define iFrame int(hollow_globals[1].z)
    \\#define iSampleRate hollow_globals[1].w
    \\#define iMouse hollow_globals[2]
    \\#define iDate hollow_globals[3]
    \\#define iCurrentCursor hollow_globals[4]
    \\#define iPreviousCursor hollow_globals[5]
    \\#define iCurrentCursorColor hollow_globals[6]
    \\#define iPreviousCursorColor hollow_globals[7]
    \\#define iCurrentCursorStyle int(hollow_globals[8].x)
    \\#define iPreviousCursorStyle int(hollow_globals[8].y)
    \\#define iCursorVisible int(hollow_globals[8].z)
    \\#define iTimeCursorChange hollow_globals[8].w
    \\#define iTimeFocus hollow_globals[9].x
    \\#define iFocus int(hollow_globals[9].y)
    \\#define iBackgroundColor hollow_globals[10].xyz
    \\#define iForegroundColor hollow_globals[11].xyz
    \\#define iCursorColor hollow_globals[12].xyz
    \\#define iCursorText hollow_globals[13].xyz
    \\#define iSelectionForegroundColor hollow_globals[14].xyz
    \\#define iSelectionBackgroundColor hollow_globals[15].xyz
    \\
    \\#define CURSORSTYLE_BLOCK        0
    \\#define CURSORSTYLE_BLOCK_HOLLOW 1
    \\#define CURSORSTYLE_BAR          2
    \\#define CURSORSTYLE_UNDERLINE    3
    \\#define CURSORSTYLE_LOCK         4
    \\
    \\#define texture2D texture
    \\
    \\void mainImage(out vec4 fragColor, in vec2 fragCoord);
    \\#define hollow_layer_opacity hollow_globals[9].z
    \\#define hollow_window_alpha hollow_globals[9].w
    \\void main() {
    \\    mainImage(_fragColor, gl_FragCoord.xy);
    \\    // Background layers ignore the shader's alpha. Colour is premultiplied
    \\    // by the window alpha; alpha is the coverage of the clear colour.
    \\    if (hollow_layer_opacity > 0.0) _fragColor = vec4(_fragColor.rgb * hollow_layer_opacity * hollow_window_alpha, hollow_layer_opacity);
    \\}
    \\#line 1
    \\
;

// `HOLLOW_Y_DOWN` follows the version line, so the prefixes are split.
const block_version = "#version 430 core\n";
const block_prefix =
    \\layout(std140, binding = 0) uniform Globals {
    \\    vec4 hollow_globals[16];
    \\    float iChannelTime[4];
    \\    vec3 iChannelResolution[4];
    \\    vec3 iPalette[256];
    \\};
    \\layout(binding = 0) uniform sampler2D iChannel0;
    \\layout(location = 0) out vec4 _fragColor;
    \\
++ macros;

// Linux requests a GL 3.3 core context.
const plain_version = "#version 330 core\n";
const plain_prefix =
    \\uniform vec4 hollow_globals[16];
    \\uniform float iChannelTime[4];
    \\uniform vec3 iChannelResolution[4];
    \\uniform vec3 iPalette[256];
    \\uniform sampler2D iChannel0;
    \\out vec4 _fragColor;
    \\
++ macros;

/// Full-screen triangle without vertex buffers.
pub const vertex_source = struct {
    pub const glsl: [:0]const u8 =
        \\#version 330 core
        \\void main() {
        \\    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
        \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
        \\}
    ;
    pub const hlsl: [:0]const u8 =
        \\float4 main(uint vid : SV_VertexID) : SV_Position {
        \\    float2 p = float2((vid << 1) & 2, vid & 2);
        \\    return float4(p * 2.0 - 1.0, 0.0, 1.0);
        \\}
    ;
};

/// Logical uniform values, in Ghostty's units: pixels, seconds, 0..1 colours.
pub const Uniforms = struct {
    resolution: [2]f32 = .{ 0, 0 },
    time: f32 = 0,
    time_delta: f32 = 0,
    frame_rate: f32 = 0,
    frame: u32 = 0,
    date: [4]f32 = .{ 0, 0, 0, 0 },
    current_cursor: [4]f32 = .{ 0, 0, 0, 0 },
    previous_cursor: [4]f32 = .{ 0, 0, 0, 0 },
    current_cursor_color: [4]f32 = .{ 0, 0, 0, 0 },
    previous_cursor_color: [4]f32 = .{ 0, 0, 0, 0 },
    current_cursor_style: CursorStyle = .block,
    previous_cursor_style: CursorStyle = .block,
    cursor_visible: bool = false,
    time_cursor_change: f32 = 0,
    time_focus: f32 = 0,
    focus: bool = true,
    background: [3]f32 = .{ 0, 0, 0 },
    foreground: [3]f32 = .{ 1, 1, 1 },
    cursor_color: [3]f32 = .{ 1, 1, 1 },
    cursor_text: [3]f32 = .{ 0, 0, 0 },
    selection_foreground: [3]f32 = .{ 0, 0, 0 },
    selection_background: [3]f32 = .{ 1, 1, 1 },
    palette: [256][3]f32 = std.mem.zeroes([256][3]f32),
    /// Non-zero for background layers, which replace the clear colour by
    /// this fraction. Not part of Ghostty's interface.
    layer_opacity: f32 = 0,
    /// Alpha of the clear colour under a background layer.
    window_alpha: f32 = 1,

    fn slots(self: *const Uniforms) [slot_count][4]f32 {
        const f = struct {
            fn rgb(v: [3]f32) [4]f32 {
                return .{ v[0], v[1], v[2], 1 };
            }
            fn flag(v: bool) f32 {
                return if (v) 1 else 0;
            }
        };
        return .{
            .{ self.resolution[0], self.resolution[1], 1, self.time },
            .{ self.time_delta, self.frame_rate, @floatFromInt(self.frame), 0 },
            .{ 0, 0, 0, 0 },
            self.date,
            self.current_cursor,
            self.previous_cursor,
            self.current_cursor_color,
            self.previous_cursor_color,
            .{
                @floatFromInt(@intFromEnum(self.current_cursor_style)),
                @floatFromInt(@intFromEnum(self.previous_cursor_style)),
                f.flag(self.cursor_visible),
                self.time_cursor_change,
            },
            .{ self.time_focus, f.flag(self.focus), self.layer_opacity, self.window_alpha },
            f.rgb(self.background),
            f.rgb(self.foreground),
            f.rgb(self.cursor_color),
            f.rgb(self.cursor_text),
            f.rgb(self.selection_foreground),
            f.rgb(self.selection_background),
        };
    }

    pub fn packStd140(self: *const Uniforms, out: *Std140) void {
        out.globals = self.slots();
        for (&out.channel_time) |*v| v.* = .{ self.time, 0, 0, 0 };
        for (&out.channel_resolution) |*v| v.* = .{ 0, 0, 0, 0 };
        out.channel_resolution[0] = .{ self.resolution[0], self.resolution[1], 1, 0 };
        for (&out.palette, self.palette) |*dst, src| dst.* = .{ src[0], src[1], src[2], 0 };
    }

    pub fn packNative(self: *const Uniforms, out: *Native) void {
        out.globals = self.slots();
        out.channel_time = @splat(self.time);
        out.channel_resolution = std.mem.zeroes([4][3]f32);
        out.channel_resolution[0] = .{ self.resolution[0], self.resolution[1], 1 };
        out.palette = self.palette;
    }
};

/// D3D11 cbuffer layout of the `Globals` block.
pub const Std140 = extern struct {
    globals: [slot_count][4]f32,
    channel_time: [4][4]f32,
    channel_resolution: [4][4]f32,
    palette: [256][4]f32,
};

/// sokol GL `SG_UNIFORMLAYOUT_NATIVE` layout of the plain uniforms.
pub const Native = extern struct {
    globals: [slot_count][4]f32,
    channel_time: [4]f32,
    channel_resolution: [4][3]f32,
    palette: [256][3]f32,
};

/// Bounded compiler diagnostics.
pub const Log = struct {
    buf: [max_log_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Log) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Log, msg: []const u8) void {
        const trimmed = std.mem.trim(u8, msg, " \r\n\x00");
        self.len = @min(trimmed.len, self.buf.len);
        @memcpy(self.buf[0..self.len], trimmed[0..self.len]);
    }
};

pub const Error = error{ ResourceExhausted, ShaderInvalid, TranslationFailed, OutOfMemory };

var process_initialized = false;

/// Translates a user shader to fragment source for `target`. The result is
/// owned by `alloc`. Errors leave a message in `log`.
fn yDefine(target: Target) []const u8 {
    return if (yIsDown(target)) "#define HOLLOW_Y_DOWN 1\n" else "#define HOLLOW_Y_DOWN 0\n";
}

pub fn compileFragment(alloc: std.mem.Allocator, user_source: []const u8, target: Target, log: *Log) Error![:0]u8 {
    log.len = 0;
    if (user_source.len > max_source_bytes) {
        log.set("shader source exceeds 256 KiB");
        return error.ResourceExhausted;
    }
    // GL also validates through glslang so both backends report the same
    // diagnostics, then hands the driver the original source.
    const block_src = try std.mem.concatWithSentinel(alloc, u8, &.{ block_version, yDefine(target), block_prefix, user_source }, 0);
    defer alloc.free(block_src);
    const spirv = try spirvFromGlsl(alloc, block_src, log);
    defer alloc.free(spirv);
    return switch (target) {
        .glsl => std.mem.concatWithSentinel(alloc, u8, &.{ plain_version, yDefine(target), plain_prefix, user_source }, 0),
        .hlsl => hlslFromSpirv(alloc, spirv, log),
    };
}

fn spirvFromGlsl(alloc: std.mem.Allocator, src: [:0]const u8, log: *Log) Error![]u32 {
    if (!process_initialized) {
        if (c.glslang_initialize_process() == 0) return error.TranslationFailed;
        process_initialized = true;
    }
    const input: c.glslang_input_t = .{
        .language = c.GLSLANG_SOURCE_GLSL,
        .stage = c.GLSLANG_STAGE_FRAGMENT,
        .client = c.GLSLANG_CLIENT_VULKAN,
        .client_version = c.GLSLANG_TARGET_VULKAN_1_2,
        .target_language = c.GLSLANG_TARGET_SPV,
        .target_language_version = c.GLSLANG_TARGET_SPV_1_5,
        .code = src.ptr,
        .default_version = 100,
        .default_profile = c.GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = 0,
        .forward_compatible = 0,
        .messages = c.GLSLANG_MSG_DEFAULT_BIT,
        .resource = c.glslang_default_resource(),
    };
    const shader = c.glslang_shader_create(&input) orelse return error.OutOfMemory;
    defer c.glslang_shader_delete(shader);
    if (c.glslang_shader_preprocess(shader, &input) == 0 or c.glslang_shader_parse(shader, &input) == 0) {
        log.set(std.mem.span(c.glslang_shader_get_info_log(shader)));
        return error.ShaderInvalid;
    }
    const program = c.glslang_program_create() orelse return error.OutOfMemory;
    defer c.glslang_program_delete(program);
    c.glslang_program_add_shader(program, shader);
    if (c.glslang_program_link(program, c.GLSLANG_MSG_SPV_RULES_BIT | c.GLSLANG_MSG_VULKAN_RULES_BIT) == 0) {
        log.set(std.mem.span(c.glslang_program_get_info_log(program)));
        return error.ShaderInvalid;
    }
    c.glslang_program_SPIRV_generate(program, c.GLSLANG_STAGE_FRAGMENT);
    const words = c.glslang_program_SPIRV_get_size(program);
    const ptr = c.glslang_program_SPIRV_get_ptr(program) orelse return error.TranslationFailed;
    return alloc.dupe(u32, ptr[0..words]);
}

fn hlslFromSpirv(alloc: std.mem.Allocator, spirv: []const u32, log: *Log) Error![:0]u8 {
    var ctx: c.spvc_context = null;
    if (c.spvc_context_create(&ctx) != c.SPVC_SUCCESS) return error.OutOfMemory;
    defer c.spvc_context_destroy(ctx);
    errdefer log.set(std.mem.span(c.spvc_context_get_last_error_string(ctx)));

    var ir: c.spvc_parsed_ir = null;
    if (c.spvc_context_parse_spirv(ctx, spirv.ptr, spirv.len, &ir) != c.SPVC_SUCCESS) return error.TranslationFailed;
    var compiler: c.spvc_compiler = null;
    if (c.spvc_context_create_compiler(ctx, c.SPVC_BACKEND_HLSL, ir, c.SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler) != c.SPVC_SUCCESS)
        return error.TranslationFailed;
    var options: c.spvc_compiler_options = null;
    if (c.spvc_compiler_create_compiler_options(compiler, &options) != c.SPVC_SUCCESS or
        c.spvc_compiler_options_set_uint(options, c.SPVC_COMPILER_OPTION_HLSL_SHADER_MODEL, 50) != c.SPVC_SUCCESS or
        c.spvc_compiler_install_compiler_options(compiler, options) != c.SPVC_SUCCESS)
        return error.TranslationFailed;
    var out: [*c]const u8 = null;
    if (c.spvc_compiler_compile(compiler, &out) != c.SPVC_SUCCESS) return error.TranslationFailed;
    return alloc.dupeSentinel(u8, std.mem.span(out), 0);
}

const testing = std.testing;

const cursor_shader =
    \\void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    \\    vec2 uv = fragCoord / iResolution.xy;
    \\    vec4 color = texture(iChannel0, uv);
    \\    if (iCursorVisible == 1 && iCurrentCursorStyle == CURSORSTYLE_BLOCK) {
    \\        color.rgb = mix(color.rgb, iCurrentCursorColor.rgb, 0.5 * iTimeCursorChange);
    \\    }
    \\    fragColor = vec4(color.rgb + iPalette[1] * 0.0, color.a);
    \\}
;

test "shadertoy: translates a cursor shader to HLSL" {
    var log: Log = .{};
    const hlsl = try compileFragment(testing.allocator, cursor_shader, .hlsl, &log);
    defer testing.allocator.free(hlsl);
    try testing.expect(std.mem.indexOf(u8, hlsl, "register(b0)") != null);
    try testing.expect(std.mem.indexOf(u8, hlsl, "register(t0)") != null);
    try testing.expect(std.mem.indexOf(u8, hlsl, "register(s0)") != null);
    try testing.expect(std.mem.indexOf(u8, hlsl, "SV_Position") != null);
}

test "shadertoy: GL keeps the user source after the plain prefix" {
    var log: Log = .{};
    const glsl = try compileFragment(testing.allocator, cursor_shader, .glsl, &log);
    defer testing.allocator.free(glsl);
    try testing.expect(std.mem.startsWith(u8, glsl, "#version 330 core\n#define HOLLOW_Y_DOWN 0\nuniform vec4 hollow_globals[16];"));
    try testing.expect(std.mem.endsWith(u8, glsl, cursor_shader));
}

test "shadertoy: reports errors at user source lines" {
    var log: Log = .{};
    const src = "void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n    fragColor = nope;\n}\n";
    try testing.expectError(error.ShaderInvalid, compileFragment(testing.allocator, src, .hlsl, &log));
    try testing.expect(std.mem.indexOf(u8, log.slice(), "0:2:") != null);
    try testing.expect(std.mem.indexOf(u8, log.slice(), "nope") != null);
}

test "shadertoy: rejects oversized sources" {
    var log: Log = .{};
    const big = try testing.allocator.alloc(u8, max_source_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, ' ');
    try testing.expectError(error.ResourceExhausted, compileFragment(testing.allocator, big, .glsl, &log));
}

test "shadertoy: packs uniforms for both layouts" {
    try testing.expectEqual(@as(usize, 4480), @sizeOf(Std140));
    try testing.expectEqual(@as(usize, 3392), @sizeOf(Native));
    var u: Uniforms = .{ .resolution = .{ 800, 600 }, .time = 2, .frame = 7, .cursor_visible = true, .current_cursor_style = .bar, .layer_opacity = 0.5, .window_alpha = 0.8 };
    u.palette[1] = .{ 1, 0.5, 0.25 };
    var std140: Std140 = undefined;
    u.packStd140(&std140);
    try testing.expectEqual([4]f32{ 800, 600, 1, 2 }, std140.globals[0]);
    try testing.expectEqual(@as(f32, 7), std140.globals[1][2]);
    try testing.expectEqual([4]f32{ 2, 0, 1, 0 }, .{ std140.globals[8][0], std140.globals[8][1], std140.globals[8][2], std140.globals[8][3] });
    try testing.expectEqual(@as(f32, 0.5), std140.globals[9][2]);
    try testing.expectEqual(@as(f32, 0.8), std140.globals[9][3]);
    try testing.expectEqual([4]f32{ 1, 0.5, 0.25, 0 }, std140.palette[1]);
    var native: Native = undefined;
    u.packNative(&native);
    try testing.expectEqual([3]f32{ 1, 0.5, 0.25 }, native.palette[1]);
    try testing.expectEqual([3]f32{ 800, 600, 1 }, native.channel_resolution[0]);
}

test "shadertoy: shipped example shaders compile" {
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "examples/shaders", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".glsl")) continue;
        const source = try dir.readFileAlloc(io, entry.name, testing.allocator, .limited(max_source_bytes));
        defer testing.allocator.free(source);
        var log: Log = .{};
        const hlsl = compileFragment(testing.allocator, source, .hlsl, &log) catch |err| {
            std.debug.print("{s}: {s}\n", .{ entry.name, log.slice() });
            return err;
        };
        testing.allocator.free(hlsl);
        count += 1;
    }
    try testing.expect(count >= 3);
}
