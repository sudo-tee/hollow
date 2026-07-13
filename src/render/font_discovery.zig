/// System font discovery, loading, and enumeration.
///
/// Contains all the platform-specific font lookup logic (DirectWrite on
/// Windows, filesystem search on Linux/macOS), the FreeType face loading
/// helpers, and the public enumeration entry point
/// (`listAvailableFontsDetailed`).
///
/// Depends on `font_config.zig` for the shared types (`RequestedFontStyle`,
/// `FontDiscoveryMatch`, `FontFamilyInfo`, `SeenFontFamilies`, …) and
/// `normalizeFontToken`.

const std = @import("std");
const builtin = @import("builtin");
const ft = @import("ft_c");

const font_config = @import("font_config.zig");

const RequestedFontStyle = font_config.RequestedFontStyle;
const FontDiscoveryMatch = font_config.FontDiscoveryMatch;
const FontFamilyInfo = font_config.FontFamilyInfo;
const FontFaceInfo = font_config.FontFaceInfo;
const SeenFontFamilies = font_config.SeenFontFamilies;
const SeenFontFamilyDetails = font_config.SeenFontFamilyDetails;
const normalizeFontToken = font_config.normalizeFontToken;

// ── DirectWrite bindings (Windows only) ──────────────────────────────────────

