// @ts-check
// Browser demo of dggrid.wasm through dggrid.mjs. Serve this folder over http (wasm can't be
// fetched from file://):  python3 -m http.server -d web 8000  ->  http://localhost:8000
import { Igeo7, PRESET } from './dggrid.mjs';
import { allCells, isPoleCell } from './cells.mjs';

/** @typedef {import('./dggrid.mjs').Ring} Ring */

const $ = (/** @type {string} */ id) => /** @type {any} */ (document.getElementById(id));
const out = $('out');
const log = (/** @type {string} */ s) => { out.textContent = s; };

const wasmBytes = await (await fetch('./dggrid.wasm')).arrayBuffer();
/** @type {Map<string, Igeo7>} one context per preset, each its own wasm instance */
const grids = new Map();
async function grid() {
  const name = $('preset').value;
  if (!grids.has(name)) {
    const dg = await Igeo7.load(wasmBytes, { preset: PRESET[/** @type {keyof typeof PRESET} */ (name)] });
    grids.set(name, dg);
  }
  return /** @type {Igeo7} */ (grids.get(name));
}

// ---- drawing helpers, map coordinates = lon/lat degrees, y flipped by the <g> ----

/** @param {Ring} ring */
const ringPath = (ring, dx = 0) =>
  'M' + ring.map(([x, y]) => `${(x + dx).toFixed(4)} ${y.toFixed(4)}`).join('L') + 'Z';

/** ring plus a copy shifted by -360 when it reaches past 180 (UNWRAP_EAST) */
/** @param {Ring} ring */
const wrapped = (ring) => ringPath(ring) + (ring.some(([x]) => x > 180) ? ringPath(ring, -360) : '');

function graticule() {
  let d = '';
  for (let x = -180; x <= 180; x += 30) d += `M${x} -90L${x} 90`;
  for (let y = -60; y <= 60; y += 30) d += `M-180 ${y}L180 ${y}`;
  $('grat').setAttribute('d', d);
}

// land outline, optional: Natural Earth 110m via world-atlas, skipped when offline
async function land() {
  try {
    // @ts-ignore  CDN module, no types
    const { feature } = await import('https://cdn.jsdelivr.net/npm/topojson-client@3.1.0/+esm');
    const topo = await (await fetch('https://cdn.jsdelivr.net/npm/world-atlas@2.0.2/land-110m.json')).json();
    const geom = feature(topo, topo.objects.land).features[0].geometry;
    const polys = geom.type === 'Polygon' ? [geom.coordinates] : geom.coordinates;
    const d = polys.flatMap((/** @type {Ring[]} */ p) => p.map((r) => ringPath(r))).join('');
    $('land').innerHTML = `<path class="land" fill-rule="evenodd" d="${d}"></path>`;
  } catch (e) {
    console.info('no basemap', e);
  }
}

async function drawGrid() {
  const dg = await grid();
  const res = +$('gridRes').value;
  const ids = allCells(res);
  const rings = dg.z7ToBoundary(ids);
  let d = '', p = '';
  for (const r of rings) isPoleCell(r) ? (p += wrapped(r)) : (d += wrapped(r));
  $('grid').setAttribute('d', d);
  $('poles').setAttribute('d', p);
  return ids.length;
}

// ---- query: point -> cell, centroid, boundary, parents ----

async function locate() {
  const dg = await grid();
  const lon = +$('lon').value, lat = +$('lat').value, res = +$('res').value;
  let id;
  try {
    [id] = dg.geoToZ7(res, [lon], [lat]);
  } catch (e) {
    log(String(/** @type {Error} */ (e).message));
    return;
  }
  const [ring] = dg.z7ToBoundary([id]);
  const c = dg.z7ToCentroid([id]);
  const chain = Array.from({ length: res + 1 }, (_, r) => dg.z7ToString(dg.geoToZ7(r, [lon], [lat])[0]));
  $('hit').setAttribute('d', wrapped(ring));
  const pt = $('pt');
  pt.setAttribute('cx', lon); pt.setAttribute('cy', lat); pt.setAttribute('visibility', 'visible');
  drawDetail(ring, [c.lon[0], c.lat[0]], [lon, lat]);
  log([
    `${$('preset').value}, res ${res}`,
    `point     ${lon}, ${lat}`,
    `z7 int    0x${id.toString(16).padStart(16, '0')}  (${id})`,
    `z7 str    ${dg.z7ToString(id)}`,
    `centroid  ${c.lon[0].toFixed(8)}, ${c.lat[0].toFixed(8)}`,
    `vertices  ${ring.length}${ring.length === 5 ? ' (pentagon)' : ''}${isPoleCell(ring) ? ', pole cell' : ''}`,
    ...ring.map(([x, y], i) => `  ${i}  ${x.toFixed(8)}, ${y.toFixed(8)}`),
    `res 0..${res}  ${chain.join(' ')}`,
  ].join('\n'));
}

