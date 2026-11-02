# prototype lib build

dglib (+ geoarrow-c) as a library, from a patched plain source copy in `.src/` (gitignored). the DGGRID submodule and the release build stay upstream + `../../patches/`.

```bash
./setup_src.sh                                  # (re)create .src/ from the gitlink commit, rerun after a submodule bump
zig build -Ddgreal=double                       # libdggrid shared lib + include/dggrid.h, libdglib.a, libgeoarrow.a, bench, smoke
zig build test -Ddgreal=double                  # C API tests (dggrid.zig)
zig build dggrid -Ddgreal=double -Doptimize=ReleaseFast   # CLI from the copy, for verification
(cd ../.. && zig build -Doptimize=ReleaseFast)  # upstream CLI = the oracle for check_cli.py
python3 check_cli.py zig-out/lib/libdggrid.dylib ../../zig-out/bin/dggrid /tmp/dgcheck   # API (ctypes) vs CLI, all presets
zig build bench -Doptimize=ReleaseFast -- 200000
zig build smoke -Ddgreal=double                 # IGEO7v2 cell -> GeoArrow WKB array
zig build -Dtarget=wasm32-wasi -Ddgreal=double -Doptimize=ReleaseFast -p zig-out/wasm   # dggrid.wasm, see ../wasm/
```

## C API (DGGRID 9.1 presets)

`include/dggrid.h`, layers:

- `dgcore.cpp`: only file touching DGGRID classes. ctx = DgRFNetwork + DgGeoSphRF (authalic sphere) + `DgIDGGSBase::makeRF(.., proj, .., Z7)` (res 0-20), same path as the CLI. batch loops, plain C, catches the fatal-hook exception -> error code. WGS84 presets: latitude through `DgAuthalic` per value, longitude untouched
- `dggrid.zig`: the exported C ABI (`export fn dg_*`). owns the handle + error message, validates everything first (res, lon/lat range + NaN, Z7 validity incl. deleted pentagon digits) -> on wasm DGGRID fatal = trap. Z7 int <-> string + resolution in Zig (bit layout from DgZ7System.cpp, no DGGRID call), batches split into runs of equal resolution
- consumers: shared lib (ctypes/cffi, Julia ccall, R), wasm32-wasi reactor (`dggrid.wasm`, exports exactly the API, ../wasm/dggrid.mjs)

| preset | upstream dggs_type | proj | lat in/out | vert0 lon |
|---|---|---|---|---|
| `DG_IGEO7V2` | IGEO7v2 = ISEA7HLZ (IGEO7 alias) | ISEA | WGS84 geodetic | 11.20 |
| `DG_IGEO7V1` | IGEO7v1 = ISEA7HSZ (8.x IGEO7) | ISEA | authalic | 11.25 |
| `DG_IVEA7HL` | IVEA7HL / IVEA7HLZ | IVEA | WGS84 geodetic | 11.20 |
| `DG_IVEA7HS` | IVEA7HS / IVEA7HSZ | IVEA | authalic | 11.25 |

all: vert0 lat exact icosahedron vertex 58.28252558853899.. (on the authalic sphere, also for L), azimuth 0

functions: `dg_preset_new(preset)`, `dg_igeo7_new()` (= IGEO7v2, changed from the sphere grid before 9.1), `dg_ctx_new(proj, datum, vert0_lon, vert0_lat, az)` (lat NaN = exact vertex), `dg_geo_to_z7`, `dg_z7_to_centroid`, `dg_z7_to_boundary` (6 (lon, lat) pairs per cell, nverts 6 or 5, NaN padded), `dg_z7_res`, `dg_z7_to_string`, `dg_z7_from_string`, `dg_last_error`, `dg_alloc`/`dg_free`. single-threaded, one ctx per thread

```julia
ctx = @ccall lib.dg_preset_new(0::Cint)::Ptr{Cvoid}   # IGEO7v2, plain ccall, no CxxWrap
@ccall lib.dg_geo_to_z7(ctx::Ptr{Cvoid}, 9::Cint, lon::Ptr{Cdouble}, lat::Ptr{Cdouble}, n::Csize_t, z::Ptr{UInt64})::Cint
```

gotcha: `DgRF::forceAddress()` swaps the address but keeps the location's frame -> a DgLocation reused across convert() calls reads the next point in the wrong frame. fresh stack DgLocation per element in dgcore.cpp

limits:
- Z7 ids in a pentagon's deleted sub-sequence (`002`, `0605`) don't exist, DGGRID itself silently decodes them to another cell (`002` = `006`, upstream TODO in DgZ7System). rejected here, valid id count per res = 10 * 7^r + 2 is a test
- res 20 at an exact pole: input lies on the edge between 2 cells (08.. / 11..), libm rounding picks one. with double those cells collapse numerically (seen: 5 of 6 vertices exactly `-90`, the 6th ca 10 cm off), upstream arm64 CLI same
- long double mode x86_64 under Rosetta: WGS84 presets -> DG_EDGGRID, double is fine, see build_notes.md 2026-11-02