const dwrite = if (builtin.os.tag == .windows) struct {
    const HollowDWriteFontMatch = extern struct {
        face_index: u32,
        path: [1024]u8,
    };

    const HollowDWriteFontFamilyCallback = *const fn (family_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int;
    const HollowDWriteFontFaceCallback = *const fn (family_utf8: [*:0]const u8, style_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int;

    extern fn hollow_dwrite_match_font(family_utf8: [*:0]const u8, want_bold: c_int, want_italic: c_int, out_match: *HollowDWriteFontMatch) c_int;
    extern fn hollow_dwrite_list_font_families(callback: HollowDWriteFontFamilyCallback, ctx: ?*anyopaque) c_int;
    extern fn hollow_dwrite_list_font_faces(callback: HollowDWriteFontFaceCallback, ctx: ?*anyopaque) c_int;
} else struct {};

// ── FreeType face loading ────────────────────────────────────────────────────

pub fn loadFace(lib: ft.FT_Library, data: []const u8, size_px: f32) !ft.FT_Face {
    var face: ft.FT_Face = null;
    const err = ft.FT_New_Memory_Face(
        lib,
        data.ptr,
        @intCast(data.len),
        0,
        &face,
    );
    if (err != 0 or face == null) return error.FtLoadFaceFailed;
    const px: c_uint = @intFromFloat(@round(size_px));
    if (ft.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FtSetSizeFailed;
    return face;
}

pub fn discoverEmojiFont(allocator: std.mem.Allocator, lib: ft.FT_Library, size_px: f32) ?ft.FT_Face {
    const known_emoji_names = [_][]const u8{
        "Noto Color Emoji",
        "Segoe UI Emoji",
        "Apple Color Emoji",
        "EmojiOne Color",
        "JoyPixels",
    };
    for (known_emoji_names) |name| {
        if (discoverSystemFont(allocator, lib, name, .regular)) |match| {
            defer allocator.free(match.path);
            if (loadFaceFromPathIndex(allocator, lib, match.path, match.face_index, size_px)) |face| {
                return face;
            } else |_| continue;
        } else |_| continue;
    }
    const fallback_paths = [_][]const u8{
        "/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
        "/usr/local/share/fonts/NotoColorEmoji.ttf",
    };
    for (fallback_paths) |path| {
        if (loadFaceFromPath(allocator, lib, path, size_px)) |face| {
            return face;
        } else |_| continue;
    }
    return null;
}

pub fn loadConfiguredFace(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    family: ?[]const u8,
    spec: ?[]const u8,
    style: RequestedFontStyle,
    embedded: []const u8,
    size_px: f32,
) !ft.FT_Face {
    if (spec) |value| {
        return loadFaceFromSpec(allocator, lib, value, style, size_px) catch loadFace(lib, embedded, size_px);
    }
    if (family) |value| {
        return loadFaceByName(allocator, lib, value, style, size_px) catch loadFace(lib, embedded, size_px);
    }
    return loadFace(lib, embedded, size_px);
}

pub fn loadFaceFromPath(allocator: std.mem.Allocator, lib: ft.FT_Library, path: []const u8, size_px: f32) !ft.FT_Face {
    return loadFaceFromPathIndex(allocator, lib, path, 0, size_px);
}

pub fn loadFaceFromPathIndex(allocator: std.mem.Allocator, lib: ft.FT_Library, path: []const u8, face_index: c_long, size_px: f32) !ft.FT_Face {
    const zpath = try allocator.dupeZ(u8, path);
    defer allocator.free(zpath);

    var face: ft.FT_Face = null;
    const err = ft.FT_New_Face(lib, zpath.ptr, face_index, &face);
    if (err != 0 or face == null) return error.FtLoadFaceFailed;
    errdefer _ = ft.FT_Done_Face(face);

    const px: c_uint = @intFromFloat(@round(size_px));
    if (ft.FT_Set_Pixel_Sizes(face, 0, px) != 0) return error.FtSetSizeFailed;
    return face;
}

pub fn loadFaceFromSpec(allocator: std.mem.Allocator, lib: ft.FT_Library, spec: []const u8, style: RequestedFontStyle, size_px: f32) !ft.FT_Face {
    return loadFaceFromPath(allocator, lib, spec, size_px) catch loadFaceByName(allocator, lib, spec, style, size_px);
}

pub fn loadFaceByName(allocator: std.mem.Allocator, lib: ft.FT_Library, name: []const u8, style: RequestedFontStyle, size_px: f32) !ft.FT_Face {
    const match = try discoverSystemFont(allocator, lib, name, style);
    defer allocator.free(match.path);
    return loadFaceFromPathIndex(allocator, lib, match.path, match.face_index, size_px);
}

// ── System font discovery ────────────────────────────────────────────────────

pub fn discoverSystemFont(allocator: std.mem.Allocator, lib: ft.FT_Library, name: []const u8, style: RequestedFontStyle) !FontDiscoveryMatch {
    if (builtin.os.tag == .windows) {
        return discoverWindowsFontWithDirectWrite(allocator, name, style);
    }

    var best: ?FontDiscoveryMatch = null;
    errdefer if (best) |match| allocator.free(match.path);

    switch (builtin.os.tag) {
        .windows => unreachable,
        .macos => {
            try searchFontDir(allocator, lib, "/System/Library/Fonts", name, style, &best);
            try searchFontDir(allocator, lib, "/Library/Fonts", name, style, &best);
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                const user_fonts = try std.fs.path.join(allocator, &.{ home, "Library", "Fonts" });
                defer allocator.free(user_fonts);
                try searchFontDir(allocator, lib, user_fonts, name, style, &best);
            } else |_| {}
        },
        else => {
            try searchFontDir(allocator, lib, "/usr/share/fonts", name, style, &best);
            try searchFontDir(allocator, lib, "/usr/local/share/fonts", name, style, &best);
            if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                const local_share_fonts = try std.fs.path.join(allocator, &.{ home, ".local", "share", "fonts" });
                defer allocator.free(local_share_fonts);
                try searchFontDir(allocator, lib, local_share_fonts, name, style, &best);
                const dot_fonts = try std.fs.path.join(allocator, &.{ home, ".fonts" });
                defer allocator.free(dot_fonts);
                try searchFontDir(allocator, lib, dot_fonts, name, style, &best);
            } else |_| {}
        },
    }

    return best orelse error.FontNotFound;
}

// ── Public enumeration API ───────────────────────────────────────────────────

pub fn listAvailableFontsDetailed(allocator: std.mem.Allocator) ![]FontFamilyInfo {
    var seen = SeenFontFamilyDetails{ .allocator = allocator };
    errdefer seen.deinit();

    if (builtin.os.tag == .windows) {
        try collectWindowsFontFaces(&seen);
    } else {
        var ft_lib: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FtInitFailed;
        defer _ = ft.FT_Done_FreeType(ft_lib);

        switch (builtin.os.tag) {
            .macos => {
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/System/Library/Fonts", &seen);
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/Library/Fonts", &seen);
                if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                    defer allocator.free(home);
                    const user_fonts = try std.fs.path.join(allocator, &.{ home, "Library", "Fonts" });
                    defer allocator.free(user_fonts);
                    try collectFontFaceDetailsFromDir(allocator, ft_lib, user_fonts, &seen);
                } else |_| {}
            },
            else => {
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/usr/share/fonts", &seen);
                try collectFontFaceDetailsFromDir(allocator, ft_lib, "/usr/local/share/fonts", &seen);
                if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
                    defer allocator.free(home);
                    const local_share_fonts = try std.fs.path.join(allocator, &.{ home, ".local", "share", "fonts" });
                    defer allocator.free(local_share_fonts);
                    try collectFontFaceDetailsFromDir(allocator, ft_lib, local_share_fonts, &seen);
                    const dot_fonts = try std.fs.path.join(allocator, &.{ home, ".fonts" });
                    defer allocator.free(dot_fonts);
                    try collectFontFaceDetailsFromDir(allocator, ft_lib, dot_fonts, &seen);
                } else |_| {}
            },
        }
    }

    return try seen.toOwnedSlice(allocator);
}

