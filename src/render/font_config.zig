/// Font configuration types and font-family enumeration builders.
///
/// Contains the renderer-facing config struct (`FtRendererConfig`), the style /
/// discovery types used by the font loader, and the deduplicating builders
/// (`SeenFontFamilies`, `SeenFontFamilyDetails`) that collect family / style
/// names during font enumeration.
///
/// No dependency on FreeType, HarfBuzz, sokol, or the `FtRenderer` struct.

const std = @import("std");

// ── Renderer-facing font configuration ───────────────────────────────────────

pub const FtRendererConfig = struct {
    pub const Smoothing = enum {
        grayscale,
        subpixel,
    };

    pub const Hinting = enum {
        none,
        light,
        normal,
    };

    font_size: f32 = 18.0,
    dpi_scale: f32 = 1.0,
    line_height: f32 = 1.0,
    padding_x: f32 = 0.0,
    padding_y: f32 = 0.0,
    coverage_boost: f32 = 1.0,
    coverage_add: f32 = 0.0,
    smoothing: Smoothing = .grayscale,
    hinting: Hinting = .normal,
    ligatures: bool = true,
    embolden: f32 = 0.0,
    regular_embolden: ?f32 = null,
    bold_embolden: ?f32 = null,
    italic_embolden: ?f32 = null,
    bold_italic_embolden: ?f32 = null,
    /// Enable perceptual luminance-based alpha correction (Ghostty-style).
    /// Produces gamma-correct text blending without requiring an sRGB framebuffer.
    /// Disabled by default — simple fg*coverage matches WezTerm on dark backgrounds.
    use_linear_correction: bool = false,
    family: ?[]const u8 = null,
    regular_path: ?[]const u8 = null,
    bold_path: ?[]const u8 = null,
    italic_path: ?[]const u8 = null,
    bold_italic_path: ?[]const u8 = null,
    fallback_paths: []const []const u8 = &.{},
};

// ── Style / discovery types ──────────────────────────────────────────────────

pub const RequestedFontStyle = enum {
    regular,
    bold,
    italic,
    bold_italic,
};

pub const FontDiscoveryMatch = struct {
    path: []u8,
    face_index: c_long,
    score: i32,
};

pub const FontFaceInfo = struct {
    style: []u8,
};

pub const FontFamilyInfo = struct {
    family: []u8,
    styles: []FontFaceInfo,

    pub fn deinit(self: *FontFamilyInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        for (self.styles) |style| allocator.free(style.style);
        allocator.free(self.styles);
        self.* = undefined;
    }
};

// ── Font-name normalisation ──────────────────────────────────────────────────

/// Normalise a font name for comparison: lowercase, strip non-alphanumeric
/// characters, truncate to `buf.len`.  Returns the normalised slice within
/// `buf`.
pub fn normalizeFontToken(buf: []u8, input: []const u8) []const u8 {
    var len: usize = 0;
    for (input) |ch| {
        if (!std.ascii.isAlphanumeric(ch)) continue;
        if (len == buf.len) break;
        buf[len] = std.ascii.toLower(ch);
        len += 1;
    }
    return buf[0..len];
}

// ── Deduplicating enumeration builders ───────────────────────────────────────

pub const SeenFontFamilies = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]u8) = .empty,
    normalized: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *SeenFontFamilies) void {
        for (self.names.items) |name| self.allocator.free(name);
        self.names.deinit(self.allocator);
        var it = self.normalized.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.normalized.deinit(self.allocator);
    }

    pub fn add(self: *SeenFontFamilies, name: []const u8) !void {
        if (name.len == 0) return;

        var normalized_buf: [256]u8 = undefined;
        const normalized_name = normalizeFontToken(&normalized_buf, name);
        if (normalized_name.len == 0) return;
        if (self.normalized.contains(normalized_name)) return;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_key = try self.allocator.dupe(u8, normalized_name);
        errdefer self.allocator.free(owned_key);

        try self.names.append(self.allocator, owned_name);
        errdefer _ = self.names.pop();
        try self.normalized.put(self.allocator, owned_key, {});
    }
};

pub const SeenFontFamilyDetails = struct {
    allocator: std.mem.Allocator,
    families: std.ArrayListUnmanaged(FontFamilyInfoBuilder) = .empty,
    normalized_map: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *SeenFontFamilyDetails) void {
        for (self.families.items) |*family| family.deinit(self.allocator);
        self.families.deinit(self.allocator);
        var it = self.normalized_map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.normalized_map.deinit(self.allocator);
    }

    pub fn add(self: *SeenFontFamilyDetails, family_name: []const u8, style_name: []const u8) !void {
        if (family_name.len == 0) return;

        var normalized_buf: [256]u8 = undefined;
        const normalized = normalizeFontToken(&normalized_buf, family_name);
        if (normalized.len == 0) return;

        if (self.normalized_map.get(normalized)) |index| {
            try self.families.items[index].addStyle(self.allocator, style_name);
            return;
        }
    }

    pub fn toOwnedSlice(self: *SeenFontFamilyDetails, allocator: std.mem.Allocator) ![]FontFamilyInfo {
        std.mem.sort(FontFamilyInfoBuilder, self.families.items, {}, struct {
            fn lessThan(_: void, a: FontFamilyInfoBuilder, b: FontFamilyInfoBuilder) bool {
                return std.ascii.lessThanIgnoreCase(a.family, b.family);
            }
        }.lessThan);

        const result = try allocator.alloc(FontFamilyInfo, self.families.items.len);
        for (self.families.items, 0..) |*family, i| result[i] = try family.toOwnedInfo(allocator);
        return result;
    }
};

