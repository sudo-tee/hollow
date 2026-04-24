const std = @import("std");
const platform = @import("platform.zig");
const ghostty = @import("term/ghostty.zig");

pub const RendererBackend = enum {
    null,
    sokol,
    webgpu,

    pub fn asString(self: RendererBackend) []const u8 {
        return switch (self) {
            .null => "null",
            .sokol => "sokol",
            .webgpu => "webgpu",
        };
    }
};

pub const Config = struct {
    pub const TopBarMode = enum {
        always,
        tabs,
    };

    pub const DomainSshBackend = enum {
        native,
        wsl,
    };

    pub const DomainSshReuse = enum {
        none,
        auto,
    };

    pub const DomainSshSpec = struct {
        host: ?[]const u8 = null,
        user: ?[]const u8 = null,
        alias: ?[]const u8 = null,
        backend: DomainSshBackend = .native,
        reuse: DomainSshReuse = .none,
    };

    pub const DomainSsh = struct {
        host: ?[]u8 = null,
        user: ?[]u8 = null,
        alias: ?[]u8 = null,
        backend: DomainSshBackend = .native,
        reuse: DomainSshReuse = .none,

        pub fn deinit(self: *DomainSsh, allocator: std.mem.Allocator) void {
            freeOwned(allocator, &self.host);
            freeOwned(allocator, &self.user);
            freeOwned(allocator, &self.alias);
            self.* = .{};
        }
    };

    pub const Domain = struct {
        name: []u8,
        shell: ?[]u8 = null,
        default_cwd: ?[]u8 = null,
        ssh: ?DomainSsh = null,
    };

    pub const TerminalTheme = struct {
        enabled: bool = false,
        foreground: ghostty.ColorRgb = .{ .r = 220, .g = 220, .b = 220 },
        background: ghostty.ColorRgb = .{ .r = 18, .g = 20, .b = 28 },
        cursor: ?ghostty.ColorRgb = null,
        selection_fg: ?ghostty.ColorRgb = null,
        selection_bg: ?ghostty.ColorRgb = null,
        palette: [256]ghostty.ColorRgb = defaultPalette(),

        fn defaultPalette() [256]ghostty.ColorRgb {
            var palette = [_]ghostty.ColorRgb{.{ .r = 0, .g = 0, .b = 0 }} ** 256;
            palette[0] = .{ .r = 0, .g = 0, .b = 0 };
            palette[1] = .{ .r = 205, .g = 49, .b = 49 };
            palette[2] = .{ .r = 13, .g = 188, .b = 121 };
            palette[3] = .{ .r = 229, .g = 229, .b = 16 };
            palette[4] = .{ .r = 36, .g = 114, .b = 200 };
            palette[5] = .{ .r = 188, .g = 63, .b = 188 };
            palette[6] = .{ .r = 17, .g = 168, .b = 205 };
            palette[7] = .{ .r = 229, .g = 229, .b = 229 };
            palette[8] = .{ .r = 102, .g = 102, .b = 102 };
            palette[9] = .{ .r = 241, .g = 76, .b = 76 };
            palette[10] = .{ .r = 35, .g = 209, .b = 139 };
            palette[11] = .{ .r = 245, .g = 245, .b = 67 };
            palette[12] = .{ .r = 59, .g = 142, .b = 234 };
            palette[13] = .{ .r = 214, .g = 112, .b = 214 };
            palette[14] = .{ .r = 41, .g = 184, .b = 219 };
            palette[15] = .{ .r = 229, .g = 229, .b = 229 };

            var cube_index: usize = 16;
            while (cube_index < 232) : (cube_index += 1) {
                const offset = cube_index - 16;
                const r = offset / 36;
                const g = (offset / 6) % 6;
                const b = offset % 6;
                palette[cube_index] = .{
                    .r = xtermCubeLevel(r),
                    .g = xtermCubeLevel(g),
                    .b = xtermCubeLevel(b),
                };
            }

            var gray_index: usize = 232;
            while (gray_index < 256) : (gray_index += 1) {
                const value: u8 = @intCast(8 + (gray_index - 232) * 10);
                palette[gray_index] = .{ .r = value, .g = value, .b = value };
            }

            return palette;
        }

        fn xtermCubeLevel(step: usize) u8 {
            return switch (step) {
                0 => 0,
                1 => 95,
                2 => 135,
                3 => 175,
                4 => 215,
                5 => 255,
                else => 0,
            };
        }
    };

    pub const Fonts = struct {
        pub const Smoothing = enum {
            grayscale,
            subpixel,
        };

        pub const Hinting = enum {
            none,
            light,
            normal,
        };

        size: f32 = 15,
        line_height: f32 = 1.0,
        padding_x: f32 = 0,
        padding_y: f32 = 0,
        coverage_boost: f32 = 1.0,
        coverage_add: f32 = 0.0,
        smoothing: Smoothing = .grayscale,
        hinting: Hinting = .normal,
        ligatures: bool = true,
        embolden: f32 = 0.0,
        family: ?[]u8 = null,
        regular: ?[]u8 = null,
        bold: ?[]u8 = null,
        italic: ?[]u8 = null,
        bold_italic: ?[]u8 = null,
        fallback_paths: std.ArrayListUnmanaged([]u8) = .{},

        pub fn deinit(self: *Fonts, allocator: std.mem.Allocator) void {
            freeOwned(allocator, &self.family);
            freeOwned(allocator, &self.regular);
            freeOwned(allocator, &self.bold);
            freeOwned(allocator, &self.italic);
            freeOwned(allocator, &self.bold_italic);
            for (self.fallback_paths.items) |path| allocator.free(path);
            self.fallback_paths.deinit(allocator);
            self.* = .{};
        }
    };

    pub const TerminalPadding = struct {
        left: u32 = 0,
        right: u32 = 0,
        top: u32 = 0,
        bottom: u32 = 0,

        pub fn horizontal(self: TerminalPadding) u32 {
            return self.left + self.right;
        }

        pub fn vertical(self: TerminalPadding) u32 {
            return self.top + self.bottom;
        }
    };

    pub const Scrollbar = struct {
        enabled: bool = true,
        width: u32 = 10,
        min_thumb_size: u32 = 24,
        margin: u32 = 2,
        jump_to_click: bool = true,
        track_color: ghostty.ColorRgb = .{ .r = 26, .g = 28, .b = 35 },
        thumb_color: ghostty.ColorRgb = .{ .r = 76, .g = 82, .b = 100 },
        thumb_hover_color: ghostty.ColorRgb = .{ .r = 106, .g = 114, .b = 136 },
        thumb_active_color: ghostty.ColorRgb = .{ .r = 126, .g = 165, .b = 236 },
        border_color: ghostty.ColorRgb = .{ .r = 46, .g = 49, .b = 60 },

        pub fn gutterWidth(self: Scrollbar) u32 {
            if (!self.enabled) return 0;
            return self.width + self.margin * 2;
        }
    };

    pub const Hyperlinks = struct {
        enabled: bool = true,
        shift_click_only: bool = true,
        match_www: bool = true,
        opener: ?[]u8 = null,
        prefixes: ?[]u8 = null,
        delimiters: ?[]u8 = null,
        trim_trailing: ?[]u8 = null,
        trim_leading: ?[]u8 = null,

        pub fn deinit(self: *Hyperlinks, allocator: std.mem.Allocator) void {
            freeOwned(allocator, &self.opener);
            freeOwned(allocator, &self.prefixes);
            freeOwned(allocator, &self.delimiters);
            freeOwned(allocator, &self.trim_trailing);
            freeOwned(allocator, &self.trim_leading);
            self.* = .{};
        }

        pub fn prefixesOrDefault(self: Hyperlinks) []const u8 {
            return self.prefixes orelse "https:// http:// file:// ftp:// mailto:";
        }

        pub fn delimitersOrDefault(self: Hyperlinks) []const u8 {
            return self.delimiters orelse " \t\r\n\"'<>[]{}|\\^`";
        }

        pub fn trimTrailingOrDefault(self: Hyperlinks) []const u8 {
            return self.trim_trailing orelse ".,;:!?)]}";
        }

        pub fn trimLeadingOrDefault(self: Hyperlinks) []const u8 {
            return self.trim_leading orelse "([{";
        }
    };

    allocator: std.mem.Allocator,
    backend: RendererBackend = .sokol,
    shell: ?[]u8 = null,
    default_domain: ?[]u8 = null,
    domains: std.ArrayListUnmanaged(Domain) = .{},
    htp_transport: ?[]u8 = null,
    fonts: Fonts = .{},
    window_title: ?[]u8 = null,
    window_width: u32 = 1280,
    window_height: u32 = 800,
    cols: u16 = 120,
    rows: u16 = 34,
    /// Scrollback history budget in bytes, matching Ghostty's native API.
    /// Rough rule of thumb: tens of MB gives much deeper history than a raw
    /// line count because storage depends on row width and styling density.
    scrollback: usize = 10_000_000,
    terminal_padding: TerminalPadding = .{},
    scrollbar: Scrollbar = .{},
    hyperlinks: Hyperlinks = .{},
    lib_dir: ?[]u8 = null,
    top_bar_mode: TopBarMode = .tabs,
    window_titlebar_show: bool = true,
    top_bar_height: u32 = 0,
    top_bar_bg: ghostty.ColorRgb = .{ .r = 28, .g = 30, .b = 38 },
    bottom_bar_show: bool = true,
    bottom_bar_height: u32 = 0,
    bottom_bar_bg: ghostty.ColorRgb = .{ .r = 28, .g = 30, .b = 38 },
    bottom_bar_draw_status: bool = true,
    debug_overlay: bool = false,
    vsync: bool = true,
    /// Frame cap used when vsync is disabled. Set to 0 to leave the render
    /// loop uncapped.
    max_fps: u32 = 120,
    /// Allow single-pane mode to skip the offscreen render-target cache and
    /// render directly into the swapchain.  Defaulting to false preserves the
    /// cached-RT path which gives smoother frame pacing.  Set to true to
    /// opt back into the lower-latency but burstier direct-render path.
    renderer_single_pane_direct: bool = false,
    renderer_safe_mode: bool = false,
    renderer_disable_swapchain_glyphs: bool = false,
    renderer_disable_multi_pane_cache: bool = false,
    /// Multiplier applied to raw wheel/touchpad scroll delta before
    /// accumulation into whole-line steps.  1.0 is the neutral value; the
    /// old hard-coded value was 2.0.
    scroll_multiplier: f32 = 1.0,
    terminal_theme: TerminalTheme = .{},

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Config) void {
        freeOwned(self.allocator, &self.shell);
        freeOwned(self.allocator, &self.default_domain);
        for (self.domains.items) |*domain| {
            self.allocator.free(domain.name);
            freeOwned(self.allocator, &domain.shell);
            freeOwned(self.allocator, &domain.default_cwd);
            if (domain.ssh) |*ssh| ssh.deinit(self.allocator);
        }
        self.domains.deinit(self.allocator);
        freeOwned(self.allocator, &self.htp_transport);
        self.fonts.deinit(self.allocator);
        freeOwned(self.allocator, &self.window_title);
        freeOwned(self.allocator, &self.lib_dir);
        self.hyperlinks.deinit(self.allocator);
    }

    pub fn shellOrDefault(self: Config) []const u8 {
        return self.shell orelse platform.defaultShell();
    }

    pub fn defaultDomainName(self: Config) ?[]const u8 {
        if (self.default_domain) |name| {
            if (self.domainByName(name) != null) return name;
        }
        return null;
    }

    pub fn shellForDomain(self: Config, domain_name: ?[]const u8) ![]const u8 {
        if (domain_name) |name| {
            const domain = self.domainByName(name) orelse return error.UnknownDomain;
            return domain.shell orelse error.DomainShellMissing;
        }

        if (self.defaultDomainName()) |name| {
            const domain = self.domainByName(name) orelse return self.shellOrDefault();
            return domain.shell orelse self.shellOrDefault();
        }

        return self.shellOrDefault();
    }

    pub fn defaultCwdForDomain(self: Config, domain_name: ?[]const u8) ?[]const u8 {
        if (domain_name) |name| {
            const domain = self.domainByName(name) orelse return null;
            return domain.default_cwd;
        }

        if (self.defaultDomainName()) |name| {
            const domain = self.domainByName(name) orelse return null;
            return domain.default_cwd;
        }

        return null;
    }

    pub fn windowTitle(self: Config) []const u8 {
        return self.window_title orelse "hollow";
    }

    pub fn setBackend(self: *Config, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(value, "null")) {
            self.backend = .null;
            return;
        }

        if (std.ascii.eqlIgnoreCase(value, "sokol")) {
            self.backend = .sokol;
            return;
        }

        if (std.ascii.eqlIgnoreCase(value, "webgpu")) {
            self.backend = .webgpu;
            return;
        }

        return error.InvalidBackend;
    }

    pub fn setShell(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.shell, value);
    }

    pub fn setDefaultDomain(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.default_domain, value);
    }

    pub fn setDomainShell(self: *Config, name: []const u8, shell_value: []const u8) !void {
        const domain = try self.ensureDomain(name);
        if (domain.ssh) |*ssh| {
            ssh.deinit(self.allocator);
            domain.ssh = null;
        }
        try replaceOwned(self.allocator, &domain.shell, shell_value);
    }

    pub fn setDomainDefaultCwd(self: *Config, name: []const u8, cwd_value: []const u8) !void {
        const domain = try self.ensureDomain(name);
        try replaceOwned(self.allocator, &domain.default_cwd, cwd_value);
    }

    pub fn setDomainSsh(self: *Config, name: []const u8, spec: DomainSshSpec) !void {
        const domain = try self.ensureDomain(name);

        if (domain.ssh) |*ssh| {
            ssh.deinit(self.allocator);
        }

        domain.ssh = .{
            .host = if (spec.host) |value| try self.allocator.dupe(u8, value) else null,
            .user = if (spec.user) |value| try self.allocator.dupe(u8, value) else null,
            .alias = if (spec.alias) |value| try self.allocator.dupe(u8, value) else null,
            .backend = spec.backend,
            .reuse = spec.reuse,
        };

        const shell_value = try self.buildSshDomainShell(domain.ssh.?);
        defer self.allocator.free(shell_value);
        try replaceOwned(self.allocator, &domain.shell, shell_value);
    }

    fn ensureDomain(self: *Config, name: []const u8) !*Domain {
        if (self.domainByNamePtr(name)) |domain| return domain;

        try self.domains.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
        });
        return &self.domains.items[self.domains.items.len - 1];
    }

    fn buildSshDomainShell(self: *Config, ssh: DomainSsh) ![]u8 {
        const target = if (ssh.host) |host|
            if (host.len > 0) blk: {
                if (ssh.user) |user| {
                    break :blk try std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ user, host });
                }
                break :blk try self.allocator.dupe(u8, host);
            } else null
        else if (ssh.alias) |alias|
            if (alias.len > 0) try self.allocator.dupe(u8, alias) else null
        else
            null;

        const destination = target orelse return error.InvalidSshDomain;
        defer self.allocator.free(destination);

        const reuse_flags = try self.sshReuseFlags(ssh);
        defer self.allocator.free(reuse_flags);

        if (ssh.backend == .wsl and platform.isWindows()) {
            if (reuse_flags.len > 0) {
                return std.fmt.allocPrint(self.allocator, "wsl.exe ssh {s} {s}", .{ reuse_flags, destination });
            }
            return std.fmt.allocPrint(self.allocator, "wsl.exe ssh {s}", .{destination});
        }

        if (reuse_flags.len > 0) {
            return std.fmt.allocPrint(self.allocator, "ssh {s} {s}", .{ reuse_flags, destination });
        }
        return std.fmt.allocPrint(self.allocator, "ssh {s}", .{destination});
    }

    fn sshReuseFlags(self: *Config, ssh: DomainSsh) ![]u8 {
        if (ssh.reuse != .auto) return self.allocator.dupe(u8, "");

        if (ssh.backend == .wsl and platform.isWindows()) {
            return std.fmt.allocPrint(self.allocator, "-o ControlMaster=auto -o ControlPersist=10m -o ControlPath=/tmp/hollow-ssh-%C", .{});
        }

        if (!platform.isWindows()) {
            return std.fmt.allocPrint(self.allocator, "-o ControlMaster=auto -o ControlPersist=10m -o ControlPath=/tmp/hollow-ssh-%C", .{});
        }

        // Windows native OpenSSH does not reliably support Unix-socket based multiplexing.
        return self.allocator.dupe(u8, "");
    }

    pub fn domainByName(self: Config, name: []const u8) ?Domain {
        for (self.domains.items) |domain| {
            if (std.mem.eql(u8, domain.name, name)) return domain;
        }
        return null;
    }

    fn domainByNamePtr(self: *Config, name: []const u8) ?*Domain {
        for (self.domains.items) |*domain| {
            if (std.mem.eql(u8, domain.name, name)) return domain;
        }
        return null;
    }

    pub fn setHtpTransport(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.htp_transport, value);
    }

    pub fn setWindowTitle(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.window_title, value);
    }

    pub fn setLibDir(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.lib_dir, value);
    }

    pub fn setFontFamily(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.family, value);
    }

    pub fn setFontRegular(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.regular, value);
    }

    pub fn setFontBold(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.bold, value);
    }

    pub fn setFontItalic(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.italic, value);
    }

    pub fn setFontBoldItalic(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.fonts.bold_italic, value);
    }

    pub fn clearFontFallbacks(self: *Config) void {
        for (self.fonts.fallback_paths.items) |path| self.allocator.free(path);
        self.fonts.fallback_paths.clearRetainingCapacity();
    }

    pub fn addFontFallback(self: *Config, value: []const u8) !void {
        try self.fonts.fallback_paths.append(self.allocator, try self.allocator.dupe(u8, value));
    }

    pub fn setHyperlinkPrefixes(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.hyperlinks.prefixes, value);
    }

    pub fn setHyperlinkOpener(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.hyperlinks.opener, value);
    }

    pub fn setHyperlinkDelimiters(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.hyperlinks.delimiters, value);
    }

    pub fn setHyperlinkTrimTrailing(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.hyperlinks.trim_trailing, value);
    }

    pub fn setHyperlinkTrimLeading(self: *Config, value: []const u8) !void {
        try replaceOwned(self.allocator, &self.hyperlinks.trim_leading, value);
    }

    pub fn setFontSmoothing(self: *Config, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(value, "grayscale")) {
            self.fonts.smoothing = .grayscale;
            return;
        }
        if (std.ascii.eqlIgnoreCase(value, "subpixel") or std.ascii.eqlIgnoreCase(value, "lcd")) {
            self.fonts.smoothing = .subpixel;
            return;
        }
        return error.InvalidFontSmoothing;
    }

    pub fn setFontHinting(self: *Config, value: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(value, "none")) {
            self.fonts.hinting = .none;
            return;
        }
        if (std.ascii.eqlIgnoreCase(value, "light")) {
            self.fonts.hinting = .light;
            return;
        }
        if (std.ascii.eqlIgnoreCase(value, "normal")) {
            self.fonts.hinting = .normal;
            return;
        }
        return error.InvalidFontHinting;
    }
};