// ── Windows-specific discovery ───────────────────────────────────────────────

fn discoverWindowsFontWithDirectWrite(allocator: std.mem.Allocator, name: []const u8, style: RequestedFontStyle) !FontDiscoveryMatch {
    if (builtin.os.tag != .windows) return error.FontNotFound;

    if (try matchWindowsFontWithDirectWrite(allocator, name, style)) |match| {
        if (isPlausibleWindowsFontPath(match.path)) {
            return match;
        }
        allocator.free(match.path);
    }

    if (try discoverWindowsFontFromFilesystem(allocator, name, style)) |match| {
        return match;
    }

    const resolved_name = try resolveWindowsFontFamilyAlias(allocator, name) orelse return error.FontNotFound;
    defer allocator.free(resolved_name);

    if (try matchWindowsFontWithDirectWrite(allocator, resolved_name, style)) |match| {
        if (isPlausibleWindowsFontPath(match.path)) {
            return match;
        }
        allocator.free(match.path);
    }

    return try discoverWindowsFontFromFilesystem(allocator, resolved_name, style) orelse error.FontNotFound;
}

fn discoverWindowsFontFromFilesystem(allocator: std.mem.Allocator, name: []const u8, style: RequestedFontStyle) !?FontDiscoveryMatch {
    if (builtin.os.tag != .windows) return null;

    var ft_lib: ft.FT_Library = null;
    if (ft.FT_Init_FreeType(&ft_lib) != 0) return error.FtInitFailed;
    defer _ = ft.FT_Done_FreeType(ft_lib);

    var best: ?FontDiscoveryMatch = null;
    errdefer if (best) |match| allocator.free(match.path);
    try searchFontDir(allocator, ft_lib, "C:\\Windows\\Fonts", name, style, &best);

    if (std.process.getEnvVarOwned(allocator, "LOCALAPPDATA")) |local_app_data| {
        defer allocator.free(local_app_data);
        const user_fonts = try std.fs.path.join(allocator, &.{ local_app_data, "Microsoft", "Windows", "Fonts" });
        defer allocator.free(user_fonts);
        try searchFontDir(allocator, ft_lib, user_fonts, name, style, &best);
    } else |_| {}

    return best;
}

fn matchWindowsFontWithDirectWrite(allocator: std.mem.Allocator, name: []const u8, style: RequestedFontStyle) !?FontDiscoveryMatch {
    if (builtin.os.tag != .windows) return null;

    const family_z = try allocator.dupeZ(u8, name);
    defer allocator.free(family_z);

    var match: dwrite.HollowDWriteFontMatch = std.mem.zeroes(dwrite.HollowDWriteFontMatch);
    const result = dwrite.hollow_dwrite_match_font(
        family_z.ptr,
        if (style == .bold or style == .bold_italic) 1 else 0,
        if (style == .italic or style == .bold_italic) 1 else 0,
        &match,
    );
    if (result == 0) return null;

    const path_len = std.mem.indexOfScalar(u8, &match.path, 0) orelse match.path.len;
    if (path_len == 0) return null;

    return .{
        .path = try allocator.dupe(u8, match.path[0..path_len]),
        .face_index = @intCast(match.face_index),
        .score = 1,
    };
}

