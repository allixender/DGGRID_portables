# dglib -> wasm32-wasi (zig 0.16), notes

2026-10-02, M2 Pro, node v20.11.1 (`node:wasi`, preview1). build + bench live in `../lib/` (`zig build -Dtarget=wasm32-wasi [-Ddgreal=double]`), runner here: `node run.mjs bench.wasm 200000`

## builds?

- yes. dglib + proj4lib + shapelib compile for wasm32-wasi, except the 19 file reader/writer classes (`DgIn*`, `DgOut*`, `DgInputStream`, `DgOutputStream`): zig's wasi libc++ has no `<fstream>` -> `../lib/build.zig` skips `DgIn*`/`DgOut*` on wasm, a lib doesn't need them (no file IO is the point anyway)
- link: only `__cxa_allocate_exception` + `__cxa_throw` missing, zig's wasm libc++abi has no exception support -> `../lib/wasi_cxa_stub.cpp`, any throw = abort = trap. no catchable errors on wasm -> validate inputs in the C API, fatal hook (0101) can only abort there
- results identical to native: 200k random pts geo -> Q2DI res 9, same hash as mac arm64/x86_64 (needs patch 0102 for dgreal=double, see below)
- bench.wasm 12.6 MB unstripped (ReleaseFast, debug info incl), libdglib.a 23 MB. not stripped / wasm-opt'd yet

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

- process exit crash: `RuntimeError: null function or function signature mismatch` in `__funcs_on_exit` <- `__wasm_call_dtors` <- `_start`, after main returned. only once an IDGGS was built (`DgRFNetwork` + `DgGeoSphRF` alone exit clean, plain static std::string + atexit test programs too). no dglib atexit calls, no linker warnings. command modules only, a reactor-style lib (no `_start`) never runs exit handlers -> not chased. outputs need `fflush(stdout)` before return, otherwise lost
- browser: export C ABI + Arrow C data structs from linear memory, read in JS (arrow-js-ffi does that for geoarrow-wasm?), untested
- reactor build (`-mexec-model=reactor`), strip + wasm-opt -> real size
