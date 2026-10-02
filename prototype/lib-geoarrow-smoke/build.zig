const std = @import("std");

fn globSorted(b: *std.Build, dir: []const u8, exts: []const []const u8) []const []const u8 {
    const io = b.graph.io;
    var d = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch @panic("openDir");
    defer d.close(io);
    var it = d.iterate();
    var list: std.ArrayList([]const u8) = .empty;
    while (it.next(io) catch @panic("iterate")) |e| {
        if (e.kind != .file) continue;
        for (exts) |x| if (std.mem.endsWith(u8, e.name, x)) {
            list.append(b.allocator, b.fmt("{s}/{s}", .{ dir, e.name })) catch @panic("oom");
        };
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, a: []const u8, c: []const u8) bool { return std.mem.lessThan(u8, a, c); }
    }.lt);
    return list.items;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- libgeoarrow (C99 + vendored nanoarrow, namespaced) ----
    const cfg = b.addConfigHeader(.{ .style = .{ .cmake = b.path("ga/geoarrow/geoarrow_config.h.in") }, .include_path = "geoarrow/geoarrow_config.h" }, .{
        .GEOARROW_VERSION_MAJOR = 0, .GEOARROW_VERSION_MINOR = 2, .GEOARROW_VERSION_PATCH = 0,
        .GEOARROW_VERSION = "0.2.0-SNAPSHOT",
        .GEOARROW_USE_FAST_FLOAT_DEFINE = "#define GEOARROW_USE_FAST_FLOAT 1",
        .GEOARROW_USE_RYU_DEFINE = "#define GEOARROW_USE_RYU 1",
        .GEOARROW_NAMESPACE_DEFINE = "#define GEOARROW_NAMESPACE DgGeoArrow",
    });
    const ga = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
    ga.addConfigHeader(cfg);
    ga.addIncludePath(b.path("ga"));
    ga.addIncludePath(b.path("ga/vendor"));
    const ga_defs = [_][]const u8{ "-DNANOARROW_NAMESPACE=DgGeoArrowNanoarrow" };
    const ga_c = [_][]const u8{
        "schema.c", "schema_view.c", "metadata.c", "kernel.c", "builder.c", "array_view.c", "util.c",
        "visitor.c", "geometry.c", "native_writer.c", "scalar_udf.c", "wkb_reader.c", "wkb_writer.c",
        "wkt_reader.c", "wkt_writer.c", "array_reader.c", "array_writer.c", "double_print.c", "ryu/d2s.c",
    };
    ga.addCSourceFiles(.{ .root = b.path("ga/geoarrow"), .files = &ga_c, .flags = &(.{ "-std=c99" } ++ ga_defs) });
    ga.addCSourceFiles(.{ .root = b.path("ga/geoarrow"), .files = &.{"double_parse_fast_float.cc"}, .flags = &(.{ "-std=c++11" } ++ ga_defs) });
    ga.addCSourceFiles(.{ .root = b.path("ga/vendor/nanoarrow"), .files = &.{"nanoarrow.c"}, .flags = &(.{ "-std=c99" } ++ ga_defs) });
    const libga = b.addLibrary(.{ .name = "geoarrow", .root_module = ga });
    libga.installHeadersDirectory(b.path("ga/geoarrow"), "geoarrow", .{ .include_extensions = &.{ ".h", ".hpp" } });
    libga.installConfigHeader(cfg);
    b.installArtifact(libga);

    // ---- libdglib (dglib + proj4lib + shapelib, no GDAL) ----
    const dg = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    for ([_][]const u8{ "dg/lib/dglib/include", "dg/lib/proj4lib/include", "dg/lib/shapelib/include", "dg/lib/shapelib/include/shapelib" }) |p| dg.addIncludePath(b.path(p));
    const cxx = &[_][]const u8{ "-std=c++11", "-D_USE_MATH_DEFINES", "-w" };
    dg.addCSourceFiles(.{ .files = globSorted(b, "dg/lib/dglib/lib", &.{".cpp"}), .flags = cxx });
    dg.addCSourceFiles(.{ .files = globSorted(b, "dg/lib/proj4lib/lib", &.{".cpp"}), .flags = cxx });
    dg.addCSourceFiles(.{ .files = globSorted(b, "dg/lib/shapelib/lib", &.{".c"}), .flags = &.{ "-std=c99", "-w" } });
    const libdg = b.addLibrary(.{ .name = "dglib", .root_module = dg });
    b.installArtifact(libdg);

    // ---- smoke: dglib cell -> WKT -> geoarrow WKB array ----
    const sm = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    sm.addCSourceFiles(.{ .files = &.{"smoke.cpp"}, .flags = &.{ "-std=c++11", "-D_USE_MATH_DEFINES", "-DNANOARROW_NAMESPACE=DgGeoArrowNanoarrow" } });
    sm.addIncludePath(b.path("dg/lib/dglib/include"));
    sm.addIncludePath(b.path("ga"));
    sm.addIncludePath(b.path("ga/vendor"));
    sm.addConfigHeader(cfg);
    sm.linkLibrary(libdg);
    sm.linkLibrary(libga);
    const smoke = b.addExecutable(.{ .name = "dg_geoarrow_smoke", .root_module = sm });
    b.installArtifact(smoke);
    const run = b.addRunArtifact(smoke);
    b.step("smoke", "run dglib+geoarrow smoke test").dependOn(&run.step);
}