fn resolveWindowsFontFamilyAlias(allocator: std.mem.Allocator, requested: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return null;

    var seen = SeenFontFamilies{ .allocator = allocator };
    defer seen.deinit();
    try collectWindowsFontFamilies(&seen);

    var best_name: ?[]const u8 = null;
    var best_score: i32 = std.math.minInt(i32);
    for (seen.names.items) |family_name| {
        const score = scoreWindowsFontFamilyName(requested, family_name);
        if (score > best_score) {
            best_score = score;
            best_name = family_name;
        }
    }

    if (best_name == null or best_score == std.math.minInt(i32)) return null;
    return try allocator.dupe(u8, best_name.?);
}

pub fn scoreWindowsFontFamilyName(requested: []const u8, candidate: []const u8) i32 {
    var requested_buf: [256]u8 = undefined;
    const requested_normalized = normalizeFontToken(&requested_buf, requested);
    if (requested_normalized.len == 0) return std.math.minInt(i32);

    var candidate_buf: [256]u8 = undefined;
    const candidate_normalized = normalizeFontToken(&candidate_buf, candidate);
    if (candidate_normalized.len == 0) return std.math.minInt(i32);

    if (std.mem.eql(u8, requested_normalized, candidate_normalized)) return 1000;

    var score: i32 = std.math.minInt(i32);
    if (containsToken(candidate_normalized, requested_normalized)) {
        score = 820;
    } else if (containsToken(requested_normalized, candidate_normalized)) {
        score = 760;
    } else {
        return std.math.minInt(i32);
    }

    const prefix_len = sharedPrefixLen(requested_normalized, candidate_normalized);
    const len_delta: usize = if (candidate_normalized.len > requested_normalized.len)
        candidate_normalized.len - requested_normalized.len
    else
        requested_normalized.len - candidate_normalized.len;
    score += @as(i32, @intCast(prefix_len * 4));
    score -= @as(i32, @intCast(@min(len_delta, 64)));
    return score;
}

fn sharedPrefixLen(a: []const u8, b: []const u8) usize {
    const max_len = @min(a.len, b.len);
    var index: usize = 0;
    while (index < max_len and a[index] == b[index]) : (index += 1) {}
    return index;
}

pub fn isPlausibleWindowsFontPath(path: []const u8) bool {
    if (path.len < 7) return false;
    if (!std.unicode.utf8ValidateSlice(path)) return false;
    const has_drive = std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    const has_unc = std.mem.startsWith(u8, path, "\\\\");
    if (!has_drive and !has_unc) return false;
    if (!isFontFile(path)) return false;
    return true;
}

fn collectWindowsFontFamilies(seen: *SeenFontFamilies) !void {
    if (builtin.os.tag != .windows) return;

    const CallbackState = struct {
        seen: *SeenFontFamilies,
        failed: ?anyerror = null,
    };

    const callback = struct {
        fn run(family_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int {
            const state: *CallbackState = @ptrCast(@alignCast(ctx orelse return 0));
            const family = std.mem.span(family_utf8);
            state.seen.add(family) catch |err| {
                state.failed = err;
                return 0;
            };
            return 1;
        }
    }.run;

    var state = CallbackState{ .seen = seen };
    const ok = dwrite.hollow_dwrite_list_font_families(callback, &state);
    if (state.failed) |err| return err;
    if (ok == 0) return error.FontEnumerationFailed;
}

fn collectWindowsFontFaces(seen: *SeenFontFamilyDetails) !void {
    if (builtin.os.tag != .windows) return;

    const CallbackState = struct {
        seen: *SeenFontFamilyDetails,
        failed: ?anyerror = null,
    };

    const callback = struct {
        fn run(family_utf8: [*:0]const u8, style_utf8: [*:0]const u8, ctx: ?*anyopaque) callconv(.c) c_int {
            const state: *CallbackState = @ptrCast(@alignCast(ctx orelse return 0));
            state.seen.add(std.mem.span(family_utf8), std.mem.span(style_utf8)) catch |err| {
                state.failed = err;
                return 0;
            };
            return 1;
        }
    }.run;

    var state = CallbackState{ .seen = seen };
    const ok = dwrite.hollow_dwrite_list_font_faces(callback, &state);
    if (state.failed) |err| return err;
    if (ok == 0) return error.FontEnumerationFailed;
}

// ── Filesystem search helpers ────────────────────────────────────────────────

fn searchFontDir(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    root_path: []const u8,
    name: []const u8,
    style: RequestedFontStyle,
    best: *?FontDiscoveryMatch,
) !void {
    var dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(child_path);
                try searchFontDir(allocator, lib, child_path, name, style, best);
            },
            .file, .sym_link => {
                if (!isFontFile(entry.name)) continue;

                const file_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(file_path);

                if (try scoreFontFile(allocator, lib, file_path, name, style)) |candidate| {
                    if (best.*) |*current| {
                        if (candidate.score <= current.score) {
                            allocator.free(candidate.path);
                            continue;
                        }
                        allocator.free(current.path);
                    }
                    best.* = candidate;
                }
            },
            else => {},
        }
    }
}