fn replaceOwned(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    freeOwned(allocator, slot);
    slot.* = try allocator.dupe(u8, value);
}

fn freeOwned(allocator: std.mem.Allocator, slot: *?[]u8) void {
    if (slot.*) |owned| {
        allocator.free(owned);
        slot.* = null;
    }
}

test "backend parsing covers planned renderers" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setBackend("webgpu");
    try std.testing.expectEqual(RendererBackend.webgpu, cfg.backend);

    try cfg.setBackend("sokol");
    try std.testing.expectEqual(RendererBackend.sokol, cfg.backend);
}

test "terminal theme default palette fills xterm 256 colors" {
    const palette = Config.TerminalTheme.defaultPalette();

    try std.testing.expectEqualDeep(ghostty.ColorRgb{ .r = 0, .g = 0, .b = 0 }, palette[16]);
    try std.testing.expectEqualDeep(ghostty.ColorRgb{ .r = 0, .g = 0, .b = 255 }, palette[21]);
    try std.testing.expectEqualDeep(ghostty.ColorRgb{ .r = 255, .g = 255, .b = 255 }, palette[231]);
    try std.testing.expectEqualDeep(ghostty.ColorRgb{ .r = 8, .g = 8, .b = 8 }, palette[232]);
    try std.testing.expectEqualDeep(ghostty.ColorRgb{ .r = 238, .g = 238, .b = 238 }, palette[255]);
}

