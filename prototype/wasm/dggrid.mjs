// dggrid.mjs: JS wrapper around dggrid.wasm, the prototype IGEO7 C API
// (../lib/include/dggrid.h) built as a wasm32-wasi reactor:
//   cd ../lib && zig build -Dtarget=wasm32-wasi -Ddgreal=double -Doptimize=ReleaseFast
//
// No WASI runtime needed: the module only imports a handful of WASI functions (DGGRID
// may print warnings, a fatal error calls proc_exit), stubbed below. Works the same in
// node and in browsers.
//
//   const dg = await Igeo7.load(bytes);     // ArrayBuffer / Uint8Array / Response, IGEO7v2
//   const iv = await Igeo7.load(bytes, { preset: PRESET.IVEA7HL });
//   const ids = dg.geoToZ7(9, [26.729], [58.378]);   // BigUint64Array
//   dg.z7ToString(ids[0]);                  // "04..."
//   dg.z7ToCentroid(ids);                   // { lon: Float64Array, lat: Float64Array }
//   dg.z7ToBoundary(ids);                   // [[[lon, lat], ...], ...] (6 or 5 vertices)
//   dg.lonLatToZ7Arrow(9, lon, lat);        // Arrow C structs: { values, nullBitmap, nullCount, .. }
//   dg.z7ToPolygonsArrow(ids);              // geoarrow.polygon: { rings, polygons, x, y, metadata, .. }

/** DGGRID 9.1 dggs_type presets (include/dggrid.h) */
export const PRESET = Object.freeze({ IGEO7v2: 0, IGEO7v1: 1, IVEA7HL: 2, IVEA7HS: 3 });

export const WRAP = Object.freeze({ NONE: 0, EAST: 1, WEST: 2 });

const decoder = new TextDecoder();
const encoder = new TextEncoder();

function wasiStubs(getMemory, log) {
  const ENOSYS = 52;
  const u32 = () => new Uint32Array(getMemory().buffer);
  return {
    environ_sizes_get: (countPtr, sizePtr) => { u32()[countPtr >> 2] = 0; u32()[sizePtr >> 2] = 0; return 0; },
    environ_get: () => 0,
    fd_write: (fd, iovs, iovsLen, nwrittenPtr) => {
      const mem = getMemory().buffer;
      const v = new Uint32Array(mem);
      let text = '', n = 0;
      for (let i = 0; i < iovsLen; i++) {
        const ptr = v[(iovs >> 2) + 2 * i], len = v[(iovs >> 2) + 2 * i + 1];
        text += decoder.decode(new Uint8Array(mem, ptr, len));
        n += len;
      }
      log(fd, text);
      v[nwrittenPtr >> 2] = n;
      return 0;
    },
    fd_read: () => ENOSYS,
    fd_seek: () => ENOSYS,
    fd_close: () => 0,
    fd_fdstat_get: () => ENOSYS,
    proc_exit: (code) => { throw new Error(`dggrid.wasm exited with code ${code} (DGGRID fatal error)`); },
  };
}

export class Igeo7 {
  /** instantiate dggrid.wasm and create a context for one preset (default IGEO7v2) */
  static async load(source, { preset = PRESET.IGEO7v2, log = (fd, text) => (fd === 2 ? console.error : console.log)(text.trimEnd()) } = {}) {
    let memory;
    const imports = { wasi_snapshot_preview1: wasiStubs(() => memory, log) };
    const { instance } = source instanceof Response
      ? await WebAssembly.instantiateStreaming(source, imports)
      : await WebAssembly.instantiate(source, imports);
    memory = instance.exports.memory;
    instance.exports._initialize();  // C++ static constructors
    return new Igeo7(instance.exports, preset);
  }

  constructor(exports, preset = PRESET.IGEO7v2) {
    this.x = exports;
    this.ctx = exports.dg_preset_new(preset);
    if (!this.ctx) throw new Error(`dg_preset_new: ${this.#cstr(exports.dg_last_error(0))}`);
  }

  free() { this.x.dg_ctx_free(this.ctx); this.ctx = 0; }

  /** boundaries across the antimeridian: WRAP.EAST (default), WRAP.WEST, WRAP.NONE */
  setLonWrap(mode) { this.#check(this.x.dg_ctx_set_lon_wrap(this.ctx, mode), 'dg_ctx_set_lon_wrap'); }

  #cstr(ptr) {
    const mem = new Uint8Array(this.x.memory.buffer);
    let end = ptr;
    while (mem[end]) end++;
    return decoder.decode(mem.subarray(ptr, end));
  }