fn collectFontFamiliesFromDir(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    root_path: []const u8,
    seen: *SeenFontFamilies,
) !void {
    var dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(child_path);
                try collectFontFamiliesFromDir(allocator, lib, child_path, seen);
            },
            .file, .sym_link => {
                if (!isFontFile(entry.name)) continue;

                const file_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(file_path);
                try collectFontFamiliesFromFile(allocator, lib, file_path, seen);
            },
            else => {},
        }
    }
}

fn collectFontFaceDetailsFromDir(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    root_path: []const u8,
    seen: *SeenFontFamilyDetails,
) !void {
    var dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.AccessDenied => return,
        else => return err,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(child_path);
                try collectFontFaceDetailsFromDir(allocator, lib, child_path, seen);
            },
            .file, .sym_link => {
                if (!isFontFile(entry.name)) continue;

                const file_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
                defer allocator.free(file_path);
                try collectFontFaceDetailsFromFile(allocator, lib, file_path, seen);
            },
            else => {},
        }
    }
}

fn collectFontFaceDetailsFromFile(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    file_path: []const u8,
    seen: *SeenFontFamilyDetails,
) !void {
    const zpath = try allocator.dupeZ(u8, file_path);
    defer allocator.free(zpath);

    var probe_face: ft.FT_Face = null;
    const probe_err = ft.FT_New_Face(lib, zpath.ptr, 0, &probe_face);
    if (probe_err != 0 or probe_face == null) return;
    const face_count: usize = @intCast(@max(probe_face.*.num_faces, 1));
    _ = ft.FT_Done_Face(probe_face);

    var face_index: usize = 0;
    while (face_index < face_count) : (face_index += 1) {
        var face: ft.FT_Face = null;
        const err = ft.FT_New_Face(lib, zpath.ptr, @intCast(face_index), &face);
        if (err != 0 or face == null) continue;
        defer _ = ft.FT_Done_Face(face);

        const family = faceFamilyName(face);
        const style = faceStyleName(face);
        if (family.len > 0) try seen.add(family, style);
    }
}

fn collectFontFamiliesFromFile(allocator: std.mem.Allocator, lib: ft.FT_Library, file_path: []const u8, seen: *SeenFontFamilies) !void {
    const zpath = try allocator.dupeZ(u8, file_path);
    defer allocator.free(zpath);

    var probe_face: ft.FT_Face = null;
    const probe_err = ft.FT_New_Face(lib, zpath.ptr, 0, &probe_face);
    if (probe_err != 0 or probe_face == null) return;
    const face_count: usize = @intCast(@max(probe_face.*.num_faces, 1));
    _ = ft.FT_Done_Face(probe_face);

    var face_index: usize = 0;
    while (face_index < face_count) : (face_index += 1) {
        var face: ft.FT_Face = null;
        const err = ft.FT_New_Face(lib, zpath.ptr, @intCast(face_index), &face);
        if (err != 0 or face == null) continue;
        defer _ = ft.FT_Done_Face(face);

        const family = faceFamilyName(face);
        if (family.len > 0) try seen.add(family);
    }
}

// ── Font scoring ─────────────────────────────────────────────────────────────

