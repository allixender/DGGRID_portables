// node test.mjs <dggrid.wasm> [check_cli workdir]
// dggrid.wasm through dggrid.mjs, for every preset: known values, error handling, and with a
// workdir of ../lib/check_cli.py the same comparison against the dggrid CLI (its last
// runs in <workdir>/<preset>/: res 20 point ids, whole earth res 3 cells). Then throughput
// for IGEO7v2.
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { Igeo7, PRESET } from './dggrid.mjs';

const [wasmPath, work] = process.argv.slice(2);
let fails = 0;
const check = (ok, what) => { if (!ok) { fails++; console.log('FAIL', what); } };

const TARTU = {
  IGEO7v2: 0x004252c3ffffffffn, IGEO7v1: 0x0042c499ffffffffn,
  IVEA7HL: 0x0042c50dffffffffn, IVEA7HS: 0x0042c631ffffffffn,
};
const wasmBytes = await readFile(wasmPath);

for (const [name, preset] of Object.entries(PRESET)) {
  console.log(`---- ${name}`);
  const dg = await Igeo7.load(wasmBytes, { preset });

  // Tartu, res 9: id from the upstream dggrid CLI (TRANSFORM_POINTS GEO -> HIERNDX Z7)
  const [tartu] = dg.geoToZ7(9, [26.729], [58.378]);
  check(tartu === TARTU[name], `${name} Tartu res 9: ${tartu.toString(16)}`);
  const s = dg.z7ToString(tartu);
  check(dg.z7FromString(s) === tartu && dg.z7Res(tartu) === 9, `string round trip ${s}`);
  console.log(`Tartu res 9: 0x${tartu.toString(16).padStart(16, '0')} = "${s}", centroid`,
              dg.z7ToCentroid([tartu]), 'boundary', dg.z7ToBoundary([tartu])[0].length, 'vertices');

  for (const [what, fn] of [
    ['lat 91', () => dg.geoToZ7(9, [0], [91])],
    ['res 21', () => dg.geoToZ7(21, [0], [0])],
    ['bad id', () => dg.z7ToCentroid([0xffffffffffffffffn])],
    ['bad string', () => dg.z7FromString('0479')],
    ['no such cell', () => dg.z7FromString('002')],
  ]) {
    try { fn(); check(false, `${what}: no error`); } catch (e) { console.log(`${what} -> ${e.message}`); }
  }

  if (work) {
    const dir = join(work, name);
    const lines = async (f) => (await readFile(join(dir, f), 'utf8')).split('\n').filter((l) => l.trim());
    const pts = (await lines('pts.txt')).map((l) => l.split(' ').map(Number));
    const cliIds = (await lines('z7.txt')).map((l) => BigInt('0x' + l.trim()));
    const ids = dg.geoToZ7(20, pts.map((p) => p[0]), pts.map((p) => p[1]));
    // an input exactly on a pole lies on the edge between two res 20 cells (08.. / 11..),
    // ca 1.3 cm from it, 1 ulp of libm rounding picks one. only such ties are let through
    const diff = [...ids.keys()].filter((i) => ids[i] !== cliIds[i]);
    const atPole = (z) => Math.abs(dg.z7ToCentroid([z]).lat[0]) > 89.9999;
    const nd = diff.filter((i) => !(Math.abs(pts[i][1]) === 90 && atPole(ids[i]) && atPole(cliIds[i]))).length;
    check(nd === 0, `res 20: ${nd} of ${ids.length} ids differ from CLI`);
    console.log(`res 20: ${ids.length} pts, ${nd} ids differ from CLI (${diff.length - nd} pole ties)`);

    const feats = JSON.parse(await readFile(join(dir, 'cells.geojson'), 'utf8')).features;
    const cells = feats.map((f) => BigInt('0x' + f.properties.name));
    const cpts = new Map((await lines('cpts.txt')).filter((l) => l.includes(','))
      .map((l) => l.split(',')).map(([z, a, b]) => [BigInt('0x' + z), [+a, +b]]));
    const lonDiff = (a, b) => Math.abs(((a - b + 540) % 360) - 180);
    const { lon, lat } = dg.z7ToCentroid(cells);
    let cmax = 0, bmax = 0, npent = 0, bad = 0;
    cells.forEach((z, i) => {
      const [a, b] = cpts.get(z);
      cmax = Math.max(cmax, Math.abs(lat[i]) < 89.999 ? lonDiff(lon[i], a) : 0, Math.abs(lat[i] - b));
    });
    dg.z7ToBoundary(cells).forEach((poly, i) => {
      const ring = feats[i].geometry.coordinates[0].slice(0, -1);
      npent += poly.length === 5;
      if (ring.length !== poly.length) { bad++; return; }
      poly.forEach(([a, b], v) => {
        bmax = Math.max(bmax, Math.abs(b) < 89.999 ? lonDiff(a, ring[v][0]) : 0, Math.abs(b - ring[v][1]));
      });
    });
    check(cmax < 1e-9 && bmax < 1e-9 && bad === 0 && npent === 12,
          `whole earth: cmax ${cmax} bmax ${bmax} bad ${bad} pentagons ${npent}`);
    console.log(`whole earth: ${cells.length} cells (${npent} pentagons), centroid max diff ${cmax.toExponential(1)}, ` +
                `boundary max diff ${bmax.toExponential(1)} deg vs CLI`);
  }

  dg.free();
}

// throughput, 200k pseudo-random points at res 9
const dg = await Igeo7.load(wasmBytes);
const n = 200000;
const lon = new Float64Array(n), lat = new Float64Array(n);
let seed = 12345;
const rnd = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 2 ** 32);
for (let i = 0; i < n; i++) { lon[i] = rnd() * 360 - 180; lat[i] = Math.asin(rnd() * 2 - 1) * 180 / Math.PI; }
for (const [what, fn] of [
  ['geoToZ7', () => dg.geoToZ7(9, lon, lat)],
  ['z7ToCentroid', () => dg.z7ToCentroid(dg.geoToZ7(9, lon, lat))],
  ['z7ToBoundaryRaw', () => dg.z7ToBoundaryRaw(dg.geoToZ7(9, lon, lat))],
]) {
  const t0 = performance.now();
  fn();
  const secs = (performance.now() - t0) / 1000;
  console.log(`${what.padEnd(16)} ${n} pts res 9: ${secs.toFixed(3)}s (${Math.round(n / secs)} pts/s)` +
              (what !== 'geoToZ7' ? ' incl. geoToZ7' : ''));
}

dg.free();
console.log(fails === 0 ? 'OK' : `${fails} checks FAILED`);
process.exit(fails ? 1 : 0);
