//! dggrid.zig: public C ABI of the prototype IGEO7 library (see include/dggrid.h).
//!
//! DGGRID 9.2 aperture 7 hexagon presets (IGEO7v2 = ISEA7HLZ, IVEA7HL, ..) + Z7 index, via
//! the C++ core in dgcore.cpp (the only code touching DGGRID). This layer owns the handle and its error
//! message, validates all input (on wasm a DGGRID fatal error can only trap), groups
//! batches by resolution, and does the Z7 int <-> string / resolution work itself.
//!
//! Z7 int (DgZ7System.cpp): bits 60-63 base cell (quad 0-11), then 20 radix-7 digits of
//! 3 bits each, res 1 at bits 57-59 ... res 20 at bits 0-2; digits beyond the cell's
//! resolution are 7. Z7 string: 2-digit quad + one digit per resolution. The children of a
//! pentagon skip one digit (DgZ7System::setAddNdxChildren), ids in that sub-sequence don't
//! exist.

const std = @import("std");

pub const max_res = 20;

pub const DG_OK: c_int = 0;
pub const DG_EINVAL: c_int = -1;
pub const DG_EDGGRID: c_int = -2;
pub const DG_ENOMEM: c_int = -3;

pub const DG_PROJ_ISEA: c_int = 0;
pub const DG_PROJ_IVEA: c_int = 1;
pub const DG_DATUM_AUTHALIC: c_int = 0;
pub const DG_DATUM_WGS84: c_int = 1;

pub const DG_WRAP: c_int = 0;
pub const DG_UNWRAP_EAST: c_int = 1;
pub const DG_UNWRAP_WEST: c_int = 2;

pub const DG_IGEO7V2: c_int = 0;
pub const DG_IGEO7V1: c_int = 1;
pub const DG_IVEA7HL: c_int = 2;
pub const DG_IVEA7HS: c_int = 3;

// upstream dggs_type presets (SubOpDGG.cpp): L = WGS84 input/output + ISEAL orientation,
// S = authalic sphere + ISEA orientation. vert0 lat = the exact icosahedron vertex (NaN here)
const Preset = struct { proj: c_int, datum: c_int, vert0_lon: f64 };
const presets = [_]Preset{
    .{ .proj = DG_PROJ_ISEA, .datum = DG_DATUM_WGS84, .vert0_lon = 11.20 }, // IGEO7v2 = ISEA7HLZ
    .{ .proj = DG_PROJ_ISEA, .datum = DG_DATUM_AUTHALIC, .vert0_lon = 11.25 }, // IGEO7v1 = ISEA7HSZ
    .{ .proj = DG_PROJ_IVEA, .datum = DG_DATUM_WGS84, .vert0_lon = 11.20 }, // IVEA7HL
    .{ .proj = DG_PROJ_IVEA, .datum = DG_DATUM_AUTHALIC, .vert0_lon = 11.25 }, // IVEA7HS
};

// ---- C++ core (dgcore.cpp) ----
const Core = opaque {};
extern fn dgc_new(proj: [*:0]const u8, wgs84: c_int, vert0_lon: f64, vert0_lat: f64, azimuth: f64, max_res: c_int, err: [*]u8, err_len: usize) ?*Core;
extern fn dgc_free(core: *Core) void;
extern fn dgc_set_lon_wrap(core: *Core, mode: c_int) void;
extern fn dgc_last_error(core: *const Core) [*:0]const u8;
extern fn dgc_geo_to_z7(core: *Core, res: c_int, lon: [*]const f64, lat: [*]const f64, n: usize, out: [*]u64) c_int;
extern fn dgc_z7_to_centroid(core: *Core, res: c_int, z7: [*]const u64, n: usize, lon: [*]f64, lat: [*]f64) c_int;
extern fn dgc_z7_to_boundary(core: *Core, res: c_int, z7: [*]const u64, n: usize, lonlat: [*]f64, nverts: [*]u8) c_int;