test "domain shell and cwd resolution honor explicit and default domains" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setShell("/bin/fallback");
    try cfg.setDomainShell("local", "/bin/zsh");
    try cfg.setDomainDefaultCwd("local", "/tmp/local");
    try cfg.setDomainDefaultCwd("cwd-only", "/tmp/cwd-only");
    try cfg.setDefaultDomain("local");

    try std.testing.expectEqualStrings("/bin/zsh", try cfg.shellForDomain("local"));
    try std.testing.expectEqualStrings("/bin/zsh", try cfg.shellForDomain(null));
    try std.testing.expectError(error.DomainShellMissing, cfg.shellForDomain("cwd-only"));
    try std.testing.expectError(error.UnknownDomain, cfg.shellForDomain("missing"));
    try std.testing.expectEqualStrings("/tmp/local", cfg.defaultCwdForDomain(null).?);
    try std.testing.expectEqualStrings("/tmp/cwd-only", cfg.defaultCwdForDomain("cwd-only").?);
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.defaultCwdForDomain("missing"));
}

test "shellForDomain reports unknown and missing-shell domains distinctly" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setDomainDefaultCwd("cwd-only", "/tmp/cwd-only");

    try std.testing.expectError(error.UnknownDomain, cfg.shellForDomain("missing"));
    try std.testing.expectError(error.DomainShellMissing, cfg.shellForDomain("cwd-only"));
}

