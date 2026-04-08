const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlib = buildZlib(b, target, optimize);
    const freetype = buildFreeType(b, target, optimize, zlib);
    const harfbuzz = buildHarfbuzz(b, target, optimize, freetype);

    b.installArtifact(zlib);
    b.installArtifact(freetype);
    b.installArtifact(harfbuzz);
}

fn buildZlib(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const upstream = b.lazyDependency("zlib_upstream", .{}) orelse @panic("missing zlib_upstream");

    const lib = b.addLibrary(.{
        .name = "z",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    flags.appendSlice(b.allocator, &.{
        "-DHAVE_SYS_TYPES_H",
        "-DHAVE_STDINT_H",
        "-DHAVE_STDDEF_H",
    }) catch @panic("OOM");
    if (target.result.os.tag != .windows) {
        flags.append(b.allocator, "-DZ_HAVE_UNISTD_H") catch @panic("OOM");
    }
    if (target.result.abi == .msvc) {
        flags.appendSlice(b.allocator, &.{
            "-D_CRT_SECURE_NO_DEPRECATE",
            "-D_CRT_NONSTDC_NO_DEPRECATE",
        }) catch @panic("OOM");
    }

    lib.root_module.addIncludePath(upstream.path(""));
    lib.root_module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = zlib_srcs,
        .flags = flags.items,
    });
    lib.installHeadersDirectory(upstream.path(""), "", .{ .include_extensions = &.{".h"} });

    return lib;
}

fn buildFreeType(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zlib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const upstream = b.lazyDependency("freetype_upstream", .{}) orelse @panic("missing freetype_upstream");

    const lib = b.addLibrary(.{
        .name = "freetype",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    lib.root_module.linkLibrary(zlib);

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    flags.appendSlice(b.allocator, &.{
        "-DFT2_BUILD_LIBRARY",
        "-DFT_CONFIG_OPTION_SYSTEM_ZLIB=1",
        "-fno-sanitize=undefined",
    }) catch @panic("OOM");
    if (target.result.os.tag != .windows) {
        flags.appendSlice(b.allocator, &.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_FCNTL_H",
        }) catch @panic("OOM");
    }

    lib.root_module.addIncludePath(upstream.path("include"));
    lib.root_module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = freetype_srcs,
        .flags = flags.items,
    });

    switch (target.result.os.tag) {
        .linux => lib.root_module.addCSourceFile(.{
            .file = upstream.path("builds/unix/ftsystem.c"),
            .flags = flags.items,
        }),
        .windows => lib.root_module.addCSourceFile(.{
            .file = upstream.path("builds/windows/ftsystem.c"),
            .flags = flags.items,
        }),
        else => lib.root_module.addCSourceFile(.{
            .file = upstream.path("src/base/ftsystem.c"),
            .flags = flags.items,
        }),
    }

    switch (target.result.os.tag) {
        .windows => {
            lib.root_module.addCSourceFile(.{
                .file = upstream.path("builds/windows/ftdebug.c"),
                .flags = flags.items,
            });
            lib.addWin32ResourceFile(.{ .file = upstream.path("src/base/ftver.rc") });
        },
        else => lib.root_module.addCSourceFile(.{
            .file = upstream.path("src/base/ftdebug.c"),
            .flags = flags.items,
        }),
    }

    lib.installHeader(upstream.path("include/ft2build.h"), "ft2build.h");
    lib.installHeadersDirectory(upstream.path("include/freetype"), "freetype", .{ .include_extensions = &.{".h"} });

    return lib;
}

fn buildHarfbuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    freetype: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const upstream = b.lazyDependency("harfbuzz_upstream", .{}) orelse @panic("missing harfbuzz_upstream");

    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = if (target.result.abi != .msvc) true else null,
        }),
        .linkage = .static,
    });
    if (target.result.os.tag == .linux) {
        lib.root_module.linkSystemLibrary("m", .{});
    }
    lib.root_module.linkLibrary(freetype);
    lib.root_module.addIncludePath(freetype.getEmittedIncludeTree());

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    flags.appendSlice(b.allocator, &.{
        "-DHAVE_STDBOOL_H",
        "-DHAVE_FREETYPE=1",
        "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
        "-DHAVE_FT_DONE_MM_VAR=1",
        "-DHAVE_FT_GET_TRANSFORM=1",
    }) catch @panic("OOM");
    if (target.result.os.tag != .windows) {
        flags.appendSlice(b.allocator, &.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
        }) catch @panic("OOM");
    }

    lib.root_module.addIncludePath(upstream.path("src"));
    lib.root_module.addCSourceFile(.{
        .file = upstream.path("src/harfbuzz.cc"),
        .flags = flags.items,
    });
    lib.installHeadersDirectory(upstream.path("src"), "", .{ .include_extensions = &.{".h"} });

    return lib;
}

const zlib_srcs: []const []const u8 = &.{
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "gzclose.c",
    "gzlib.c",
    "gzread.c",
    "gzwrite.c",
    "inflate.c",
    "infback.c",
    "inftrees.c",
    "inffast.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
};

const freetype_srcs: []const []const u8 = &.{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};