pub const Ctx = struct {
    core: *Core,
    datum: c_int,
    err: [256:0]u8 = [_:0]u8{0} ** 256,

    fn fail(ctx: *Ctx, code: c_int, comptime fmt: []const u8, args: anytype) c_int {
        _ = std.fmt.bufPrintZ(&ctx.err, fmt, args) catch {};
        return code;
    }

    fn failCore(ctx: *Ctx) c_int {
        return ctx.fail(DG_EDGGRID, "DGGRID: {s}", .{dgc_last_error(ctx.core)});
    }
};

// error of the last failed dg_ctx_new, returned by dg_last_error(NULL)
var new_err: [256:0]u8 = [_:0]u8{0} ** 256;

// ---- Z7 index arithmetic (no DGGRID needed): z7.zig ----

const z7lib = @import("z7.zig");
const digit = z7lib.digit;
pub const z7Res = z7lib.res;

test {
    _ = z7lib;
}

fn checkRes(ctx: *Ctx, res: c_int) ?c_int {
    if (res < 0 or res > max_res)
        return ctx.fail(DG_EINVAL, "resolution {d} out of range 0..{d}", .{ res, max_res });
    return null;
}

// ---- exported C API ----

/// IGEO7 = alias for IGEO7v2, same as upstream's dggs_type IGEO7 since 9.1
export fn dg_igeo7_new() ?*Ctx {
    return dg_preset_new(DG_IGEO7V2);
}

export fn dg_preset_new(preset: c_int) ?*Ctx {
    if (preset < 0 or preset >= presets.len) {
        _ = std.fmt.bufPrintZ(&new_err, "unknown preset {d}", .{preset}) catch {};
        return null;
    }
    const p = presets[@intCast(preset)];
    return dg_ctx_new(p.proj, p.datum, p.vert0_lon, std.math.nan(f64), 0.0);
}

export fn dg_ctx_new(proj: c_int, datum: c_int, vert0_lon: f64, vert0_lat: f64, azimuth: f64) ?*Ctx {
    if ((proj != DG_PROJ_ISEA and proj != DG_PROJ_IVEA) or (datum != DG_DATUM_AUTHALIC and datum != DG_DATUM_WGS84)) {
        _ = std.fmt.bufPrintZ(&new_err, "unknown projection {d} or datum {d}", .{ proj, datum }) catch {};
        return null;
    }
    if (!std.math.isFinite(vert0_lon) or std.math.isInf(vert0_lat) or !std.math.isFinite(azimuth) or
        @abs(vert0_lat) > 90 or @abs(vert0_lon) > 180 or azimuth < 0 or azimuth >= 360)
    {
        _ = std.fmt.bufPrintZ(&new_err, "invalid orientation vert0 ({d}, {d}) azimuth {d}", .{ vert0_lon, vert0_lat, azimuth }) catch {};
        return null;
    }
    const ctx = std.heap.c_allocator.create(Ctx) catch {
        _ = std.fmt.bufPrintZ(&new_err, "out of memory", .{}) catch {};
        return null;
    };
    const proj_name: [*:0]const u8 = if (proj == DG_PROJ_IVEA) "IVEA" else "ISEA";
    const core = dgc_new(proj_name, @intFromBool(datum == DG_DATUM_WGS84), vert0_lon, vert0_lat, azimuth, max_res, &new_err, new_err.len) orelse {
        std.heap.c_allocator.destroy(ctx);
        return null;
    };
    ctx.* = .{ .core = core, .datum = datum };
    return ctx;
}

/// boundaries across the antimeridian: DG_UNWRAP_EAST (default), DG_UNWRAP_WEST, DG_WRAP
export fn dg_ctx_set_lon_wrap(ctx: *Ctx, mode: c_int) c_int {
    if (mode != DG_WRAP and mode != DG_UNWRAP_EAST and mode != DG_UNWRAP_WEST)
        return ctx.fail(DG_EINVAL, "unknown longitude wrap mode {d}", .{mode});
    dgc_set_lon_wrap(ctx.core, mode);
    return DG_OK;
}

export fn dg_ctx_datum(ctx: *const Ctx) c_int {
    return ctx.datum;
}

/// for dgarrow.c, not part of the public API
export fn dgz_set_error(ctx: *Ctx, msg: [*:0]const u8) void {
    _ = ctx.fail(DG_EINVAL, "{s}", .{std.mem.span(msg)});
}

