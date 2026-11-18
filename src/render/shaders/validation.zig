//! Compiler-only validation. Never creates GPU resources or changes the shader chain.
const std = @import("std");
const io = @import("../../io.zig");
const shadertoy = @import("shadertoy.zig");

pub const Code = enum {
    ok,
    invalid_argument,
    read_failed,
    resource_exhausted,
    shader_invalid,
    translation_failed,
    out_of_memory,
};

pub const Result = struct {
    valid: bool = false,
    code: Code,
    log: shadertoy.Log = .{},

    pub fn failure(code: Code, message: []const u8) Result {
        var result: Result = .{ .code = code };
        result.log.set(message);
        return result;
    }
};

pub fn validateFile(allocator: std.mem.Allocator, path: []const u8, target: shadertoy.Target) Result {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null)
        return Result.failure(.invalid_argument, "expected a non-empty shader file path without NUL bytes");
    if (path.len > 32 * 1024)
        return Result.failure(.resource_exhausted, "shader path exceeds 32 KiB");

    const source = std.Io.Dir.cwd().readFileAlloc(io.get(), path, allocator, .limited(shadertoy.max_source_bytes)) catch |err| {
        return switch (err) {
            error.StreamTooLong => Result.failure(.resource_exhausted, "shader source exceeds 256 KiB"),
            error.OutOfMemory => Result.failure(.out_of_memory, "not enough memory to read shader"),
            else => Result.failure(.read_failed, @errorName(err)),
        };
    };
    defer allocator.free(source);
    if (std.mem.indexOfScalar(u8, source, 0) != null)
        return Result.failure(.shader_invalid, "shader source contains NUL bytes");

    var log: shadertoy.Log = .{};
    const fragment = shadertoy.compileFragment(allocator, source, target, &log) catch |err| {
        if (log.len == 0) log.set(@errorName(err));
        return .{
            .code = switch (err) {
                error.ShaderInvalid => .shader_invalid,
                error.TranslationFailed => .translation_failed,
                error.ResourceExhausted => .resource_exhausted,
                error.OutOfMemory => .out_of_memory,
            },
            .log = log,
        };
    };
    defer allocator.free(fragment);
    return .{ .valid = true, .code = .ok };
}

test "shader validation compiles files for both backends and reports missing mainImage" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "shader.glsl", .data = "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }" });
    const path = try tmp.dir.realPathFileAlloc(io.get(), "shader.glsl", allocator);
    defer allocator.free(path);
    for ([_]shadertoy.Target{ .glsl, .hlsl }) |target| {
        const valid = validateFile(allocator, path, target);
        try std.testing.expect(valid.valid);
        try std.testing.expectEqual(Code.ok, valid.code);
        try std.testing.expectEqual(@as(usize, 0), valid.log.len);

        try tmp.dir.writeFile(io.get(), .{ .sub_path = "shader.glsl", .data = "vec4 color = vec4(1.0);" });
        const missing_main = validateFile(allocator, path, target);
        try std.testing.expect(!missing_main.valid);
        try std.testing.expectEqual(Code.shader_invalid, missing_main.code);
        try std.testing.expect(std.mem.indexOf(u8, missing_main.log.slice(), "mainImage") != null);
        try tmp.dir.writeFile(io.get(), .{ .sub_path = "shader.glsl", .data = "void mainImage(out vec4 c, in vec2 p) { c = texture(iChannel0, p / iResolution.xy); }" });
    }
}

test "shader validation returns bounded diagnostics for bad source and file errors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "shader.glsl", .data = "void mainImage(out vec4 c, in vec2 p) {\n c = nope;\n}" });
    const path = try tmp.dir.realPathFileAlloc(io.get(), "shader.glsl", allocator);
    defer allocator.free(path);
    const invalid = validateFile(allocator, path, .hlsl);
    try std.testing.expectEqual(Code.shader_invalid, invalid.code);
    try std.testing.expect(std.mem.indexOf(u8, invalid.log.slice(), "0:2:") != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid.log.slice(), "nope") != null);

    try tmp.dir.writeFile(io.get(), .{ .sub_path = "shader.glsl", .data = "invalid\x00source" });
    try std.testing.expectEqual(Code.shader_invalid, validateFile(allocator, path, .glsl).code);
    const big = try allocator.alloc(u8, shadertoy.max_source_bytes + 1);
    defer allocator.free(big);
    @memset(big, ' ');
    try tmp.dir.writeFile(io.get(), .{ .sub_path = "shader.glsl", .data = big });
    try std.testing.expectEqual(Code.resource_exhausted, validateFile(allocator, path, .glsl).code);
    try tmp.dir.deleteFile(io.get(), "shader.glsl");
    const missing = validateFile(allocator, path, .glsl);
    try std.testing.expectEqual(Code.read_failed, missing.code);
    try std.testing.expect(missing.log.len > 0);
    try std.testing.expectEqual(Code.invalid_argument, validateFile(allocator, "", .glsl).code);
    try std.testing.expectEqual(Code.invalid_argument, validateFile(allocator, "a\x00b", .glsl).code);
    try std.testing.expectEqual(Code.resource_exhausted, validateFile(allocator, big[0 .. 32 * 1024 + 1], .glsl).code);
}
