//! Prototype library build: dglib (+ geoarrow-c) from the patched source copy in .src/
//! (run ./setup_src.sh first, see README.md). Never touches the DGGRID submodule.
//!
//!   zig build -Ddgreal=double              dgreal = double instead of long double
//!   zig build dggrid                       CLI from the copy (verification vs upstream)
//!   zig build bench -- 200000              geo -> Q2DI loop, fatal hook test
//!   zig build smoke                        dglib cell -> GeoArrow WKB array
//!   libdggrid / dggrid.wasm also carry dgarrow.c (include/dggrid_arrow.h) + libgeoarrow
//!   zig build test                         C API tests (dggrid.zig)
//!   zig build                              + libdggrid shared lib + include/dggrid.h
//!   zig build -Dtarget=wasm32-wasi         libdglib, bench.wasm (no file IO classes),
//!                                          dggrid.wasm (reactor exporting the C API)

const std = @import("std");

const dg = ".src/DGGRID/src";
const ga = ".src/geoarrow-c/src";

const dg_includes = [_][]const u8{
    dg ++ "/lib/dglib/include",
    dg ++ "/lib/dgaplib/include",
    dg ++ "/lib/proj4lib/include",
    dg ++ "/lib/shapelib/include",
    dg ++ "/lib/shapelib/include/shapelib",
    dg ++ "/apps/dggrid",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dgreal = b.option(enum { longdouble, double }, "dgreal", "floating point type of dglib (default longdouble = upstream)") orelse .longdouble;
    const wasm = target.result.cpu.arch.isWasm();

    var cxx: std.ArrayList([]const u8) = .empty;
    cxx.appendSlice(b.allocator, &.{ "-std=c++11", "-D_USE_MATH_DEFINES" }) catch @panic("OOM");
    if (dgreal == .double) cxx.append(b.allocator, "-DDG_REAL_DOUBLE") catch @panic("OOM");
    const c_flags = [_][]const u8{"-std=c99"};

    // ---- libdglib: dglib + proj4lib + shapelib. wasm32-wasi: zig's libc++ there has
    // no <fstream>, so all file reader/writer classes (DgIn*, DgOut*) are left out.
    // pic: linked into the shared libdggrid
    const dgmod = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true, .pic = if (wasm) null else true });
    for (dg_includes) |p| dgmod.addIncludePath(b.path(p));
    dgmod.addCSourceFiles(.{ .files = globSorted(b, dg ++ "/lib/dglib/lib", ".cpp", wasm), .flags = cxx.items });
    dgmod.addCSourceFiles(.{ .files = globSorted(b, dg ++ "/lib/proj4lib/lib", ".cpp", false), .flags = cxx.items });
    dgmod.addCSourceFiles(.{ .files = globSorted(b, dg ++ "/lib/shapelib/lib", ".c", false), .flags = &c_flags });
    // wasm32-wasi: zig's libc++abi is built without exceptions -> any throw aborts
    if (wasm) dgmod.addCSourceFile(.{ .file = b.path("wasi_cxa_stub.cpp"), .flags = cxx.items });
    const libdg = b.addLibrary(.{ .name = "dglib", .root_module = dgmod });
    b.installArtifact(libdg);

    // ---- bench: geo -> Q2DI loop (+ fatal hook test where exceptions exist)
    const bench = addExe(b, "bench", "bench.cpp", target, optimize, cxx.items, libdg);
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Run the geo -> Q2DI benchmark (pass N after --)").dependOn(&run_bench.step);

    // ---- libgeoarrow (C99 + vendored nanoarrow, namespaced so it can sit next to
    // pyarrow or another nanoarrow copy)
    const cfg = b.addConfigHeader(.{ .style = .{ .cmake = b.path(ga ++ "/geoarrow/geoarrow_config.h.in") }, .include_path = "geoarrow/geoarrow_config.h" }, .{
        .GEOARROW_VERSION_MAJOR = 0,
        .GEOARROW_VERSION_MINOR = 2,
        .GEOARROW_VERSION_PATCH = 0,
        .GEOARROW_VERSION = "0.2.0-SNAPSHOT",
        .GEOARROW_USE_FAST_FLOAT_DEFINE = "#define GEOARROW_USE_FAST_FLOAT 1",
        .GEOARROW_USE_RYU_DEFINE = "#define GEOARROW_USE_RYU 1",
        .GEOARROW_NAMESPACE_DEFINE = "#define GEOARROW_NAMESPACE DgGeoArrow",
    });
    const gamod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true, .pic = if (wasm) null else true });
    gamod.addConfigHeader(cfg);
    gamod.addIncludePath(b.path(ga));
    gamod.addIncludePath(b.path(ga ++ "/vendor"));
    // = GEOARROW_SOURCES in geoarrow-c's CMakeLists.txt + its double print/parse helpers
    gamod.addCSourceFiles(.{ .root = b.path(ga ++ "/geoarrow"), .files = &.{
        "schema.c",      "schema_view.c", "metadata.c",   "kernel.c",        "builder.c",
        "array_view.c",  "util.c",        "visitor.c",    "geometry.c",      "native_writer.c",
        "scalar_udf.c",  "wkb_reader.c",  "wkb_writer.c", "wkt_reader.c",    "wkt_writer.c",
        "array_reader.c", "array_writer.c", "double_print.c", "ryu/d2s.c",
    }, .flags = &.{ "-std=c99", ga_def } });
    gamod.addCSourceFiles(.{ .root = b.path(ga ++ "/geoarrow"), .files = &.{"double_parse_fast_float.cc"}, .flags = &.{ "-std=c++11", ga_def } });
    gamod.addCSourceFiles(.{ .root = b.path(ga ++ "/vendor/nanoarrow"), .files = &.{"nanoarrow.c"}, .flags = &.{ "-std=c99", ga_def } });
    const libga = b.addLibrary(.{ .name = "geoarrow", .root_module = gamod });
    b.installArtifact(libga);
    const ga_lib = GaLib{ .lib = libga, .cfg = cfg };


    // ---- libdggrid: public C API (dggrid.zig, include/dggrid.h) over the C++ core
    // (dgcore.cpp). wasm: a reactor module (no main, _initialize runs the C++ static
    // constructors) exporting exactly the C API.
    const api = addApiModule(b, target, optimize, cxx.items, libdg, ga_lib);
    if (wasm) {
        api.export_symbol_names = &api_exports;
        if (optimize != .Debug) api.strip = true;
        const wasm_lib = b.addExecutable(.{ .name = "dggrid", .root_module = api });
        wasm_lib.entry = .disabled;
        wasm_lib.wasi_exec_model = .reactor;
        b.installArtifact(wasm_lib);
    } else {
        b.installArtifact(b.addLibrary(.{ .name = "dggrid", .root_module = api, .linkage = .dynamic }));
    }
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("include/dggrid.h"), "include/dggrid.h").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("include/dggrid_arrow.h"), "include/dggrid_arrow.h").step);

    if (wasm) return;

    const tests = b.addTest(.{ .root_module = addApiModule(b, target, optimize, cxx.items, libdg, ga_lib) });
    b.step("test", "Run the C API tests").dependOn(&b.addRunArtifact(tests).step);

    // ---- dggrid CLI from the patched copy, to verify the rewrite against upstream
    const climod = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    for (dg_includes) |p| climod.addIncludePath(b.path(p));
    climod.addCSourceFiles(.{ .files = globSorted(b, dg ++ "/lib/dgaplib/lib", ".cpp", false), .flags = cxx.items });
    climod.addCSourceFiles(.{ .files = globSorted(b, dg ++ "/apps/dggrid", ".cpp", false), .flags = cxx.items });
    climod.linkLibrary(libdg);
    const cli = b.addExecutable(.{ .name = "dggrid", .root_module = climod });
    const install_cli = b.addInstallArtifact(cli, .{});
    b.step("dggrid", "Build the dggrid CLI from the patched copy").dependOn(&install_cli.step);

    // ---- smoke: dglib cell -> WKT -> GeoArrow WKB array
    var smoke_flags: std.ArrayList([]const u8) = .empty;
    smoke_flags.appendSlice(b.allocator, cxx.items) catch @panic("OOM");
    smoke_flags.append(b.allocator, ga_def) catch @panic("OOM");
    const smoke = addExe(b, "smoke", "smoke.cpp", target, optimize, smoke_flags.items, libdg);
    smoke.root_module.addConfigHeader(cfg);
    smoke.root_module.addIncludePath(b.path(ga));
    smoke.root_module.addIncludePath(b.path(ga ++ "/vendor"));
    smoke.root_module.linkLibrary(libga);
    b.step("smoke", "Run the dglib + geoarrow smoke test").dependOn(&b.addRunArtifact(smoke).step);
}