fn scoreFontFile(
    allocator: std.mem.Allocator,
    lib: ft.FT_Library,
    file_path: []const u8,
    name: []const u8,
    style: RequestedFontStyle,
) !?FontDiscoveryMatch {
    const zpath = try allocator.dupeZ(u8, file_path);
    defer allocator.free(zpath);

    var probe_face: ft.FT_Face = null;
    const probe_err = ft.FT_New_Face(lib, zpath.ptr, 0, &probe_face);
    if (probe_err != 0 or probe_face == null) return null;
    const face_count: usize = @intCast(@max(probe_face.*.num_faces, 1));
    _ = ft.FT_Done_Face(probe_face);

    var best_score: i32 = std.math.minInt(i32);
    var best_index: c_long = 0;
    var face_index: usize = 0;
    while (face_index < face_count) : (face_index += 1) {
        var face: ft.FT_Face = null;
        const err = ft.FT_New_Face(lib, zpath.ptr, @intCast(face_index), &face);
        if (err != 0 or face == null) continue;
        defer _ = ft.FT_Done_Face(face);

        const score = scoreDiscoveredFace(face, file_path, name, style);
        if (score > best_score) {
            best_score = score;
            best_index = @intCast(face_index);
        }
    }

    if (best_score == std.math.minInt(i32)) return null;
    return .{
        .path = try allocator.dupe(u8, file_path),
        .face_index = best_index,
        .score = best_score,
    };
}

fn scoreDiscoveredFace(face: ft.FT_Face, file_path: []const u8, name: []const u8, style: RequestedFontStyle) i32 {
    var wanted_buf: [256]u8 = undefined;
    const wanted = normalizeFontToken(&wanted_buf, name);
    if (wanted.len == 0) return std.math.minInt(i32);

    var family_buf: [256]u8 = undefined;
    const family = normalizeFontToken(&family_buf, faceFamilyName(face));

    var style_buf: [256]u8 = undefined;
    const style_name = normalizeFontToken(&style_buf, faceStyleName(face));

    var basename_buf: [256]u8 = undefined;
    const basename = normalizeFontToken(&basename_buf, std.fs.path.stem(std.fs.path.basename(file_path)));

    const family_match = family.len > 0 and std.mem.eql(u8, family, wanted);
    const basename_match = basename.len > 0 and std.mem.eql(u8, basename, wanted);
    const loose_match = (family.len > 0 and (containsToken(family, wanted) or containsToken(wanted, family))) or
        (basename.len > 0 and (containsToken(basename, wanted) or containsToken(wanted, basename)));

    if (!family_match and !basename_match and !loose_match) return std.math.minInt(i32);

    var score: i32 = 0;
    if (family_match) score += 1000;
    if (basename_match) score += 900;
    if (!family_match and !basename_match and loose_match) score += 700;
    if ((face.*.face_flags & ft.FT_FACE_FLAG_SCALABLE) != 0) score += 25;
    score += styleMatchScore(face, style_name, style);
    return score;
}

fn styleMatchScore(face: ft.FT_Face, style_name: []const u8, style: RequestedFontStyle) i32 {
    const bold = faceIsBold(face, style_name);
    const italic = faceIsItalic(face, style_name);

    return switch (style) {
        .regular => 220 - boolPenalty(bold) - boolPenalty(italic) + regularNameBonus(style_name),
        .bold => 170 + boolBonus(bold) - boolPenalty(italic),
        .italic => 170 - boolPenalty(bold) + boolBonus(italic),
        .bold_italic => 120 + boolBonus(bold) + boolBonus(italic),
    };
}

fn boolBonus(value: bool) i32 {
    return if (value) 60 else -80;
}

fn boolPenalty(value: bool) i32 {
    return if (value) 80 else 0;
}

fn regularNameBonus(style_name: []const u8) i32 {
    if (style_name.len == 0) return 0;
    if (containsToken(style_name, "regular") or containsToken(style_name, "book") or containsToken(style_name, "roman")) return 20;
    return 0;
}

fn faceIsBold(face: ft.FT_Face, style_name: []const u8) bool {
    return (face.*.style_flags & ft.FT_STYLE_FLAG_BOLD) != 0 or containsToken(style_name, "bold") or containsToken(style_name, "semibold") or containsToken(style_name, "demibold");
}

fn faceIsItalic(face: ft.FT_Face, style_name: []const u8) bool {
    return (face.*.style_flags & ft.FT_STYLE_FLAG_ITALIC) != 0 or containsToken(style_name, "italic") or containsToken(style_name, "oblique");
}

fn faceFamilyName(face: ft.FT_Face) []const u8 {
    if (face.*.family_name) |ptr| return std.mem.span(ptr);
    return "";
}

fn faceStyleName(face: ft.FT_Face) []const u8 {
    if (face.*.style_name) |ptr| return std.mem.span(ptr);
    return "";
}

fn containsToken(haystack: []const u8, needle: []const u8) bool {
    return needle.len > 0 and std.mem.indexOf(u8, haystack, needle) != null;
}