test "hyperlink defaults and overrides stay stable" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), cfg.hyperlinks.opener);
    try std.testing.expectEqualStrings("https:// http:// file:// ftp:// mailto:", cfg.hyperlinks.prefixesOrDefault());
    try std.testing.expectEqualStrings(" \t\r\n\"'<>[]{}|\\^`", cfg.hyperlinks.delimitersOrDefault());
    try std.testing.expectEqualStrings(".,;:!?)]}", cfg.hyperlinks.trimTrailingOrDefault());
    try std.testing.expectEqualStrings("([{", cfg.hyperlinks.trimLeadingOrDefault());

    try cfg.setHyperlinkOpener("wslview");
    try cfg.setHyperlinkPrefixes("custom://");
    try cfg.setHyperlinkDelimiters(" |");
    try cfg.setHyperlinkTrimTrailing("?!");
    try cfg.setHyperlinkTrimLeading("<(");

    try std.testing.expectEqualStrings("wslview", cfg.hyperlinks.opener.?);
    try std.testing.expectEqualStrings("custom://", cfg.hyperlinks.prefixesOrDefault());
    try std.testing.expectEqualStrings(" |", cfg.hyperlinks.delimitersOrDefault());
    try std.testing.expectEqualStrings("?!", cfg.hyperlinks.trimTrailingOrDefault());
    try std.testing.expectEqualStrings("<(", cfg.hyperlinks.trimLeadingOrDefault());
}