export fn dg_ctx_free(ctx: ?*Ctx) void {
    const c = ctx orelse return;
    dgc_free(c.core);
    std.heap.c_allocator.destroy(c);
}

export fn dg_last_error(ctx: ?*const Ctx) [*:0]const u8 {
    const c = ctx orelse return &new_err;
    return &c.err;
}

/// cells containing the points (degrees) at resolution res, as Z7 ints
export fn dg_geo_to_z7(ctx: *Ctx, res: c_int, lon: [*]const f64, lat: [*]const f64, n: usize, out: [*]u64) c_int {
    if (checkRes(ctx, res)) |e| return e;
    for (0..n) |i| {
        if (!std.math.isFinite(lon[i]) or !std.math.isFinite(lat[i]) or @abs(lat[i]) > 90 or @abs(lon[i]) > 360)
            return ctx.fail(DG_EINVAL, "point {d}: invalid lon/lat ({d}, {d})", .{ i, lon[i], lat[i] });
    }
    if (dgc_geo_to_z7(ctx.core, res, lon, lat, n, out) != 0) return ctx.failCore();
    return DG_OK;
}

/// resolution of a Z7 int, -1 if invalid
export fn dg_z7_res(z: u64) c_int {
    return if (z7Res(z)) |r| r else -1;
}

/// writes the Z7 string + NUL into buf, returns its length, -1 if z is invalid or buf too small
export fn dg_z7_to_string(z: u64, buf: [*]u8, len: usize) c_int {
    const res = z7Res(z) orelse return -1;
    const n = 2 + @as(usize, res);
    if (len < n + 1) return -1;
    const quad: u8 = @intCast(z >> 60);
    buf[0] = '0' + quad / 10;
    buf[1] = '0' + quad % 10;
    var r: u5 = 1;
    while (r <= res) : (r += 1) buf[1 + @as(usize, r)] = '0' + @as(u8, digit(z, r));
    buf[n] = 0;
    return @intCast(n);
}

/// parses a Z7 string (len bytes, no NUL needed), DG_EINVAL if malformed or no such cell
export fn dg_z7_from_string(s: [*]const u8, len: usize, out: *u64) c_int {
    if (len < 2 or len > 2 + max_res) return DG_EINVAL;
    for (s[0..len]) |ch| if (ch < '0' or ch > '9') return DG_EINVAL;
    const quad: u64 = (s[0] - '0') * 10 + (s[1] - '0');
    if (quad > 11) return DG_EINVAL;
    var z: u64 = quad << 60;
    var r: u5 = 1;
    while (r <= max_res) : (r += 1) {
        const i = 1 + @as(usize, r);
        const d: u64 = if (i < len) s[i] - '0' else 7;
        if (i < len and d > 6) return DG_EINVAL;
        z |= d << @as(u6, 20 - @as(u6, r)) * 3;
    }
    if (z7Res(z) == null) return DG_EINVAL;
    out.* = z;
    return DG_OK;
}

// ---- Z7 topology, batch, no ctx needed (ctx only carries the error message) ----

fn failOpt(ctx: ?*Ctx, code: c_int, comptime fmt: []const u8, args: anytype) c_int {
    return if (ctx) |c| c.fail(code, fmt, args) else code;
}

fn validRes(ctx: ?*Ctx, z7: [*]const u64, i: usize) ?u5 {
    const r = z7Res(z7[i]);
    if (r == null) _ = failOpt(ctx, DG_EINVAL, "z7[{d}] = 0x{x:0>16} is not a valid Z7 index", .{ i, z7[i] });
    return r;
}

/// resolution of each id, -1 for an invalid one
export fn dg_z7_res_batch(z7: [*]const u64, n: usize, out: [*]i8) c_int {
    for (0..n) |i| out[i] = if (z7Res(z7[i])) |r| @intCast(r) else -1;
    return DG_OK;
}

