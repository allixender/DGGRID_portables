# prototype lib build

dglib (+ geoarrow-c) as a library, from a patched plain source copy in `.src/` (gitignored). the DGGRID submodule and the release build stay upstream + `../../patches/`.

```bash
./setup_src.sh                                  # (re)create .src/, rerun after a submodule bump
zig build -Ddgreal=double                       # libdggrid shared lib + include/dggrid.h, libdglib.a, libgeoarrow.a, bench, smoke
zig build test -Ddgreal=double                  # C API tests (dggrid.zig)
zig build dggrid -Ddgreal=double -Doptimize=ReleaseFast   # CLI from the copy, for verification
python3 check_cli.py zig-out/lib/libdggrid.dylib zig-out/bin/dggrid /tmp/dgcheck   # API (ctypes) vs CLI
zig build bench -Doptimize=ReleaseFast -- 200000
zig build smoke                                 # dglib cell -> GeoArrow WKB array
zig build -Dtarget=wasm32-wasi -Ddgreal=double -Doptimize=ReleaseFast -p zig-out/wasm   # dggrid.wasm, see ../wasm/
```

## C API (IGEO7)

`include/dggrid.h`, layers:

- `dgcore.cpp`: only file touching DGGRID classes. ctx = DgRFNetwork + DgGeoSphRF + DgIDGGS7H (res 0-20) + DgZ7System. batch loops, plain C, catches the fatal-hook exception -> error code
- `dggrid.zig`: the exported C ABI (`export fn dg_*`). owns the handle + error message, validates everything first (res, lon/lat range + NaN, Z7 validity) -> on wasm DGGRID fatal = trap, so nothing invalid gets through. Z7 int <-> string + resolution in Zig (bit layout from DgZ7System.cpp, no DGGRID call), batches split into runs of equal resolution
- consumers: shared lib (ctypes/cffi, Julia ccall, R), wasm32-wasi reactor (`dggrid.wasm`, exports exactly the API, ../wasm/dggrid.mjs)

functions: `dg_igeo7_new` (vert0 11.25 / 58.28252559, az 0 = DGGRID IGEO7 preset) / `dg_ctx_new(vert0_lon, vert0_lat, az)`, `dg_geo_to_z7`, `dg_z7_to_centroid`, `dg_z7_to_boundary` (6 (lon, lat) pairs per cell, nverts 6 or 5, NaN padded), `dg_z7_res`, `dg_z7_to_string`, `dg_z7_from_string`, `dg_last_error`, `dg_alloc`/`dg_free`. single-threaded, one ctx per thread

gotcha found on the way: `DgRF::forceAddress()` swaps the address but keeps the location's frame -> a DgLocation reused across convert() calls reads the next point in the wrong frame. fresh stack DgLocation per element in dgcore.cpp

### checks 2026-10-02 (M2 Pro, -Ddgreal=double)

- `zig build test`: 4/4 (Tartu round trip point -> cell -> centroid -> same cell, 12 pentagons, invalid input, Z7 strings), also with longdouble
- `check_cli.py` vs the prototype dggrid CLI with `dggs_type IGEO7`, 3005 pts (random on the sphere + poles, ±180, vert0, Tartu): Z7 ids + strings identical at res 0/1/5/9/13/17/20; centroids + boundaries of those cells (GENERATE_GRID ADDRESS_FILES) and whole earth res 1 + 3 (3432 cells, 12 pentagons) within 5e-13 deg (= CLI print precision 12)
- native via ctypes, 200k pts res 9: geo_to_z7 386k pts/s, z7_to_centroid 855k/s, z7_to_boundary 201k/s

## what setup_src.sh does

- `git archive` of the pinned DGGRID (src/, examples/) + geoarrow-c (src/) commits -> plain files, local edits in the submodules can't leak in
- `ci/apply_patches.sh .src/DGGRID ../../patches patches` -> release patches first, then prototype-only ones
- `patches/dgreal.py` rewrite -> `diff -ru ../../DGGRID/src .src/DGGRID/src` shows everything

## patches (prototype only)

- `0101-fatal-hook.patch`: `DgBase::setFatalHook()`, called on every Fatal report before printing and regardless of `minReportLevel`. default NULL -> CLI unchanged (print + `exit(1)`). native lib: hook throws, C API catches. wasm: no exceptions -> abort/trap
- `0102-coordtrans-atan2.patch`: rotated icosahedron vertex lon via `atan2` instead of `acos(x / sin(lat))`. the south pole vertex sits exactly on acos' ill-conditioned point, with a 53-bit long double 3 ulp -> 3.6e-8 rad -> neighbour-cell flips in triangles 15-19 depending on libm (details in ../wasm/NOTES.md). upstream candidate
- `dgreal.py` (generated, not a static patch: ~1100 lines in ~145 files): `long double` -> `dgreal`, `sinl()` etc -> `std::sin()`, `1.5L` -> `DGR(1.5)`, `%LF` -> `"%" DG_RFMT_L "F"`. `dglib/DgReal.h` picks the type, `-DDG_REAL_DOUBLE` (= `-Ddgreal=double`) -> double. idempotent, prints what it changed

## verification 2026-10-02 (M2 Pro, 32 examplesNoGDAL, byte compare of all 98 output files)

| build | vs | differ |
|---|---|---|
| longdouble aarch64 | upstream aarch64 | 0 |
| longdouble x86_64 (80-bit, rosetta) | upstream x86_64 | 0 without 0102, 1 with 0102 (south pole vertex lon, isea3h5.kml) |
| double aarch64 | upstream aarch64 | 0 (long double == double there) |
| double x86_64 | upstream aarch64 | 10 (vs 50 for upstream x86_64), last digit + shp doubles, macOS libm x86 vs arm |

-> rewrite is exact in long double mode. bench hash (200k pts geo -> Q2DI res9) identical on aarch64/x86_64 native both modes and wasm both modes (with 0102)

## next

- Arrow / GeoArrow in + out next to the raw buffers: points -> Z7 uint64 array, cells -> geoarrow polygon built directly (not via WKT like smoke.cpp)
- parent/children (Z7 parent = digit truncation? pentagon children), Z7 hex string form like the CLI
- hot loop still allocates per element inside DGGRID's convert() chain (malloc heavy, cf. karula perf in build_notes)
- shared lib exports all of dglib's C++ symbols too -> visibility / export list like the wasm build
- windows-x86_64 here needs the `src/mingw_ldouble_numput.cpp` shim + `__USE_MINGW_ANSI_STDIO` like the root build, not wired yet (only matters in long double mode)
