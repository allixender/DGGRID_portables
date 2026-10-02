//! Portable, GDAL-free DGGRID builds from the `DGGRID` submodule (sahrk/DGGRID).
//!
//!   zig build                      dggrid for the host (or -Dtarget=...), zig-out/bin
//!   zig build release              all release targets, ReleaseFast + stripped,
//!                                  zig-out/release/<platform>/dggrid[.exe]
//!   zig build -Dubsan=true ...     UB sanitizer in trap mode (CI check, not for shipping)
//!
//! Source lists are globbed (sorted, non-recursive) from the upstream lib/app dirs,
//! which matches upstream's CMakeLists exactly, so submodule bumps need no edits here.

const std = @import("std");

const src_root = "DGGRID/src";

const include_dirs = [_][]const u8{
    src_root ++ "/lib/dglib/include",
    src_root ++ "/lib/dgaplib/include",
    src_root ++ "/lib/proj4lib/include",
    src_root ++ "/lib/shapelib/include",
    // upstream includes some shapelib headers without the shapelib/ prefix
    src_root ++ "/lib/shapelib/include/shapelib",
    src_root ++ "/apps/dggrid",
};

const cxx_flags = [_][]const u8{ "-std=c++11", "-D_USE_MATH_DEFINES" };
const c_flags = [_][]const u8{"-std=c99"};

/// Release matrix: platform name (used for the output dir and asset names) -> zig target.
const release_targets = [_]struct { name: []const u8, query: []const u8 }{
    .{ .name = "linux-x86_64", .query = "x86_64-linux-musl" },
    .{ .name = "linux-arm64", .query = "aarch64-linux-musl" },
    .{ .name = "macos-x86_64", .query = "x86_64-macos.11.0" },
    .{ .name = "macos-arm64", .query = "aarch64-macos.11.0" },
    .{ .name = "windows-x86_64", .query = "x86_64-windows-gnu" },
    .{ .name = "windows-arm64", .query = "aarch64-windows-gnu" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ubsan = b.option(bool, "ubsan", "Enable the C/C++ UB sanitizer in trap mode") orelse false;
    const strip = b.option(bool, "strip", "Strip debug info from the binary");

    const dggrid = addDggrid(b, target, optimize, ubsan, strip);
    b.installArtifact(dggrid);

    const run = b.addRunArtifact(dggrid);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run dggrid (pass args after --)").dependOn(&run.step);

    const release_step = b.step("release", "Build all release targets (ReleaseFast, stripped)");
    for (release_targets) |rt| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = rt.query }) catch
            std.debug.panic("bad target query '{s}'", .{rt.query});
        const exe = addDggrid(b, b.resolveTargetQuery(query), .ReleaseFast, false, true);
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{rt.name}) } },
            .pdb_dir = .disabled,
        });
        release_step.dependOn(&install.step);
    }
}

fn addDggrid(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ubsan: bool,
    strip: ?bool,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .strip = strip,
        .sanitize_c = if (ubsan) .trap else .off,
    });
    for (include_dirs) |dir| mod.addIncludePath(b.path(dir));
    // MinGW x86_64: long double is 80-bit x87, but UCRT's printf family reads %Lf as a
    // 64-bit double, so every "%LF" coordinate came out as 0.0. mingw-w64's own stdio
    // handles 80-bit long double. (aarch64: long double == double, UCRT is correct.)
    // That define does not reach zig's prebuilt libc++ (ostream << long double still
    // went through UCRT), so also install a num_put facet that formats long double
    // with mingw-w64's printf, see src/mingw_ldouble_numput.cpp and build_notes.md.
    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64) {
        mod.addCMacro("__USE_MINGW_ANSI_STDIO", "1");
        mod.addCSourceFile(.{ .file = b.path("src/mingw_ldouble_numput.cpp"), .flags = &cxx_flags });
    }

    mod.addCSourceFiles(.{ .files = globSources(b, src_root ++ "/lib/dglib/lib", ".cpp"), .flags = &cxx_flags });
    mod.addCSourceFiles(.{ .files = globSources(b, src_root ++ "/lib/dgaplib/lib", ".cpp"), .flags = &cxx_flags });
    mod.addCSourceFiles(.{ .files = globSources(b, src_root ++ "/lib/proj4lib/lib", ".cpp"), .flags = &cxx_flags });
    mod.addCSourceFiles(.{ .files = globSources(b, src_root ++ "/lib/shapelib/lib", ".c"), .flags = &c_flags });
    mod.addCSourceFiles(.{ .files = globSources(b, src_root ++ "/apps/dggrid", ".cpp"), .flags = &cxx_flags });

    return b.addExecutable(.{ .name = "dggrid", .root_module = mod });
}

/// Sorted, non-recursive list of `dir/*<ext>`. Sorting keeps the link order, and so
/// the output, independent of the host filesystem's directory order.
fn globSources(b: *std.Build, dir: []const u8, ext: []const u8) []const []const u8 {
    const io = b.graph.io;
    var d = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s} ({t}); is the DGGRID submodule checked out?", .{ dir, err });
    defer d.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch |err| std.debug.panic("iterating {s}: {t}", .{ dir, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ext)) continue;
        files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.name })) catch @panic("OOM");
    }
    if (files.items.len == 0) std.debug.panic("no {s} sources in {s}", .{ ext, dir });

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return files.items;
}