/// ancestor at resolution res (0..cell's resolution), res -1 = one level up
export fn dg_z7_parent(ctx: ?*Ctx, z7: [*]const u64, n: usize, res: c_int, out: [*]u64) c_int {
    if (res < -1 or res > max_res)
        return failOpt(ctx, DG_EINVAL, "parent resolution {d} out of range -1..{d}", .{ res, max_res });
    for (0..n) |i| {
        const r = validRes(ctx, z7, i) orelse return DG_EINVAL;
        if (res == -1 and r == 0)
            return failOpt(ctx, DG_EINVAL, "z7[{d}] is a base cell, it has no parent", .{i});
        if (res > r)
            return failOpt(ctx, DG_EINVAL, "z7[{d}] has resolution {d}, no parent at {d}", .{ i, r, res });
        out[i] = z7lib.parent(z7[i], if (res == -1) r - 1 else @intCast(res));
    }
    return DG_OK;
}

/// the 7 children, out[7 * i + digit], a pentagon's skipped digit = DG_Z7_NONE
export fn dg_z7_children(ctx: ?*Ctx, z7: [*]const u64, n: usize, out: [*]u64) c_int {
    for (0..n) |i| {
        const r = validRes(ctx, z7, i) orelse return DG_EINVAL;
        if (r == max_res) return failOpt(ctx, DG_EINVAL, "z7[{d}] has resolution {d}, no children", .{ i, max_res });
        z7lib.children(z7[i], r, out[7 * i ..][0..7]);
    }
    return DG_OK;
}

/// the 6 neighbours, out[6 * i + direction - 1] in GBT direction order 1..6, a pentagon's
/// missing one = DG_Z7_NONE
export fn dg_z7_neighbors(ctx: ?*Ctx, z7: [*]const u64, n: usize, out: [*]u64) c_int {
    for (0..n) |i| {
        const r = validRes(ctx, z7, i) orelse return DG_EINVAL;
        z7lib.neighbors(z7[i], r, out[6 * i ..][0..6]);
    }
    return DG_OK;
}

/// runs of equal resolution -> one core call each; validates every id first
fn forEachResRun(ctx: *Ctx, z7: [*]const u64, n: usize, comptime f: anytype, args: anytype) c_int {
    for (0..n) |i| {
        if (z7Res(z7[i]) == null) return ctx.fail(DG_EINVAL, "z7[{d}] = 0x{x:0>16} is not a valid Z7 index", .{ i, z7[i] });
    }
    var i: usize = 0;
    while (i < n) {
        const res = z7Res(z7[i]).?;
        var j = i + 1;
        while (j < n and z7Res(z7[j]).? == res) : (j += 1) {}
        if (f(ctx.core, res, z7 + i, j - i, i, args) != 0) return ctx.failCore();
        i = j;
    }
    return DG_OK;
}

/// cell centre points in degrees
export fn dg_z7_to_centroid(ctx: *Ctx, z7: [*]const u64, n: usize, lon: [*]f64, lat: [*]f64) c_int {
    return forEachResRun(ctx, z7, n, struct {
        fn call(core: *Core, res: u5, ids: [*]const u64, m: usize, off: usize, a: anytype) c_int {
            return dgc_z7_to_centroid(core, res, ids, m, a[0] + off, a[1] + off);
        }
    }.call, .{ lon, lat });
}

/// cell boundaries in degrees: lonlat holds n * 6 (lon, lat) pairs, nverts 6 or 5
/// (pentagons, 6th pair NaN)
export fn dg_z7_to_boundary(ctx: *Ctx, z7: [*]const u64, n: usize, lonlat: [*]f64, nverts: [*]u8) c_int {
    return forEachResRun(ctx, z7, n, struct {
        fn call(core: *Core, res: u5, ids: [*]const u64, m: usize, off: usize, a: anytype) c_int {
            return dgc_z7_to_boundary(core, res, ids, m, a[0] + off * 12, a[1] + off);
        }
    }.call, .{ lonlat, nverts });
}

/// memory for callers without their own allocator in this address space (wasm/JS)
export fn dg_alloc(n: usize) ?*anyopaque {
    return std.c.malloc(n);
}

export fn dg_free(p: ?*anyopaque) void {
    std.c.free(p);
}

// ---- tests (zig build test) ----

const testing = std.testing;

