# dglib -> wasm32-wasi (zig 0.16), notes

2026-10-02, M2 Pro, node v20.11.1. build in `../lib/`: `zig build -Dtarget=wasm32-wasi -Ddgreal=double -Doptimize=ReleaseFast -p zig-out/wasm`

- `dggrid.wasm` -> the IGEO7 C API as a reactor module (no main, `_initialize` runs the C++ static ctors), exports exactly `dg_*` + memory. `dggrid.mjs` = JS wrapper, `node test.mjs <dggrid.wasm> [check_cli workdir]` = test + bench
- `bench.wasm` -> WASI command (geo -> Q2DI loop), `node run.mjs bench.wasm 200000`

## update 2026-11-02, DGGRID 9.1

- builds unchanged, no new WASI imports, 780 KB stripped ReleaseFast (205 KB gzip). `Igeo7.load(bytes, { preset: PRESET.IVEA7HL })`, default IGEO7v2. numbers below this section = 2026-10-02, 8.x sphere grid
- test.mjs vs root CLI, 4 presets: res 20 ids identical except exact pole ties, whole earth res 3 within 6.1e-12 deg
- IGEO7v2, 200k pts res 9, derived from the cumulative timings: geo -> Z7 207k/s, Z7 -> centroid ca 480k/s, Z7 -> boundary ca 140k/s. native 397k / 751k / 170k
- long double (quad) mode, same checks OK, ca 9.5k pts/s, 22x slower -> stays a check, not a build to use
- 9.1 `DgAuthalic` inverse converges on musl double (8 * DBL_EPSILON tolerance) -> no trap in WGS84 mode. 0102 gone, upstream atan2l gives the same hash

## dggrid.wasm + dggrid.mjs (JS API)

- imports only 8 WASI functions (environ_*, fd_write/read/seek/close, fd_fdstat_get, proc_exit) -> dggrid.mjs stubs them itself, fd_write -> console, proc_exit (= DGGRID fatal) -> JS Error. no WASI runtime / shim lib needed, same code node + browser (`Igeo7.load(fetch(...))` via instantiateStreaming)
- API: `geoToZ7(res, lon, lat)` -> BigUint64Array, `z7ToCentroid(ids)`, `z7ToBoundary(ids)` / `z7ToBoundaryRaw`, `z7ToString`, `z7FromString`, `z7Res`. buffers via dg_alloc/dg_free, typed array views recreated after each call (memory growth detaches them)
- size: 727 KB stripped ReleaseFast (187 KB gzip), 593 KB ReleaseSmall, unstripped 12.6 MB
- test.mjs vs CLI (check_cli.py workdir): res 20 ids 3005/3005 identical, whole earth res 3 (3432 cells, 12 pentagons) centroids/boundaries within 6e-12 deg (native 5e-13, wasm libm rounding)
- invalid input (lat 91, res 21, bad id, bad string) -> JS exceptions with the dg_last_error message, instance stays usable

| 200k pts res 9 | wasm (node 20) | native (ctypes) |
|---|---|---|
| geo -> Z7 | 200k pts/s | 386k pts/s |
| Z7 -> centroid | ~545k/s | 855k/s |
| Z7 -> boundary | ~160k/s | 201k/s |

## builds?

- yes. dglib + proj4lib + shapelib compile for wasm32-wasi, except the 19 file reader/writer classes (`DgIn*`, `DgOut*`, `DgInputStream`, `DgOutputStream`): zig's wasi libc++ has no `<fstream>` -> `../lib/build.zig` skips `DgIn*`/`DgOut*` on wasm, a lib doesn't need them (no file IO is the point anyway)
- link: only `__cxa_allocate_exception` + `__cxa_throw` missing, zig's wasm libc++abi has no exception support -> `../lib/wasi_cxa_stub.cpp`, any throw = abort = trap. no catchable errors on wasm -> validate inputs in the C API, fatal hook (0101) can only abort there
- results identical to native: 200k random pts geo -> Q2DI res 9, same hash as mac arm64/x86_64 (needs patch 0102 for dgreal=double, see below)
- bench.wasm 12.6 MB unstripped (ReleaseFast, debug info incl), libdglib.a 23 MB. dggrid.wasm is stripped (727 KB, see above)

## long double = 128-bit soft float on wasm32

- `LDBL_MANT_DIG` 113 on wasm32 (same as aarch64-linux) -> every dglib op in software quad
- `-mlong-double-64` rejected by the driver, `-Xclang -mlong-double-64` accepted but ABI mismatch with zig's prebuilt libc/libc++ (wasm-ld: signature mismatch `ostream<<(long double)`, `to_string(long double)`) -> dead end, hence the dgreal typedef (`../lib/patches/dgreal.py`)

| build, 200k pts geo -> Q2DI res9 | pts/s | vs native arm64 |
|---|---|---|
| native aarch64-macos (long double == double) | ~700k | 1 |
| wasm32-wasi, long double (upstream) | 9.8k | ~70x slower |
| wasm32-wasi, `-Ddgreal=double` | 387k | ~55% of native |
| x86_64-macos rosetta, long double | 14k | rosetta x87 emulation, not representative |
| x86_64-macos rosetta, `-Ddgreal=double` | 449k | |

## coordtrans / south pole vertex (-> patch 0102)

- first dgreal=double wasm run: hash differed from native, 1 in 20k pts in a different cell (same with the -mlong-double-64 hack -> not an ABI thing)
- trace: projTri x already off ~9e-9 -> `vert11` (rotated south pole) lon -2.9452430762 vs -2.9452431127 (3.6e-8 rad), triangles 15-19 (centres, dazh) inherit it, flips are neighbour cells ((2,3) in Q2DI = one class III step), i.e. pts within ~1e-8 of a cell edge
- double libm itself fine: sin/cos/acos/asin/atan <= 1 ulp wasm vs mac, tan <= 3, atan2/sqrt identical (200k inputs)
- cause: `coordtrans()` (DgProjTriRF.cpp) takes lon as `acos(x / sin(lat))` + sign test. for the pole x / sin(lat) is exactly -1 -> acos ill-conditioned there, 3 ulp -> sqrt(6e-16) ~ 3.6e-8 rad. mac libm happens to round to exactly -1, musl doesn't
- fix 0102: `lon = lon0 - atan2(y, x)`, same sign convention -> wasm double hash == native
- side effect long double x86_64 (80-bit): 1 of 98 example files changes, `isea3h5.kml` south pole vertex printed `-157.36031,-90.00000` instead of `0.00000,-90.00000` (same point, lon undefined at the pole). harmless
- -> windows-arm64 (53-bit long double, UCRT libm) probably hits the same thing: candidate for the z3CellClip/zCellClip cell count diffs (4140 vs 4108) in build_notes.md "open". check with 0102 on a windows-11-arm runner? upstream-worthy anyway

## open

- process exit crash (command modules only, bench.wasm): `RuntimeError: null function or function signature mismatch` in `__funcs_on_exit` <- `__wasm_call_dtors` <- `_start`, after main returned. only once an IDGGS was built (`DgRFNetwork` + `DgGeoSphRF` alone exit clean, plain static std::string + atexit test programs too). no dglib atexit calls, no linker warnings. dggrid.wasm is a reactor, never runs exit handlers -> irrelevant for the lib, not chased. command outputs need `fflush(stdout)` before return
- browser demo page (map click -> cell + hexagon), not done yet. dggrid.mjs should work as is
- Arrow C data structs from linear memory for JS (arrow-js-ffi as in geoarrow-wasm?), untested
- wasm-opt not tried
