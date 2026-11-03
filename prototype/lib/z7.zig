//! z7.zig: Z7 index arithmetic, no DGGRID needed: validation, parent, children, neighbours.
//!
//! Z7 int (DgZ7System.cpp): bits 60-63 base cell (quad 0-11), then 20 radix-7 digits of
//! 3 bits each, res 1 at bits 57-59 ... res 20 at bits 0-2; digits beyond the cell's
//! resolution are 7. The children of a pentagon (quad + only zero digits) skip one digit,
//! 2 for quads 0-5, 5 for quads 6-11 (DgZ7System::setAddNdxChildren), ids in that
//! sub-sequence don't exist.
//!
//! Neighbours by Generalized Balanced Ternary addition, CW tables at odd, CCW at even
//! resolutions, carries across base cells with the rotations into / out of the polar base
//! cells 0 and 11. Ported from z7py (Apache-2.0, A. Kmoch and contributors), itself a port of
//! the C++ Z7 reference by Weston James Renoud and Javier Jimenez Shaw
//! (https://github.com/wrenoud/Z7), with the same edge guards as z7py (pole rotation table,
//! first non zero digit), input validated here, see prototype/lib/README.md.

const std = @import("std");

pub const max_res = 20;
/// empty slot: the missing pentagon neighbour / child
pub const none: u64 = std.math.maxInt(u64);

pub fn digit(z: u64, r: u5) u3 {
    return @truncate(z >> @as(u6, 20 - @as(u6, r)) * 3);
}

fn setDigit(z: u64, r: u5, d: u3) u64 {
    const shift = @as(u6, 20 - @as(u6, r)) * 3;
    return (z & ~(@as(u64, 7) << shift)) | (@as(u64, d) << shift);
}

pub fn quad(z: u64) u4 {
    return @truncate(z >> 60);
}

fn setQuad(z: u64, q: u4) u64 {
    return (z & ~(@as(u64, 0xf) << 60)) | (@as(u64, q) << 60);
}

/// the digit the children of a pentagon skip = the missing neighbour direction
fn skipDigit(q: u4) u3 {
    return if (q <= 5) 2 else 5;
}

/// resolution of a Z7 index, null if it is not a valid index
pub fn res(z: u64) ?u5 {
    const q = quad(z);
    if (q > 11) return null;
    const skip = skipDigit(q);
    var pentagon = true;
    var rr: u5 = 0;
    var r: u5 = 1;
    while (r <= max_res) : (r += 1) {
        const d = digit(z, r);
        if (d == 7) break;
        if (pentagon and d == skip) return null;
        pentagon = pentagon and d == 0;
        rr = r;
    }
    while (r <= max_res) : (r += 1) {
        if (digit(z, r) != 7) return null; // digit after the first padding digit
    }
    return rr;
}

/// digits 1..r all zero (r = the cell's resolution)
fn isPentagon(z: u64, r: u5) bool {
    if (r == 0) return true;
    return (z & ~(@as(u64, 0xf) << 60)) >> @as(u6, 20 - @as(u6, r)) * 3 == 0;
}

/// ancestor at resolution to (<= the cell's resolution r)
pub fn parent(z: u64, to: u5) u64 {
    if (to == max_res) return z;
    const keep = @as(u6, 20 - @as(u6, to)) * 3; // bits below the digits to keep
    const pad = (@as(u64, 1) << keep) - 1; // all 7s
    return (z & ~pad) | pad;
}

/// children in digit order 0..6, a pentagon's skipped digit -> none. r = the cell's resolution < 20
pub fn children(z: u64, r: u5, out: *[7]u64) void {
    const pent = isPentagon(z, r);
    for (0..7) |d| {
        out[d] = if (pent and d == skipDigit(quad(z))) none else setDigit(z, r + 1, @intCast(d));
    }
}

// ---- GBT neighbours ----