test "z7: valid ids per resolution = cell count 10 * 7^r + 2, deleted pentagon digits rejected" {
    var r: u5 = 0;
    while (r <= 5) : (r += 1) {
        const n = std.math.pow(u64, 7, r);
        var valid: u64 = 0;
        for (0..12) |q| {
            for (0..n) |k| {
                var z: u64 = @as(u64, q) << 60;
                var rest = k;
                var d: u5 = max_res;
                while (d > 0) : (d -= 1) {
                    var dv: u64 = 7;
                    if (d <= r) {
                        dv = rest % 7;
                        rest /= 7;
                    }
                    z |= dv << @as(u6, 20 - @as(u6, d)) * 3;
                }
                if (z7Res(z)) |zr| {
                    try testing.expectEqual(r, zr);
                    valid += 1;
                }
            }
        }
        try testing.expectEqual(10 * n + 2, valid);
    }
    var z: u64 = undefined;
    try testing.expectEqual(DG_EINVAL, dg_z7_from_string("002", 3, &z));
    try testing.expectEqual(DG_EINVAL, dg_z7_from_string("00002", 5, &z));
    try testing.expectEqual(DG_EINVAL, dg_z7_from_string("0605", 4, &z));
    try testing.expectEqual(DG_OK, dg_z7_from_string("005", 3, &z));
    try testing.expectEqual(DG_OK, dg_z7_from_string("0602", 4, &z));
}

test "z7 string round trip and resolution" {
    var z: u64 = undefined;
    try testing.expectEqual(DG_OK, dg_z7_from_string("0401234", 7, &z));
    try testing.expectEqual(@as(c_int, 5), dg_z7_res(z));
    var buf: [32]u8 = undefined;
    try testing.expectEqual(@as(c_int, 7), dg_z7_to_string(z, &buf, buf.len));
    try testing.expectEqualStrings("0401234", std.mem.sliceTo(&buf, 0));
    try testing.expectEqual(DG_EINVAL, dg_z7_from_string("12", 2, &z)); // quad 12
    try testing.expectEqual(DG_EINVAL, dg_z7_from_string("0407", 4, &z)); // digit 7
    try testing.expectEqual(@as(c_int, -1), dg_z7_res(z & ~@as(u64, 7))); // res 20 digit 0 after padding
}

// res 9 ids from the upstream 9.1 dggrid CLI (same on 9.2), TRANSFORM_POINTS GEO -> HIERNDX Z7 INT64
const tartu_lon = 26.729;
const tartu_lat = 58.378;
const tartu_ids = [_]struct { preset: c_int, z7: u64 }{
    .{ .preset = DG_IGEO7V2, .z7 = 0x004252c3ffffffff },
    .{ .preset = DG_IGEO7V1, .z7 = 0x0042c499ffffffff },
    .{ .preset = DG_IVEA7HL, .z7 = 0x0042c50dffffffff },
    .{ .preset = DG_IVEA7HS, .z7 = 0x0042c631ffffffff },
};

test "presets: Tartu res 9 id = CLI, centroid + boundary round trip" {
    for (tartu_ids) |t| {
        const ctx = dg_preset_new(t.preset) orelse return error.CtxNew;
        defer dg_ctx_free(ctx);

        const lon = [_]f64{ tartu_lon, -122.7083, 0.0 };
        const lat = [_]f64{ tartu_lat, 42.1947, 0.0 };
        var z7: [3]u64 = undefined;
        try testing.expectEqual(DG_OK, dg_geo_to_z7(ctx, 9, &lon, &lat, 3, &z7));
        try testing.expectEqual(t.z7, z7[0]);
        for (z7) |z| try testing.expectEqual(@as(c_int, 9), dg_z7_res(z));

        var clon: [3]f64 = undefined;
        var clat: [3]f64 = undefined;
        try testing.expectEqual(DG_OK, dg_z7_to_centroid(ctx, &z7, 3, &clon, &clat));
        // res 9 cells are ~1.7 km across: centre within 0.02 deg of the point
        for (0..3) |i| {
            try testing.expect(@abs(clon[i] - lon[i]) < 0.02);
            try testing.expect(@abs(clat[i] - lat[i]) < 0.02);
        }
        // centroid lies in the same cell
        var z7b: [3]u64 = undefined;
        try testing.expectEqual(DG_OK, dg_geo_to_z7(ctx, 9, &clon, &clat, 3, &z7b));
        try testing.expectEqualSlices(u64, &z7, &z7b);

        var ll: [3 * 12]f64 = undefined;
        var nv: [3]u8 = undefined;
        try testing.expectEqual(DG_OK, dg_z7_to_boundary(ctx, &z7, 3, &ll, &nv));
        try testing.expectEqualSlices(u8, &.{ 6, 6, 6 }, &nv);
    }
}