test "scrollbar gutter width includes margins only when enabled" {
    const enabled = Config.Scrollbar{ .enabled = true, .width = 12, .margin = 3 };
    const disabled = Config.Scrollbar{ .enabled = false, .width = 12, .margin = 3 };

    try std.testing.expectEqual(@as(u32, 18), enabled.gutterWidth());
    try std.testing.expectEqual(@as(u32, 0), disabled.gutterWidth());
}

test "setDomainSsh builds shell command from ssh spec" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setDomainSsh("remote", .{
        .host = "example.com",
        .user = "alice",
        .backend = if (platform.isWindows()) .wsl else .native,
        .reuse = .auto,
    });

    const domain = cfg.domainByName("remote").?;
    const shell = domain.shell.?;

    if (platform.isWindows()) {
        try std.testing.expectEqualStrings("wsl.exe ssh -o ControlMaster=auto -o ControlPersist=10m -o ControlPath=/tmp/hollow-ssh-%C alice@example.com", shell);
    } else {
        try std.testing.expectEqualStrings("ssh -o ControlMaster=auto -o ControlPersist=10m -o ControlPath=/tmp/hollow-ssh-%C alice@example.com", shell);
    }
}

test "setDomainSsh accepts alias-only specs without reuse flags" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setDomainSsh("alias-only", .{ .alias = "prod", .reuse = .none });

    const shell = cfg.domainByName("alias-only").?.shell.?;
    if (platform.isWindows()) {
        try std.testing.expectEqualStrings("ssh prod", shell);
    } else {
        try std.testing.expectEqualStrings("ssh prod", shell);
    }
}