### checks 2026-11-02 (M2 Pro, DGGRID 9.1 @ 4f8bf61)

- `zig build test`: 7/7, double + long double, x86_64 double too
- `check_cli.py` vs unmodified root CLI, 4 presets, 3005 pts (random on the sphere + poles, ±180, vert0, Tartu): Z7 ids + strings identical at res 0/1/5/9/13/17/20; centroids + boundaries of those cells and whole earth res 1 + 3 (3432 cells, 12 pentagons) within 5.1e-13 deg (= CLI print precision 12)
- fuzz IGEO7v2 + IVEA7HL (scratch, not in repo): ca 17k valid ids -> centroid -> same cell 100%, 200k pts res 0/3/9/20 incl. lat 1e-300 and 90 - 1e-14, no fatal. 1 mismatch, res 20, 1e-14 deg from the pole
- Julia ccall ok, same ids as CLI (IGEO7v2, IVEA7HL Tartu res 9)
- aarch64-linux-musl in podman: smoke + bench, double and quad long double, same cell + hash
- 7 targets x 2 real types build (macos x86_64/arm64, linux musl x86_64/arm64, linux gnu.2.17 x86_64, windows gnu x86_64/arm64), only macos + linux arm64 run here

native via ctypes, 200k pts res 9, k/s:

| preset | geo -> Z7 | Z7 -> centroid | Z7 -> boundary |
|---|---|---|---|
| IGEO7v2 | 397 | 751 | 170 |
| IGEO7v1 | 406 | 887 | 208 |
| IVEA7HL | 562 | 938 | 234 |
| IVEA7HS | 581 | 1137 | 308 |

-> WGS84 costs 15-24% on outputs (Newton per latitude), input ca 2%. IVEA faster than ISEA. ctx new ca 1 ms

## what setup_src.sh does

- `git archive` of the pinned DGGRID (src/, examples/) + geoarrow-c (src/) commits -> plain files, local edits in the submodules can't leak in
- `ci/apply_patches.sh .src/DGGRID ../../patches patches` -> release patches first, then prototype-only ones
- `patches/dgreal.py` rewrite -> `diff -ru ../../DGGRID/src .src/DGGRID/src` shows everything

## patches (prototype only)

- `0101-fatal-hook.patch`: `DgBase::setFatalHook()`, called on every Fatal report before printing and regardless of `minReportLevel`. default NULL -> CLI unchanged (print + `exit(1)`). native lib: hook throws, C API catches. wasm: no exceptions -> abort/trap
- `0102-coordtrans-atan2.patch`: dropped 2026-11-02, upstream's 9.1 `coordtrans` uses atan2l itself ("loss of precision near rotated icosahedron vertices"). bench hash native == wasm double without it
- `dgreal.py` (generated, not a static patch: ~2300 replacements in 158 files on 9.1): `long double` -> `dgreal`, `sinl()` etc -> `std::sin()` (9.1 adds `atanhl`, `log1pl`, `hypotl`, `copysignl`), `1.5L` -> `DGR(1.5)`, `%LF` -> `"%" DG_RFMT_L "F"`, `LDBL_MAX` etc -> `DGR_MAX`. `dglib/DgReal.h` picks the type, `-DDG_REAL_DOUBLE` (= `-Ddgreal=double`) -> double. idempotent, prints what it changed

## verification 2026-11-02 (M2 Pro, 39 examplesNoGDALorH3, byte compare of all 196 output files)

| build | vs | differ |
|---|---|---|
| longdouble aarch64 | upstream aarch64 | 0 |
| longdouble x86_64 (80-bit, rosetta) | upstream x86_64 | 0 (both 37/39, wholeEarthIGEO7 + icosaISEAL hit the rosetta fatal) |
| double aarch64 | upstream aarch64 | 0 (long double == double there) |
| double x86_64 (rosetta) | upstream aarch64 | 13 (39/39), gridgenMixedSHP, hiRes, multipleOrientations, superfundGrid |

-> rewrite is exact in long double mode. bench hash (200k pts geo -> Q2DI res9) `b90723bb9bf21ffb` identical native arm64 + wasm double

## next

- Arrow / GeoArrow in + out next to the raw buffers: points -> Z7 uint64 array, cells -> geoarrow polygon built directly (not via WKT like smoke.cpp)
- Z7 hex string form like the CLI
- hot loop still allocates per element inside DGGRID's convert() chain (malloc heavy, cf. karula perf in build_notes)
- shared lib exports all of dglib's C++ symbols too -> visibility / export list like the wasm build
- Z7 parent/children: digit truncation confirmed in DgZ7System::setAddNdxParent, children skip the pentagon digit, not exposed yet
- windows-x86_64 here needs the `src/mingw_ldouble_numput.cpp` shim + `__USE_MINGW_ANSI_STDIO` like the root build, not wired yet (only matters in long double mode)