test "longitude wrap: cell across the antimeridian, default east, centroid stays a normal point" {
    const ctx = dg_preset_new(DG_IGEO7V2) orelse return error.CtxNew;
    defer dg_ctx_free(ctx);
    const z = [_]u64{0x1ae7ffffffffffff}; // res 3, CLI: lons 178.4 .. -175.7
    var ll: [12]f64 = undefined;
    var nv: [1]u8 = undefined;
    const Case = struct { mode: c_int, lo: f64, hi: f64 };
    for ([_]Case{
        .{ .mode = DG_UNWRAP_EAST, .lo = 170, .hi = 190 },
        .{ .mode = DG_UNWRAP_WEST, .lo = -190, .hi = -170 },
    }) |c| {
        try testing.expectEqual(DG_OK, dg_ctx_set_lon_wrap(ctx, c.mode));
        try testing.expectEqual(DG_OK, dg_z7_to_boundary(ctx, &z, 1, &ll, &nv));
        for (0..6) |v| try testing.expect(ll[2 * v] > c.lo and ll[2 * v] < c.hi);
    }
    try testing.expectEqual(DG_OK, dg_ctx_set_lon_wrap(ctx, DG_WRAP));
    try testing.expectEqual(DG_OK, dg_z7_to_boundary(ctx, &z, 1, &ll, &nv));
    var lo: f64 = 180;
    var hi: f64 = -180;
    for (0..6) |v| {
        lo = @min(lo, ll[2 * v]);
        hi = @max(hi, ll[2 * v]);
    }
    try testing.expect(hi - lo > 300);
    try testing.expectEqual(DG_EINVAL, dg_ctx_set_lon_wrap(ctx, 9));

    // default east again: vertex lon > 180 as input = the same place
    try testing.expectEqual(DG_OK, dg_ctx_set_lon_wrap(ctx, DG_UNWRAP_EAST));
    var clon: [1]f64 = undefined;
    var clat: [1]f64 = undefined;
    try testing.expectEqual(DG_OK, dg_z7_to_centroid(ctx, &z, 1, &clon, &clat));
    try testing.expect(@abs(clon[0]) <= 180);
    var back: [1]u64 = undefined;
    try testing.expectEqual(DG_OK, dg_geo_to_z7(ctx, 3, &clon, &clat, 1, &back));
    try testing.expectEqual(z[0], back[0]);
    const shifted = [_]f64{if (clon[0] < 0) clon[0] + 360 else clon[0] - 360};
    try testing.expectEqual(DG_OK, dg_geo_to_z7(ctx, 3, &shifted, &clat, 1, &back));
    try testing.expectEqual(z[0], back[0]);
    const too_far = [_]f64{361.0};
    try testing.expectEqual(DG_EINVAL, dg_geo_to_z7(ctx, 3, &too_far, &clat, 1, &back));
}

test "IVEA7HL by hand = the preset (vert0 lon 11.2, exact vertex lat)" {
    const ctx = dg_ctx_new(DG_PROJ_IVEA, DG_DATUM_WGS84, 11.2, std.math.nan(f64), 0.0) orelse return error.CtxNew;
    defer dg_ctx_free(ctx);
    const lon = [_]f64{tartu_lon};
    const lat = [_]f64{tartu_lat};
    var z7: [1]u64 = undefined;
    try testing.expectEqual(DG_OK, dg_geo_to_z7(ctx, 9, &lon, &lat, 1, &z7));
    try testing.expectEqual(@as(u64, 0x0042c50dffffffff), z7[0]);
}