// GBT addition, digit and carry, CW (odd resolutions) / CCW (even); CCW digit = (a + b) mod 7
const cw_digit = [7][7]u3{
    .{ 0, 1, 2, 3, 4, 5, 6 }, .{ 1, 4, 3, 6, 5, 2, 0 }, .{ 2, 3, 1, 4, 6, 0, 5 }, .{ 3, 6, 4, 5, 0, 1, 2 },
    .{ 4, 5, 6, 0, 2, 3, 1 }, .{ 5, 2, 0, 1, 3, 6, 4 }, .{ 6, 0, 5, 2, 1, 4, 3 },
};
const cw_carry = [7][7]u3{
    .{ 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 1, 0, 5, 0 }, .{ 0, 0, 2, 3, 0, 0, 2 }, .{ 0, 1, 3, 3, 0, 0, 0 },
    .{ 0, 0, 0, 0, 4, 4, 6 }, .{ 0, 5, 0, 0, 4, 5, 0 }, .{ 0, 0, 2, 0, 6, 0, 6 },
};
const ccw_carry = [7][7]u3{
    .{ 0, 0, 0, 0, 0, 0, 0 }, .{ 0, 1, 0, 3, 0, 1, 0 }, .{ 0, 0, 2, 2, 0, 0, 6 }, .{ 0, 3, 2, 3, 0, 0, 0 },
    .{ 0, 0, 0, 0, 4, 5, 4 }, .{ 0, 1, 0, 0, 5, 5, 0 }, .{ 0, 0, 6, 0, 4, 0, 6 },
};
/// neighbouring base cell per (base cell, GBT direction 1-6); the slot of the pentagon's skip digit is unused
const base_neighbours = [12][6]u4{
    .{ 5, 4, 4, 2, 1, 3 },     .{ 5, 0, 0, 6, 10, 2 },   .{ 1, 0, 0, 7, 6, 3 },     .{ 2, 0, 0, 8, 7, 4 },
    .{ 3, 0, 0, 9, 8, 5 },     .{ 4, 0, 0, 10, 9, 1 },   .{ 10, 2, 1, 11, 11, 7 },  .{ 6, 3, 2, 11, 11, 8 },
    .{ 7, 4, 3, 11, 11, 9 },   .{ 8, 5, 4, 11, 11, 10 }, .{ 9, 1, 5, 11, 11, 6 },   .{ 9, 6, 10, 8, 8, 7 },
};
/// times x5 (mod 7) entering polar base cell 0 / 11, per source base cell
const into_pole_rotations = [12]u8{ 0, 5, 0, 1, 3, 4, 5, 4, 3, 1, 0, 0 };
/// times x5 leaving base cell 0 (11 mirrored), [first digit of the cell - 1][first digit of the neighbour - 1]
const out_of_pole_rotations = [6][6]u8{
    .{ 0, 1, 0, 1, 0, 2 }, .{ 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0, 3, 2, 2 },
    .{ 5, 5, 0, 0, 0, 0 }, .{ 0, 1, 0, 0, 0, 0 }, .{ 5, 0, 4, 0, 4, 0 },
};

const Sum = struct { digit: u3, carry: u3 };

fn gbtAdd(r: u5, a: u3, b: u3) Sum {
    if (r % 2 == 0) return .{ .digit = @intCast((@as(u8, a) + b) % 7), .carry = ccw_carry[a][b] };
    return .{ .digit = cw_digit[a][b], .carry = cw_carry[a][b] };
}

/// 5^k mod 7
fn pow5(k: u8) u3 {
    var m: u8 = 1;
    for (0..k % 6) |_| m = m * 5 % 7;
    return @intCast(m);
}

/// every digit from..to multiplied by m mod 7 = a rotation of the sub-hierarchy
fn rotate(z: u64, from: u5, to: u5, m: u3) u64 {
    var x = z;
    var j = from;
    while (j <= to) : (j += 1) x = setDigit(x, j, @intCast(@as(u8, digit(x, j)) * m % 7));
    return x;
}

/// position of the first digit != 0 (a padding 7 counts), 0 if there is none
fn firstNonZero(z: u64) u5 {
    if (digit(z, 1) == 7) return 0; // res 0
    var i: u5 = 1;
    while (i <= max_res) : (i += 1) {
        if (digit(z, i) != 0) return i;
    }
    return 0;
}

/// the cell one step in GBT direction dir (1-6) at resolution r, carry != 0 = left the base cell
fn step(z: u64, r: u5, dir: u3) struct { z: u64, carry: u3 } {
    var s = gbtAdd(r, digit(z, r), dir);
    var x = setDigit(z, r, s.digit);
    var i = r - 1;
    while (s.carry != 0 and i >= 1) : (i -= 1) {
        s = gbtAdd(i, digit(z, i), s.carry);
        x = setDigit(x, i, s.digit);
    }
    return .{ .z = x, .carry = s.carry };
}

/// the 6 neighbours in GBT direction order 1..6, a pentagon's missing one -> none.
/// z must be valid with resolution r
pub fn neighbors(z: u64, r: u5, out: *[6]u64) void {
    const q = quad(z);
    const ex = skipDigit(q);
    if (r == 0) {
        for (0..6) |i| {
            out[i] = if (i + 1 == ex) none else setQuad(none, base_neighbours[q][i]);
        }
        return;
    }
    const first = digit(z, 1);
    for (1..7) |d| {
        const s = step(z, r, @intCast(d));
        var x = s.z;
        if (s.carry != 0) {
            const nq = base_neighbours[q][s.carry - 1];
            x = setQuad(x, nq);
            if (nq == 0 or nq == 11) {
                const k = into_pole_rotations[q] + @intFromBool(first == 1 or first == 6);
                if (k > 0) x = rotate(x, 1, r, pow5(k));
            }
            if (q == 0 or q == 11) {
                var row: u8 = first;
                var col: u8 = digit(x, 1);
                if (q == 11) {
                    row = 7 - row;
                    col = 7 - col;
                }
                if (row >= 1 and row <= 6 and col >= 1 and col <= 6) {
                    const k = out_of_pole_rotations[row - 1][col - 1];
                    if (k > 0) x = rotate(x, 1, r, pow5(k));
                }
            }
        }
        out[d - 1] = x;
    }
    if (isPentagon(z, r)) {
        out[ex - 1] = none;
        return;
    }
    // neighbours that landed on the pentagon's missing digit: rotate them out of it
    const ref = digit(z, firstNonZero(z));
    const m: u3 = if (@as(u8, ref) * 5 % 7 == ex) 5 else if (@as(u8, ref) * 3 % 7 == ex) 3 else 0;
    if (m == 0) return;
    for (out) |*x| {
        const t = firstNonZero(x.*);
        if (t >= 1 and t <= r and digit(x.*, t) == ex) x.* = rotate(x.*, t, r, m);
    }
}