const api_exports = [_][]const u8{
    "dg_igeo7_new",      "dg_preset_new",      "dg_ctx_new",        "dg_ctx_free",
    "dg_last_error",     "dg_ctx_datum",       "dg_ctx_set_lon_wrap",
    "dg_arrow_geo_to_z7", "dg_arrow_lonlat_to_z7", "dg_arrow_z7_to_points", "dg_arrow_z7_to_polygons",
    "dg_arrow_release_schema", "dg_arrow_release_array",
    "dg_geo_to_z7",      "dg_z7_to_centroid",  "dg_z7_to_boundary", "dg_z7_res",
    "dg_z7_to_string",   "dg_z7_from_string",  "dg_alloc",          "dg_free",
};

const GaLib = struct { lib: *std.Build.Step.Compile, cfg: *std.Build.Step.ConfigHeader };
const ga_def = "-DNANOARROW_NAMESPACE=DgGeoArrowNanoarrow";

fn addApiModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
    libdg: *std.Build.Step.Compile,
    ga_lib: GaLib,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("dggrid.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    for (dg_includes) |p| mod.addIncludePath(b.path(p));
    mod.addCSourceFile(.{ .file = b.path("dgcore.cpp"), .flags = flags });
    mod.linkLibrary(libdg);
    // dgarrow.c: Arrow C Data + GeoArrow over dggrid.h, no DGGRID classes
    mod.addIncludePath(b.path("include"));
    mod.addConfigHeader(ga_lib.cfg);
    mod.addIncludePath(b.path(ga));
    mod.addIncludePath(b.path(ga ++ "/vendor"));
    mod.addCSourceFile(.{ .file = b.path("dgarrow.c"), .flags = &.{ "-std=c99", ga_def } });
    mod.linkLibrary(ga_lib.lib);
    return mod;
}