test "poles and antimeridian don't trip the WGS84 latitude conversion" {
    for (presets, 0..) |_, p| {
        const ctx = dg_preset_new(@intCast(p)) orelse return error.CtxNew;
        defer dg_ctx_free(ctx);
        const lon = [_]f64{ 0.0, 180.0, -180.0, 180.0 };
        const lat = [_]f64{ 90.0, -90.0, 0.0, 89.9999999 };
        var z7: [4]u64 = undefined;
        for ([_]c_int{ 0, 1, 9, max_res }) |res| {
            try testing.expectEqual(DG_OK, dg_geo_to_z7(ctx, res, &lon, &lat, 4, &z7));
            var clon: [4]f64 = undefined;
            var clat: [4]f64 = undefined;
            try testing.expectEqual(DG_OK, dg_z7_to_centroid(ctx, &z7, 4, &clon, &clat));
            var ll: [4 * 12]f64 = undefined;
            var nv: [4]u8 = undefined;
            try testing.expectEqual(DG_OK, dg_z7_to_boundary(ctx, &z7, 4, &ll, &nv));
        }
    }
}

test "pentagons: base cells at res 0 and their centre children" {
    for (presets, 0..) |_, p| {
        const ctx = dg_preset_new(@intCast(p)) orelse return error.CtxNew;
        defer dg_ctx_free(ctx);
        var buf: [8]u8 = undefined;
        for (0..12) |q| {
            // res 3 centre child of base cell q: all digits 0 -> pentagon
            const s = std.fmt.bufPrint(&buf, "{d:0>2}000", .{q}) catch unreachable;
            var z: [1]u64 = undefined;
            try testing.expectEqual(DG_OK, dg_z7_from_string(s.ptr, s.len, &z[0]));
            var ll: [12]f64 = undefined;
            var nv: [1]u8 = undefined;
            try testing.expectEqual(DG_OK, dg_z7_to_boundary(ctx, &z, 1, &ll, &nv));
            try testing.expectEqual(@as(u8, 5), nv[0]);
            try testing.expect(std.math.isNan(ll[10]));
        }
    }
}

test "invalid input is rejected before DGGRID sees it" {
    const ctx = dg_igeo7_new() orelse return error.CtxNew;
    defer dg_ctx_free(ctx);
    const lon = [_]f64{0.0};
    const lat = [_]f64{91.0};
    var out: [1]u64 = undefined;
    try testing.expectEqual(DG_EINVAL, dg_geo_to_z7(ctx, 9, &lon, &lat, 1, &out));
    try testing.expectEqual(DG_EINVAL, dg_geo_to_z7(ctx, 21, &lon, &lon, 1, &out));
    const bad = [_]u64{0xffff_ffff_ffff_ffff};
    var c: [1]f64 = undefined;
    try testing.expectEqual(DG_EINVAL, dg_z7_to_centroid(ctx, &bad, 1, &c, &c));
    try testing.expect(std.mem.len(dg_last_error(ctx)) > 0);
    try testing.expect(dg_preset_new(99) == null);
    try testing.expect(dg_ctx_new(7, 0, 11.2, 58.0, 0.0) == null);
    try testing.expect(std.mem.len(dg_last_error(null)) > 0);
}

// Arrow C Data Interface round trip through dgarrow.c, consumer side in check_arrow.py
const ArrowSchema = extern struct {
    format: ?[*:0]const u8 = null,
    name: ?[*:0]const u8 = null,
    metadata: ?[*]const u8 = null,
    flags: i64 = 0,
    n_children: i64 = 0,
    children: ?[*]*ArrowSchema = null,
    dictionary: ?*ArrowSchema = null,
    release: ?*const fn (*ArrowSchema) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};
const ArrowArray = extern struct {
    length: i64 = 0,
    null_count: i64 = 0,
    offset: i64 = 0,
    n_buffers: i64 = 0,
    n_children: i64 = 0,
    buffers: ?[*]?*const anyopaque = null,
    children: ?[*]*ArrowArray = null,
    dictionary: ?*ArrowArray = null,
    release: ?*const fn (*ArrowArray) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};
