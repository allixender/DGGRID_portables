const std = @import("std");

fn addDir(b: *std.Build, m: *std.Build.Module, dir: []const u8, flags: []const []const u8) void {
    const io = b.graph.io;
    var d = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch @panic("open");
    defer d.close(io);
    var it = d.iterate();
    var list: std.ArrayList([]const u8) = .empty;
    while (it.next(io) catch @panic("it")) |e| {
        if (e.kind != .file) continue;
        if (std.mem.endsWith(u8, e.name, ".cpp") or std.mem.endsWith(u8, e.name, ".c"))
            list.append(b.allocator, b.fmt("{s}/{s}", .{ dir, e.name })) catch @panic("oom");
    }
    m.addCSourceFiles(.{ .files = list.items, .flags = flags });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sanitize = b.option(bool, "ubsan", "sanitize_c") orelse false;
    const cxx = &[_][]const u8{ "-std=c++11", "-D_USE_MATH_DEFINES", "-w" };
    const cc = &[_][]const u8{ "-std=c99", "-w" };
    const m = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true,
        .sanitize_c = if (sanitize) .trap else .off });
    for ([_][]const u8{ "src/lib/dglib/include", "src/lib/dgaplib/include", "src/lib/proj4lib/include",
        "src/lib/shapelib/include", "src/lib/shapelib/include/shapelib", "src/apps/dggrid" }) |p| m.addIncludePath(b.path(p));
    addDir(b, m, "src/lib/dglib/lib", cxx);
    addDir(b, m, "src/lib/dgaplib/lib", cxx);
    addDir(b, m, "src/lib/proj4lib/lib", cxx);
    addDir(b, m, "src/lib/shapelib/lib", cc);
    addDir(b, m, "src/apps/dggrid", cxx);
    const exe = b.addExecutable(.{ .name = "dggrid", .root_module = m });
    b.installArtifact(exe);
}