// ---- tests ----

const testing = std.testing;

fn parse(s: []const u8) u64 {
    var z: u64 = (@as(u64, s[0] - '0') * 10 + (s[1] - '0')) << 60;
    var r: u5 = 1;
    while (r <= max_res) : (r += 1) {
        const i = 1 + @as(usize, r);
        z = setDigit(z, r, if (i < s.len) @intCast(s[i] - '0') else 7);
    }
    return z;
}

fn expectNeighbors(cell: []const u8, expected: []const []const u8) !void {
    const z = parse(cell);
    var out: [6]u64 = undefined;
    neighbors(z, res(z).?, &out);
    var want: [6]u64 = undefined;
    for (expected, 0..) |e, i| want[i] = if (e.len == 0) none else parse(e);
    try testing.expectEqualSlices(u64, want[0..expected.len], &out);
}

test "z7: res, parent, children" {
    const z = parse("0401234");
    try testing.expectEqual(@as(?u5, 5), res(z));
    try testing.expectEqual(parse("0401"), parent(z, 2));
    try testing.expectEqual(parse("04"), parent(z, 0));
    try testing.expectEqual(z, parent(z, 5));
    var ch: [7]u64 = undefined;
    children(z, 5, &ch);
    for (ch, 0..) |c, d| {
        try testing.expectEqual(@as(?u5, 6), res(c));
        try testing.expectEqual(z, parent(c, 5));
        try testing.expectEqual(@as(u3, @intCast(d)), digit(c, 6));
    }
    // pentagons: skip digit 2 (quads 0-5) / 5 (quads 6-11)
    children(parse("0300"), 2, &ch);
    try testing.expectEqual(none, ch[2]);
    for (ch, 0..) |c, d| if (d != 2) try testing.expect(res(c) != null);
    children(parse("07"), 0, &ch);
    try testing.expectEqual(none, ch[5]);
    const full = parse("0012345612345612345612");
    try testing.expectEqual(@as(?u5, 20), res(full));
    try testing.expectEqual(full, parent(full, 20));
}

// vectors from the Z7 reference tests (wrenoud/Z7 tests/tests.cpp)
test "z7: GBT step + neighbours, reference vectors" {
    const a = parse("0800433");
    for ([_][]const u8{ "0800046", "0800064", "0800065", "0800430", "0800431", "0800432" }, 1..) |e, d|
        try testing.expectEqual(parse(e), step(a, 5, @intCast(d)).z);
    const b = parse("0006464460645425026");
    for ([_][]const u8{ "0006464460645425020", "0006464460645425245", "0006464460645425022" }, 1..) |e, d|
        try testing.expectEqual(parse(e), step(b, 17, @intCast(d)).z);

    try expectNeighbors("0800432", &.{ "0800433", "0800651", "0800064", "0800436", "0800430", "0800655" });
    // exclusion zone rotations
    try expectNeighbors("0300613", &.{ "0300032", "0300366", "0300364", "0300610", "0300611", "0300612" });
    try expectNeighbors("0300036", &.{ "0300030", "0300611", "0300032", "0300063", "0300034", "0300062" });
    try expectNeighbors("080041", &.{ "080016", "080043", "080004", "080045", "080014", "080040" });
    try expectNeighbors("080004", &.{ "080001", "080006", "080000", "080041", "080016", "080043" });
    // pentagons
    try expectNeighbors("0800", &.{ "0801", "0802", "0803", "0804", "", "0806" });
    try expectNeighbors("00", &.{ "05", "", "04", "02", "01", "03" });
    try expectNeighbors("090", &.{ "091", "092", "093", "094", "", "096" });
    try expectNeighbors("090000000000000000000", &.{ "090000000000000000001", "090000000000000000002", "090000000000000000003", "090000000000000000004", "", "090000000000000000006" });
    try expectNeighbors("0900000000000000000000", &.{ "0900000000000000000001", "0900000000000000000002", "0900000000000000000003", "0900000000000000000004", "", "0900000000000000000006" });

    try testing.expectEqual(@as(u5, 6), firstNonZero(parse("0000000")));
    try testing.expectEqual(@as(u5, 3), firstNonZero(parse("1200567")));
    try testing.expectEqual(@as(u5, 0), firstNonZero(parse("0900000000000000000000"))); // C++: 21
}
