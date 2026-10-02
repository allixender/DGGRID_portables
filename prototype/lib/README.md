# prototype lib build

dglib (+ geoarrow-c) as a library, from a patched plain source copy in `.src/` (gitignored). the DGGRID submodule and the release build stay upstream + `../../patches/`.

```bash
./setup_src.sh                                  # (re)create .src/, rerun after a submodule bump
zig build -Ddgreal=double                       # libdglib.a, libgeoarrow.a, bench, smoke
zig build dggrid -Doptimize=ReleaseFast         # CLI from the copy, for verification
zig build bench -Doptimize=ReleaseFast -- 200000
zig build smoke                                 # dglib cell -> GeoArrow WKB array
zig build -Dtarget=wasm32-wasi -Ddgreal=double  # libdglib + bench.wasm, see ../wasm/NOTES.md
```

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

- C ABI on top (ctx = network + geoRF + IDGGS, single-threaded, one ctx per thread if ever), batch in/out as Arrow arrays: points -> Z7 uint64, cells -> boundaries (geoarrow polygon built directly, not via WKT like smoke.cpp), parent/children
- avoid `new DgLocation` per point in the hot loop (malloc heavy, cf. karula perf in build_notes)
- windows-x86_64 here needs the `src/mingw_ldouble_numput.cpp` shim + `__USE_MINGW_ANSI_STDIO` like the root build, not wired yet (only matters in long double mode)