/** @param {Ring} ring @param {[number, number]} c @param {[number, number]} p */
function drawDetail(ring, c, p) {
  const k = Math.cos((c[1] * Math.PI) / 180) || 1e-9;  // local equirectangular
  const xy = ring.map(([x, y]) => [(x - c[0]) * k, y - c[1]]);
  const span = Math.max(...xy.map(([x, y]) => Math.max(Math.abs(x), Math.abs(y)))) || 1;
  const s = 110 / span, T = (/** @type {number[]} */ [x, y]) => [140 + x * s, 140 - y * s];
  const pts = xy.map(T);
  const [px, py] = T([(p[0] - c[0]) * k, p[1] - c[1]]);
  $('detail').innerHTML =
    `<polygon points="${pts.map((q) => q.join(',')).join(' ')}" class="hit"/>` +
    pts.map(([x, y], i) => `<text x="${x}" y="${y}" dx="${x > 140 ? 6 : -14}" dy="4" font-size="11" fill="currentColor">${i}</text>`).join('') +
    `<circle cx="140" cy="140" r="3" fill="currentColor"/><circle cx="${px}" cy="${py}" r="3" fill="none" stroke="currentColor"/>`;
}

// ---- batch + Arrow ----

function randomPoints(/** @type {number} */ n) {
  const lon = new Float64Array(n), lat = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    lon[i] = Math.random() * 360 - 180;
    lat[i] = (Math.asin(Math.random() * 2 - 1) * 180) / Math.PI;
  }
  return { lon, lat };
}

async function bench() {
  const dg = await grid();
  const n = 200000, { lon, lat } = randomPoints(n);
  const t = (/** @type {() => unknown} */ f) => { const t0 = performance.now(); f(); return (performance.now() - t0) / 1000; };
  let ids = new BigUint64Array(0);
  const a = t(() => { ids = dg.geoToZ7(9, lon, lat); });
  const b = t(() => dg.z7ToCentroid(ids));
  const c = t(() => dg.z7ToBoundaryRaw(ids));
  const rate = (/** @type {number} */ s) => `${Math.round(n / s / 1000)}k/s`;
  log(`${n} random points, res 9\n  geoToZ7         ${rate(a)}\n  z7ToCentroid    ${rate(b)}\n  z7ToBoundaryRaw ${rate(c)}`);
}

async function arrow() {
  const dg = await grid();
  const lon = [26.729, NaN, -70.0, 180.0], lat = [58.378, NaN, -33.4, 10.0];  // last one: across the antimeridian
  const ids = dg.lonLatToZ7Arrow(7, lon, lat);
  const bits = ids.nullBitmap;  // Arrow validity bitmap, null = no nulls
  const valid = [...ids.values].map((_, i) => (bits ? (bits[i >> 3] >> (i & 7)) & 1 : 1));
  const ok = [...ids.values].filter((_, i) => valid[i]);
  const poly = dg.z7ToPolygonsArrow(ok);
  log([
    `lonLatToZ7Arrow(7, lon, lat)  NaN, NaN -> null`,
    `  format '${ids.format}' name '${ids.name}' length ${ids.length} nulls ${ids.nullCount}`,
    `  values ${[...ids.values].map((v, i) => (valid[i] === 0 ? 'null' : dg.z7ToString(v))).join(' ')}`,
    ``,
    `z7ToPolygonsArrow(${ok.length} ids)`,
    `  format '${poly.format}', ${poly.metadata['ARROW:extension:name']}`,
    `  crs ${poly.metadata['ARROW:extension:metadata']?.slice(0, 120) ?? 'none'}`,
    `  polygon offsets ${[...poly.polygons]}  ring offsets ${[...poly.rings]}`,
    `  ${poly.x.length} coords, last cell lon ${[...poly.x.slice(poly.rings[ok.length - 1])].map((x) => x.toFixed(3)).join(' ')}`,
  ].join('\n'));
}

// ---- wiring ----

$('map').addEventListener('click', (/** @type {MouseEvent} */ e) => {
  const svg = $('map'), g = svg.firstElementChild;
  const q = new DOMPoint(e.clientX, e.clientY).matrixTransform(g.getScreenCTM().inverse());
  $('lon').value = q.x.toFixed(5);
  $('lat').value = q.y.toFixed(5);
  locate();
});
$('go').addEventListener('click', locate);
$('bench').addEventListener('click', bench);
$('arrow').addEventListener('click', arrow);
$('gridRes').addEventListener('change', drawGrid);
$('preset').addEventListener('change', async () => { await drawGrid(); await locate(); });

graticule();
land();
const n = await drawGrid();
await locate();
console.info(`grid res ${$('gridRes').value}: ${n} cells`);