  #check(rc, fn) {
    if (rc !== 0) throw new Error(`${fn}: ${this.#cstr(this.x.dg_last_error(this.ctx))}`);
  }

  // allocate wasm memory for the given byte sizes, run fn(...ptrs), free them again.
  // views on memory.buffer must be (re)created after any call that may grow memory.
  #withBuffers(sizes, fn) {
    const ptrs = sizes.map((s) => this.x.dg_alloc(Math.max(s, 1)));
    try {
      if (ptrs.includes(0)) throw new Error('dg_alloc: out of memory');
      return fn(...ptrs);
    } finally {
      ptrs.forEach((p) => this.x.dg_free(p));
    }
  }

  /** cells containing the points (degrees) at resolution res, as Z7 ints */
  geoToZ7(res, lon, lat) {
    const n = lon.length;
    return this.#withBuffers([8 * n, 8 * n, 8 * n], (pLon, pLat, pOut) => {
      new Float64Array(this.x.memory.buffer, pLon, n).set(lon);
      new Float64Array(this.x.memory.buffer, pLat, n).set(lat);
      this.#check(this.x.dg_geo_to_z7(this.ctx, res, pLon, pLat, n, pOut), 'dg_geo_to_z7');
      return new BigUint64Array(this.x.memory.buffer, pOut, n).slice();
    });
  }

  #putIds(ptr, ids) {
    new BigUint64Array(this.x.memory.buffer, ptr, ids.length).set(ids.map ? ids.map(BigInt) : ids);
  }

  /** cell centre points in degrees */
  z7ToCentroid(ids) {
    const n = ids.length;
    return this.#withBuffers([8 * n, 8 * n, 8 * n], (pIds, pLon, pLat) => {
      this.#putIds(pIds, ids);
      this.#check(this.x.dg_z7_to_centroid(this.ctx, pIds, n, pLon, pLat), 'dg_z7_to_centroid');
      return {
        lon: new Float64Array(this.x.memory.buffer, pLon, n).slice(),
        lat: new Float64Array(this.x.memory.buffer, pLat, n).slice(),
      };
    });
  }

  /** raw boundaries: lonlat (n * 6 pairs, NaN padded) + nverts (6, or 5 for pentagons) */
  z7ToBoundaryRaw(ids) {
    const n = ids.length;
    return this.#withBuffers([8 * n, 96 * n, n], (pIds, pLL, pNv) => {
      this.#putIds(pIds, ids);
      this.#check(this.x.dg_z7_to_boundary(this.ctx, pIds, n, pLL, pNv), 'dg_z7_to_boundary');
      return {
        lonlat: new Float64Array(this.x.memory.buffer, pLL, 12 * n).slice(),
        nverts: new Uint8Array(this.x.memory.buffer, pNv, n).slice(),
      };
    });
  }

  /** boundaries as arrays of [lon, lat] vertices (open rings) */
  z7ToBoundary(ids) {
    const { lonlat, nverts } = this.z7ToBoundaryRaw(ids);
    return Array.from(nverts, (nv, i) =>
      Array.from({ length: nv }, (_, v) => [lonlat[12 * i + 2 * v], lonlat[12 * i + 2 * v + 1]]));
  }

  // ---- Arrow C Data Interface, wasm32 layout (pointers 4 bytes, int64 aligned to 8) ----
  // sizes + offsets: ArrowSchema 48, ArrowArray 64

  #view() { return new DataView(this.x.memory.buffer); }

  // a primitive input array in wasm memory, nothing to release: buffers[0] = no nulls
  #putPrimitive(pSchema, pArray, pBuffers, pFormat, format, pData, n) {
    const v = this.#view();
    new Uint8Array(this.x.memory.buffer, pSchema, 48).fill(0);
    new Uint8Array(this.x.memory.buffer, pArray, 64).fill(0);
    new Uint8Array(this.x.memory.buffer, pFormat, 2).set([format.charCodeAt(0), 0]);
    v.setUint32(pSchema, pFormat, true);
    v.setUint32(pSchema + 40, 1, true);  // release != NULL = not released, never called on input
    v.setUint32(pBuffers, 0, true);
    v.setUint32(pBuffers + 4, pData, true);
    v.setBigInt64(pArray, BigInt(n), true);
    v.setBigInt64(pArray + 24, 2n, true);
    v.setUint32(pArray + 40, pBuffers, true);
    v.setUint32(pArray + 52, 1, true);
  }

  #readArray(p) {
    const v = this.#view();
    const nBuffers = Number(v.getBigInt64(p + 24, true)), nChildren = Number(v.getBigInt64(p + 32, true));
    const pb = v.getUint32(p + 40, true), pc = v.getUint32(p + 44, true);
    return {
      length: Number(v.getBigInt64(p, true)),
      nullCount: Number(v.getBigInt64(p + 8, true)),
      offset: Number(v.getBigInt64(p + 16, true)),
      buffers: Array.from({ length: nBuffers }, (_, i) => v.getUint32(pb + 4 * i, true)),
      children: Array.from({ length: nChildren }, (_, i) => this.#readArray(v.getUint32(pc + 4 * i, true))),
    };
  }

  #readSchema(p) {
    const v = this.#view();
    const name = v.getUint32(p + 4, true), meta = v.getUint32(p + 8, true);
    let metadata = {};
    if (meta) {  // int32 count, then int32 length + bytes per key and value
      const n = v.getInt32(meta, true);
      let at = meta + 4;
      const str = () => {
        const len = v.getInt32(at, true);
        const t = decoder.decode(new Uint8Array(this.x.memory.buffer, at + 4, len));
        at += 4 + len;
        return t;
      };
      for (let i = 0; i < n; i++) { const k = str(); metadata[k] = str(); }
    }
    return { format: this.#cstr(v.getUint32(p, true)), name: name ? this.#cstr(name) : '', metadata };
  }

  #copyBitmap(arr) {
    const p = arr.buffers[0];
    return p ? new Uint8Array(this.x.memory.buffer, p, Math.ceil((arr.offset + arr.length) / 8)).slice() : null;
  }

  /** plain lon + lat -> uint64 Arrow array, NaN + NaN = null */
  lonLatToZ7Arrow(res, lon, lat) {
    const n = lon.length;
    return this.#withBuffers([8 * n, 8 * n, 48, 64, 8, 2, 48, 64, 8, 2, 48, 64],
      (dLon, dLat, sLon, aLon, bLon, fLon, sLat, aLat, bLat, fLat, sOut, aOut) => {
        new Float64Array(this.x.memory.buffer, dLon, n).set(lon);
        new Float64Array(this.x.memory.buffer, dLat, n).set(lat);
        this.#putPrimitive(sLon, aLon, bLon, fLon, 'g', dLon, n);
        this.#putPrimitive(sLat, aLat, bLat, fLat, 'g', dLat, n);
        this.#check(this.x.dg_arrow_lonlat_to_z7(this.ctx, res, sLon, aLon, sLat, aLat, sOut, aOut), 'dg_arrow_lonlat_to_z7');
        const a = this.#readArray(aOut);
        const out = {
          ...this.#readSchema(sOut), length: a.length, nullCount: a.nullCount,
          nullBitmap: this.#copyBitmap(a),
          values: new BigUint64Array(this.x.memory.buffer, a.buffers[1] + 8 * a.offset, a.length).slice(),
        };
        this.x.dg_arrow_release_array(aOut);
        this.x.dg_arrow_release_schema(sOut);
        return out;
      });
  }

  /** z7 -> geoarrow.polygon, copied out of the Arrow buffers: list<list<struct<x, y>>> */
  z7ToPolygonsArrow(ids) {
    const n = ids.length;
    return this.#withBuffers([8 * n, 48, 64, 8, 2, 48, 64], (dIds, sIn, aIn, bIn, fIn, sOut, aOut) => {
      this.#putIds(dIds, ids);
      this.#putPrimitive(sIn, aIn, bIn, fIn, 'L', dIds, n);
      this.#check(this.x.dg_arrow_z7_to_polygons(this.ctx, sIn, aIn, 0, sOut, aOut), 'dg_arrow_z7_to_polygons');
      const a = this.#readArray(aOut);
      const rings = a.children[0], coords = rings.children[0];
      const [cx, cy] = coords.children;
      const out = {
        ...this.#readSchema(sOut), length: a.length, nullCount: a.nullCount,
        polygons: new Int32Array(this.x.memory.buffer, a.buffers[1] + 4 * a.offset, a.length + 1).slice(),
        rings: new Int32Array(this.x.memory.buffer, rings.buffers[1] + 4 * rings.offset, rings.length + 1).slice(),
        x: new Float64Array(this.x.memory.buffer, cx.buffers[1] + 8 * cx.offset, cx.length).slice(),
        y: new Float64Array(this.x.memory.buffer, cy.buffers[1] + 8 * cy.offset, cy.length).slice(),
      };
      this.x.dg_arrow_release_array(aOut);
      this.x.dg_arrow_release_schema(sOut);
      return out;
    });
  }

  z7Res(id) { return this.x.dg_z7_res(BigInt(id)); }

  z7ToString(id) {
    return this.#withBuffers([32], (p) => {
      const n = this.x.dg_z7_to_string(BigInt(id), p, 32);
      if (n < 0) throw new Error(`invalid Z7 index ${id}`);
      return decoder.decode(new Uint8Array(this.x.memory.buffer, p, n));
    });
  }

  z7FromString(s) {
    const bytes = encoder.encode(s);
    return this.#withBuffers([bytes.length, 8], (pS, pOut) => {
      new Uint8Array(this.x.memory.buffer, pS, bytes.length).set(bytes);
      if (this.x.dg_z7_from_string(pS, bytes.length, pOut) !== 0) throw new Error(`invalid Z7 string "${s}"`);
      return new BigUint64Array(this.x.memory.buffer, pOut, 1)[0];
    });
  }
}
