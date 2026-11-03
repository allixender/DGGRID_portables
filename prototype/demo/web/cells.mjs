// @ts-check
// Z7 helpers in plain JS, no wasm needed.

/**
 * every cell at resolution res (0..20) as Z7 ints, from the Z7 digit rule:
 * base cells 0-11, 7 children per level, except below a pentagon (base cell + only zeros),
 * which skips one digit (2 for base cells 0-5, 5 for 6-11). 10 * 7^res + 2 cells.
 * @param {number} res
 * @returns {bigint[]}
 */
export function allCells(res) {
  const out = [];
  let padding = 0n;
  for (let r = res + 1; r <= 20; r++) padding |= 7n << BigInt((20 - r) * 3);
  for (let q = 0; q < 12; q++) {
    const skip = q <= 5 ? 2n : 5n;
    /** @type {[bigint, boolean][]} */
    let level = [[BigInt(q) << 60n, true]];
    for (let r = 1; r <= res; r++) {
      const shift = BigInt((20 - r) * 3);
      const next = [];
      for (const [z, pent] of level) {
        for (let d = 0n; d < 7n; d++) {
          if (pent && d === skip) continue;
          next.push(/** @type {[bigint, boolean]} */ ([z | (d << shift), pent && d === 0n]));
        }
      }
      level = next;
    }
    for (const [z] of level) out.push(z | padding);
  }
  return out;
}

/**
 * true for the cells whose edge runs through a pole: two vertices exactly 180 deg apart in
 * longitude. Correct on the sphere, wrong as planar lon/lat polygons, 4 per resolution
 * @param {[number, number][]} ring
 */
export function isPoleCell(ring) {
  return ring.some(([a], i) => Math.abs(Math.abs(ring[(i + 1) % ring.length][0] - a) - 180) < 1e-6);
}