// ── Font-file extension check ────────────────────────────────────────────────

pub fn isFontFile(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(ext, ".ttf") or
        std.ascii.eqlIgnoreCase(ext, ".otf") or
        std.ascii.eqlIgnoreCase(ext, ".ttc") or
        std.ascii.eqlIgnoreCase(ext, ".otc");
}

// ── Glyph coverage probing (used by font fallback selection) ─────────────────

pub fn fontLikelySupportsText(face: ft.FT_Face, utf8: []const u8) bool {
    const cp = firstRenderableCodepoint(utf8) orelse return true;
    return ft.FT_Get_Char_Index(face, cp) != 0;
}

pub fn firstRenderableCodepoint(utf8: []const u8) ?u32 {
    var view = std.unicode.Utf8View.init(utf8) catch return null;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        if (isIgnorableCodepoint(cp)) continue;
        return cp;
    }
    return null;
}

pub fn isIgnorableCodepoint(cp: u32) bool {
    return switch (cp) {
        0x200C, 0x200D, 0xFE0E, 0xFE0F => true,
        0x0300...0x036F => true,
        else => false,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "windows font family alias scoring prefers closest superset" {
    try std.testing.expect(scoreWindowsFontFamilyName("Yu Gothic U", "Yu Gothic UI") > scoreWindowsFontFamilyName("Yu Gothic U", "Yu Gothic"));
}

test "windows font family alias scoring rejects unrelated families" {
    try std.testing.expectEqual(std.math.minInt(i32), scoreWindowsFontFamilyName("Yu Gothic U", "Consolas"));
}

test "isFontFile: recognises common font extensions" {
    try std.testing.expect(isFontFile("Arial.ttf"));
    try std.testing.expect(isFontFile("Arial.OTF"));
    try std.testing.expect(isFontFile("NotoSans.ttc"));
    try std.testing.expect(!isFontFile("readme.txt"));
    try std.testing.expect(!isFontFile("font"));
}

test "containsToken: substring match" {
    try std.testing.expect(containsToken("Yu Gothic UI", "Gothic"));
    try std.testing.expect(containsToken("Gothic", "Gothic"));
    try std.testing.expect(!containsToken("Consolas", "Gothic"));
    try std.testing.expect(!containsToken("", "x"));
}

test "sharedPrefixLen: common prefix" {
    try std.testing.expectEqual(@as(usize, 0), sharedPrefixLen("abc", "xyz"));
    try std.testing.expectEqual(@as(usize, 3), sharedPrefixLen("abc", "abc"));
    try std.testing.expectEqual(@as(usize, 2), sharedPrefixLen("abcd", "abef"));
}

test "isIgnorableCodepoint: zero-width joiner and variation selectors" {
    try std.testing.expect(isIgnorableCodepoint(0x200C)); // ZWNJ
    try std.testing.expect(isIgnorableCodepoint(0x200D)); // ZWJ
    try std.testing.expect(isIgnorableCodepoint(0xFE0E)); // variation selector-15
    try std.testing.expect(isIgnorableCodepoint(0xFE0F)); // variation selector-16
    try std.testing.expect(isIgnorableCodepoint(0x0300)); // combining grave
    try std.testing.expect(isIgnorableCodepoint(0x036F)); // last combining diacritic
    try std.testing.expect(!isIgnorableCodepoint(0x0041)); // 'A'
    try std.testing.expect(!isIgnorableCodepoint(0x0370)); // just past combining block
}

test "firstRenderableCodepoint: skips ignorable codepoints" {
    // "A" alone → returns 'A'
    try std.testing.expectEqual(@as(?u32, 0x41), firstRenderableCodepoint("A"));
    // ZWJ followed by "B" → returns 'B' (ZWJ is ignorable)
    try std.testing.expectEqual(@as(?u32, 0x42), firstRenderableCodepoint("\u{200D}B"));
    // Empty string → null
    try std.testing.expectEqual(@as(?u32, null), firstRenderableCodepoint(""));
}

test "isPlausibleWindowsFontPath: rejects non-Windows paths" {
    if (builtin.os.tag != .windows) return;
    try std.testing.expect(!isPlausibleWindowsFontPath("/usr/share/fonts/arial.ttf"));
    try std.testing.expect(!isPlausibleWindowsFontPath("arial.ttf"));
}