fn addExe(
    b: *std.Build,
    name: []const u8,
    src: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flags: []const []const u8,
    libdg: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    for (dg_includes) |p| mod.addIncludePath(b.path(p));
    mod.addCSourceFile(.{ .file = b.path(src), .flags = flags });
    mod.linkLibrary(libdg);
    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    b.installArtifact(exe);
    return exe;
}

/// Sorted, non-recursive list of `dir/*<ext>` (as in the root build.zig). With
/// `skip_io`, file reader/writer classes (DgIn*, DgOut*) are left out.
fn globSorted(b: *std.Build, dir: []const u8, ext: []const u8, skip_io: bool) []const []const u8 {
    const io = b.graph.io;
    var d = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s} ({t}); run ./setup_src.sh first", .{ dir, err });
    defer d.close(io);

    var files: std.ArrayList([]const u8) = .empty;
    var it = d.iterate();
    while (it.next(io) catch |err| std.debug.panic("iterating {s}: {t}", .{ dir, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ext)) continue;
        if (skip_io and (std.mem.startsWith(u8, entry.name, "DgIn") or std.mem.startsWith(u8, entry.name, "DgOut"))) continue;
        files.append(b.allocator, b.fmt("{s}/{s}", .{ dir, entry.name })) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    return files.items;
}