extern fn dg_arrow_lonlat_to_z7(ctx: *Ctx, res: c_int, lon_s: *const ArrowSchema, lon: *const ArrowArray, lat_s: *const ArrowSchema, lat: *const ArrowArray, out_s: *ArrowSchema, out: *ArrowArray) c_int;
extern fn dg_arrow_geo_to_z7(ctx: *Ctx, res: c_int, in_s: *const ArrowSchema, in: *const ArrowArray, out_s: *ArrowSchema, out: *ArrowArray) c_int;
extern fn dg_arrow_z7_to_points(ctx: *Ctx, z7_s: *const ArrowSchema, z7: *const ArrowArray, encoding: c_int, out_s: *ArrowSchema, out: *ArrowArray) c_int;
extern fn dg_arrow_z7_to_polygons(ctx: *Ctx, z7_s: *const ArrowSchema, z7: *const ArrowArray, encoding: c_int, out_s: *ArrowSchema, out: *ArrowArray) c_int;

test "arrow: lon/lat -> z7 -> points -> z7, polygons, nulls, errors" {
    const ctx = dg_preset_new(DG_IGEO7V2) orelse return error.CtxNew;
    defer dg_ctx_free(ctx);

    var lon = [_]f64{ tartu_lon, 0.0, 0.0 };
    var lat = [_]f64{ tartu_lat, 0.0, std.math.nan(f64) };
    lon[2] = std.math.nan(f64); // NaN, NaN -> null
    var lon_buf = [_]?*const anyopaque{ null, &lon };
    var lat_buf = [_]?*const anyopaque{ null, &lat };
    const noop = struct {
        fn release(_: *ArrowSchema) callconv(.c) void {}
    };
    const f64_s = ArrowSchema{ .format = "g", .release = &noop.release }; // released = invalid
    const lon_a = ArrowArray{ .length = 3, .n_buffers = 2, .buffers = &lon_buf };
    const lat_a = ArrowArray{ .length = 3, .n_buffers = 2, .buffers = &lat_buf };

    var ids_s = ArrowSchema{};
    var ids = ArrowArray{};
    try testing.expectEqual(DG_OK, dg_arrow_lonlat_to_z7(ctx, 9, &f64_s, &lon_a, &f64_s, &lat_a, &ids_s, &ids));
    defer ids_s.release.?(&ids_s);
    defer ids.release.?(&ids);
    try testing.expectEqual(@as(i64, 3), ids.length);
    try testing.expectEqual(@as(i64, 1), ids.null_count);
    const vals: [*]const u64 = @ptrCast(@alignCast(ids.buffers.?[1].?));
    try testing.expectEqual(@as(u64, 0x004252c3ffffffff), vals[0]);

    var pts_s = ArrowSchema{};
    var pts = ArrowArray{};
    try testing.expectEqual(DG_OK, dg_arrow_z7_to_points(ctx, &ids_s, &ids, 0, &pts_s, &pts));
    defer pts_s.release.?(&pts_s);
    defer pts.release.?(&pts);
    try testing.expectEqual(@as(i64, 1), pts.null_count);

    var back_s = ArrowSchema{};
    var back = ArrowArray{};
    try testing.expectEqual(DG_OK, dg_arrow_geo_to_z7(ctx, 9, &pts_s, &pts, &back_s, &back));
    defer back_s.release.?(&back_s);
    defer back.release.?(&back);
    const back_vals: [*]const u64 = @ptrCast(@alignCast(back.buffers.?[1].?));
    try testing.expectEqual(vals[0], back_vals[0]);
    try testing.expectEqual(vals[1], back_vals[1]);
    try testing.expectEqual(@as(i64, 1), back.null_count);

    var poly_s = ArrowSchema{};
    var poly = ArrowArray{};
    try testing.expectEqual(DG_OK, dg_arrow_z7_to_polygons(ctx, &ids_s, &ids, 0, &poly_s, &poly));
    defer poly_s.release.?(&poly_s);
    defer poly.release.?(&poly);
    try testing.expectEqual(@as(i64, 3), poly.length);

    // polygons are not points; outputs stay released on error
    var err_s = ArrowSchema{};
    var err_a = ArrowArray{};
    try testing.expect(dg_arrow_geo_to_z7(ctx, 9, &poly_s, &poly, &err_s, &err_a) != DG_OK);
    try testing.expect(err_s.release == null and err_a.release == null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(dg_last_error(ctx)), "not a point") != null);
}