test "window title shell and default domain helpers fall back safely" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("hollow", cfg.windowTitle());
    try std.testing.expectEqualStrings(platform.defaultShell(), cfg.shellOrDefault());
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.defaultDomainName());

    try cfg.setWindowTitle("custom title");
    try cfg.setShell("/bin/custom-shell");
    try cfg.setDefaultDomain("missing-domain");

    try std.testing.expectEqualStrings("custom title", cfg.windowTitle());
    try std.testing.expectEqualStrings("/bin/custom-shell", cfg.shellOrDefault());
    try std.testing.expectEqual(@as(?[]const u8, null), cfg.defaultDomainName());

    try cfg.setDomainShell("actual-domain", "/bin/domain-shell");
    try cfg.setDefaultDomain("actual-domain");
    try std.testing.expectEqualStrings("actual-domain", cfg.defaultDomainName().?);
}

test "font smoothing and hinting parse accepted values and reject invalid ones" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setFontSmoothing("grayscale");
    try std.testing.expectEqual(Config.Fonts.Smoothing.grayscale, cfg.fonts.smoothing);

    try cfg.setFontSmoothing("lcd");
    try std.testing.expectEqual(Config.Fonts.Smoothing.subpixel, cfg.fonts.smoothing);

    try cfg.setFontHinting("none");
    try std.testing.expectEqual(Config.Fonts.Hinting.none, cfg.fonts.hinting);

    try cfg.setFontHinting("light");
    try std.testing.expectEqual(Config.Fonts.Hinting.light, cfg.fonts.hinting);

    try cfg.setFontHinting("normal");
    try std.testing.expectEqual(Config.Fonts.Hinting.normal, cfg.fonts.hinting);

    try std.testing.expectError(error.InvalidFontSmoothing, cfg.setFontSmoothing("sharp"));
    try std.testing.expectError(error.InvalidFontHinting, cfg.setFontHinting("heavy"));
}

test "font family setter stores owned value" {
    var cfg = Config.init(std.testing.allocator);
    defer cfg.deinit();

    try cfg.setFontFamily("Consolas");
    try std.testing.expectEqualStrings("Consolas", cfg.fonts.family.?);

    try cfg.setFontFamily("JetBrains Mono");
    try std.testing.expectEqualStrings("JetBrains Mono", cfg.fonts.family.?);
}

test "replaceOwned and freeOwned manage owned string slots" {
    var slot: ?[]u8 = null;

    try replaceOwned(std.testing.allocator, &slot, "alpha");
    try std.testing.expectEqualStrings("alpha", slot.?);

    try replaceOwned(std.testing.allocator, &slot, "beta");
    try std.testing.expectEqualStrings("beta", slot.?);

    freeOwned(std.testing.allocator, &slot);
    try std.testing.expectEqual(@as(?[]u8, null), slot);
}