pub const FontFamilyInfoBuilder = struct {
    family: []u8,
    styles: std.ArrayListUnmanaged([]u8) = .empty,
    normalized_styles: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator, family_name: []const u8, style_name: []const u8) !FontFamilyInfoBuilder {
        var builder = FontFamilyInfoBuilder{ .family = try allocator.dupe(u8, family_name) };
        errdefer allocator.free(builder.family);
        try builder.addStyle(allocator, style_name);
        return builder;
    }

    pub fn deinit(self: *FontFamilyInfoBuilder, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        for (self.styles.items) |style| allocator.free(style);
        self.styles.deinit(allocator);
        var it = self.normalized_styles.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.normalized_styles.deinit(allocator);
    }

    pub fn addStyle(self: *FontFamilyInfoBuilder, allocator: std.mem.Allocator, style_name: []const u8) !void {
        const style = if (style_name.len == 0) "Regular" else style_name;

        var normalized_buf: [256]u8 = undefined;
        const normalized = normalizeFontToken(&normalized_buf, style);
        if (normalized.len == 0) return;
        if (self.normalized_styles.contains(normalized)) return;

        const owned_style = try allocator.dupe(u8, style);
        errdefer allocator.free(owned_style);
        const owned_key = try allocator.dupe(u8, normalized);
        errdefer allocator.free(owned_key);

        try self.styles.append(allocator, owned_style);
        errdefer _ = self.styles.pop();
        try self.normalized_styles.put(allocator, owned_key, {});
    }

    pub fn toOwnedInfo(self: *FontFamilyInfoBuilder, allocator: std.mem.Allocator) !FontFamilyInfo {
        std.mem.sort([]u8, self.styles.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.ascii.lessThanIgnoreCase(a, b);
            }
        }.lessThan);

        const family = try allocator.dupe(u8, self.family);
        errdefer allocator.free(family);
        const styles = try allocator.alloc(FontFaceInfo, self.styles.items.len);
        errdefer allocator.free(styles);
        for (self.styles.items, 0..) |style, i| {
            styles[i] = .{ .style = try allocator.dupe(u8, style) };
        }
        return .{ .family = family, .styles = styles };
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "normalizeFontToken: strips non-alphanumeric and lowercases" {
    var buf: [256]u8 = undefined;
    const result = normalizeFontToken(&buf, "Yu Gothic UI");
    try std.testing.expectEqualStrings("yugothicui", result);
}

test "normalizeFontToken: empty input" {
    var buf: [256]u8 = undefined;
    const result = normalizeFontToken(&buf, "");
    try std.testing.expectEqualStrings("", result);
}

test "normalizeFontToken: truncates at buffer length" {
    var buf: [4]u8 = undefined;
    const result = normalizeFontToken(&buf, "ABCDEFGH");
    try std.testing.expectEqualStrings("abcd", result);
}

test "FontFamilyInfo: deinit releases all allocations" {
    const allocator = std.testing.allocator;
    var info = FontFamilyInfo{
        .family = try allocator.dupe(u8, "Test Font"),
        .styles = try allocator.alloc(FontFaceInfo, 2),
    };
    info.styles[0] = .{ .style = try allocator.dupe(u8, "Regular") };
    info.styles[1] = .{ .style = try allocator.dupe(u8, "Bold") };
    info.deinit(allocator);
    // If deinit missed an allocation, the next test would report a leak.
}

test "SeenFontFamilies: deduplicates by normalised name" {
    const allocator = std.testing.allocator;
    var seen = SeenFontFamilies{ .allocator = allocator };
    defer seen.deinit();

    try seen.add("Yu Gothic UI");
    try seen.add("Yu Gothic UI"); // duplicate
    try seen.add("yu-gothic-ui"); // same normalised
    try seen.add("Consolas");

    try std.testing.expectEqual(@as(usize, 2), seen.names.items.len);
    try std.testing.expectEqualStrings("Yu Gothic UI", seen.names.items[0]);
    try std.testing.expectEqualStrings("Consolas", seen.names.items[1]);
}

test "FontFamilyInfoBuilder: deduplicates styles" {
    const allocator = std.testing.allocator;
    var builder = try FontFamilyInfoBuilder.init(allocator, "Test", "Regular");
    defer builder.deinit(allocator);

    try builder.addStyle(allocator, "Bold");
    try builder.addStyle(allocator, "Bold"); // duplicate
    try builder.addStyle(allocator, "Italic");
    try std.testing.expectEqual(@as(usize, 3), builder.styles.items.len);
}
