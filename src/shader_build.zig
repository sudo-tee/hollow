//! glslang and SPIRV-Cross static libraries for custom (Shadertoy) shaders.
//! Adapted from Ghostty's pkg/glslang and pkg/spirv-cross builds, plus the
//! HLSL backend that Ghostty doesn't need.
const std = @import("std");

pub const Libs = struct {
    glslang: *std.Build.Step.Compile,
    spirv_cross: *std.Build.Step.Compile,
    translate: *std.Build.Step.TranslateC,

    pub fn link(self: Libs, module: *std.Build.Module) void {
        module.linkLibrary(self.glslang);
        module.linkLibrary(self.spirv_cross);
        module.addImport("shaderc_c", self.translate.createModule());
    }
};

/// Returns null on the first configure pass, before the lazy upstream
/// tarballs are fetched.
pub fn libs(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) ?Libs {
    const glslang_upstream = b.lazyDependency("glslang", .{}) orelse return null;
    const spirv_upstream = b.lazyDependency("spirv_cross", .{}) orelse return null;

    const flags: []const []const u8 = &.{
        "-std=c++17",
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    };

    const glslang = cppLibrary(b, "glslang", target, optimize);
    glslang.root_module.addIncludePath(glslang_upstream.path(""));
    glslang.root_module.addIncludePath(b.path("src/render/shaders/glslang_override"));
    glslang.root_module.addCSourceFiles(.{ .root = glslang_upstream.path(""), .flags = flags, .files = &glslang_sources });
    glslang.root_module.addCSourceFile(.{
        .file = glslang_upstream.path(if (target.result.os.tag == .windows)
            "glslang/OSDependent/Windows/ossource.cpp"
        else
            "glslang/OSDependent/Unix/ossource.cpp"),
        .flags = flags,
    });

    const spirv_cross = cppLibrary(b, "spirv_cross", target, optimize);
    spirv_cross.root_module.addIncludePath(spirv_upstream.path(""));
    spirv_cross.root_module.addCSourceFiles(.{
        .root = spirv_upstream.path(""),
        .flags = &.{
            "-DSPIRV_CROSS_C_API_GLSL=1",
            "-DSPIRV_CROSS_C_API_HLSL=1",
            "-fno-sanitize=undefined",
            "-fno-sanitize-trap=undefined",
        },
        .files = &.{
            "spirv_cross.cpp",
            "spirv_parser.cpp",
            "spirv_cross_parsed_ir.cpp",
            "spirv_cfg.cpp",
            "spirv_cross_c.cpp",
            "spirv_glsl.cpp",
            "spirv_hlsl.cpp",
        },
    });

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/render/shaders/shaderc_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.addIncludePath(glslang_upstream.path(""));
    translate.addIncludePath(spirv_upstream.path(""));

    return .{ .glslang = glslang, .spirv_cross = spirv_cross, .translate = translate };
}

fn cppLibrary(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = target.result.abi != .msvc,
        }),
        .linkage = .static,
    });
}

const glslang_sources = [_][]const u8{
    "glslang/GenericCodeGen/CodeGen.cpp",
    "glslang/GenericCodeGen/Link.cpp",
    "glslang/MachineIndependent/glslang_tab.cpp",
    "glslang/MachineIndependent/attribute.cpp",
    "glslang/MachineIndependent/Constant.cpp",
    "glslang/MachineIndependent/iomapper.cpp",
    "glslang/MachineIndependent/InfoSink.cpp",
    "glslang/MachineIndependent/Initialize.cpp",
    "glslang/MachineIndependent/IntermTraverse.cpp",
    "glslang/MachineIndependent/Intermediate.cpp",
    "glslang/MachineIndependent/ParseContextBase.cpp",
    "glslang/MachineIndependent/ParseHelper.cpp",
    "glslang/MachineIndependent/PoolAlloc.cpp",
    "glslang/MachineIndependent/RemoveTree.cpp",
    "glslang/MachineIndependent/Scan.cpp",
    "glslang/MachineIndependent/ShaderLang.cpp",
    "glslang/MachineIndependent/SpirvIntrinsics.cpp",
    "glslang/MachineIndependent/SymbolTable.cpp",
    "glslang/MachineIndependent/Versions.cpp",
    "glslang/MachineIndependent/intermOut.cpp",
    "glslang/MachineIndependent/limits.cpp",
    "glslang/MachineIndependent/linkValidate.cpp",
    "glslang/MachineIndependent/parseConst.cpp",
    "glslang/MachineIndependent/reflection.cpp",
    "glslang/MachineIndependent/preprocessor/Pp.cpp",
    "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
    "glslang/MachineIndependent/preprocessor/PpContext.cpp",
    "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
    "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
    "glslang/MachineIndependent/propagateNoContraction.cpp",
    "glslang/CInterface/glslang_c_interface.cpp",
    "glslang/ResourceLimits/ResourceLimits.cpp",
    "glslang/ResourceLimits/resource_limits_c.cpp",
    "SPIRV/GlslangToSpv.cpp",
    "SPIRV/InReadableOrder.cpp",
    "SPIRV/Logger.cpp",
    "SPIRV/SpvBuilder.cpp",
    "SPIRV/SpvPostProcess.cpp",
    "SPIRV/doc.cpp",
    "SPIRV/disassemble.cpp",
    "SPIRV/CInterface/spirv_c_interface.cpp",
};
