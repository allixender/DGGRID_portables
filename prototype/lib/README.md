# prototype lib build

dglib (+ geoarrow-c) as a library, from a patched plain source copy in `.src/` (gitignored). the DGGRID submodule and the release build stay upstream + `../../patches/`.

```bash
./setup_src.sh                                  # (re)create .src/ from the gitlink commit, rerun after a submodule bump
zig build -Ddgreal=double                       # libdggrid shared lib + include/dggrid.h, libdglib.a, libgeoarrow.a, bench, smoke
zig build test -Ddgreal=double                  # C API tests (dggrid.zig)
zig build dggrid -Ddgreal=double -Doptimize=ReleaseFast   # CLI from the copy, for verification
(cd ../.. && zig build -Doptimize=ReleaseFast)  # upstream CLI = the oracle for check_cli.py
python3 check_cli.py zig-out/lib/libdggrid.dylib ../../zig-out/bin/dggrid /tmp/dgcheck   # API (ctypes) vs CLI, all presets
TOPO_RES=6 python3 check_cli.py ...                     # full run: topology vs CLI up to res 6 (default 5, res 6 = ca 80 s CLI per preset)
python3 check_arrow.py zig-out/lib/libdggrid.dylib /tmp/dgcheck   # Arrow / GeoArrow, needs pyarrow geoarrow-pyarrow shapely geopandas pyproj numpy
zig build bench -Doptimize=ReleaseFast -- 200000
zig build smoke -Ddgreal=double                 # IGEO7v2 cell -> GeoArrow WKB array
zig build -Dtarget=wasm32-wasi -Ddgreal=double -Doptimize=ReleaseFast -p zig-out/wasm   # dggrid.wasm, see ../wasm/
```

## C API (DGGRID 9.2, presets unchanged since 9.1)

`include/dggrid.h`, layers:

- `dgcore.cpp`: only file touching DGGRID classes. ctx = DgRFNetwork + DgGeoSphRF (authalic sphere) + `DgIDGGSBase::makeRF(.., proj, .., Z7)` (res 0-20), same path as the CLI. batch loops, plain C, catches the fatal-hook exception -> error code. WGS84 presets: latitude through `DgAuthalic` per value, longitude untouched
- `dggrid.zig`: the exported C ABI (`export fn dg_*`). owns the handle + error message, validates everything first (res, lon/lat range + NaN, Z7 validity incl. deleted pentagon digits) -> on wasm DGGRID fatal = trap. Z7 int <-> string in Zig, batches split into runs of equal resolution
- `z7.zig`: Z7 index arithmetic, no DGGRID call (bit layout from DgZ7System.cpp): validity + resolution, parent, children, GBT neighbours, see "Z7 topology"
- consumers: shared lib (ctypes/cffi, Julia ccall, R), wasm32-wasi reactor (`dggrid.wasm`, exports exactly the API, ../wasm/dggrid.mjs)

| preset | upstream dggs_type | proj | lat in/out | vert0 lon |
|---|---|---|---|---|
| `DG_IGEO7V2` | IGEO7v2 = ISEA7HLZ (IGEO7 alias) | ISEA | WGS84 geodetic | 11.20 |
| `DG_IGEO7V1` | IGEO7v1 = ISEA7HSZ (8.x IGEO7) | ISEA | authalic | 11.25 |
| `DG_IVEA7HL` | IVEA7HL / IVEA7HLZ | IVEA | WGS84 geodetic | 11.20 |
| `DG_IVEA7HS` | IVEA7HS / IVEA7HSZ | IVEA | authalic | 11.25 |

all: vert0 lat exact icosahedron vertex 58.28252558853899.. (on the authalic sphere, also for L), azimuth 0

functions: `dg_preset_new(preset)`, `dg_igeo7_new()` (= IGEO7v2, changed from the sphere grid before 9.1), `dg_ctx_new(proj, datum, vert0_lon, vert0_lat, az)` (lat NaN = exact vertex), `dg_geo_to_z7`, `dg_z7_to_centroid`, `dg_z7_to_boundary` (6 (lon, lat) pairs per cell, nverts 6 or 5, NaN padded, lon > 180 across the antimeridian by default, `dg_ctx_set_lon_wrap`), `dg_z7_res`, `dg_z7_to_string`, `dg_z7_from_string`, `dg_z7_neighbors` / `_children` / `_parent` / `_res_batch` (see Z7 topology), `dg_last_error`, `dg_alloc`/`dg_free`. single-threaded, one ctx per thread

```julia
ctx = @ccall lib.dg_preset_new(0::Cint)::Ptr{Cvoid}   # IGEO7v2, plain ccall, no CxxWrap
@ccall lib.dg_geo_to_z7(ctx::Ptr{Cvoid}, 9::Cint, lon::Ptr{Cdouble}, lat::Ptr{Cdouble}, n::Csize_t, z::Ptr{UInt64})::Cint
```

gotcha: `DgRF::forceAddress()` swaps the address but keeps the location's frame -> a DgLocation reused across convert() calls reads the next point in the wrong frame. fresh stack DgLocation per element in dgcore.cpp

limits:
- Z7 ids in a pentagon's deleted sub-sequence (`002`, `0605`) don't exist, DGGRID itself silently decodes them to another cell (`002` = `006`, upstream TODO in DgZ7System). rejected here, valid id count per res = 10 * 7^r + 2 is a test
- res 20 at an exact pole: input lies on the edge between 2 cells (08.. / 11..), libm rounding picks one. with double those cells collapse numerically (seen: 5 of 6 vertices exactly `-90`, the 6th ca 10 cm off), upstream arm64 CLI same
- within 1 deg of a pole: double vs 80-bit long double differ up to 2.4e-7 deg at res 20 (ca 3 cm, res 9 ca 3e-9), elsewhere 5e-12
- exact pole input: ties also across platforms, mac arm64 vs karula CLI pick different cells at 0-2 of 2 pole points. `check_cli.py` allows it only if both cells reach the pole
- 9.2 regression, ISEA presets in double (the lib, and the CLI wherever long double = double: mac arm64, windows arm64): pole cells res 17 -> 5 vertices, res 18-20 -> 1 vertex = the pole itself (9.1: 6). `DgProjISEA.cpp` snyderInv snaps to the pole when `1 - |sinlat| <= 4 * LDBL_EPSILON` = within ca 2.4e-6 deg (27 cm) in double, x87 5e-8 deg -> whole cells snap, 9.2's `dropDuplicatePoints` (DgIDGGBase, 1e-12 rad) then leaves one point. Arrow polygons out of such a cell are degenerate. IVEA not affected, x87 / quad hide it. fix = lat + lon by atan2 from all three components (direct problem), no snap: 6 vertices again, 0.01 mm vs x87 (9.1 double: 5.8 cm), 39 examples unchanged except hiRes shp (2.8e-14 deg) -> for Kevin, not applied here

### checks 2026-11-09 on 9.2 @ 81de09a (M2 Pro native only, karula pending, no VPN)

- `setup_src.sh`: `0001`, `0002`, `0101` apply unchanged. `dgreal.py` covers the new `DgEllipsoidRF.cpp` (DgWGS84RF.cpp gone) + `DgDVec3D.h`, no `*l()` math left outside comments. dgcore.cpp unchanged, presets + `makeRF` same in 9.2
- `zig build test`: double + longdouble ok
- `check_cli.py` vs 9.2 root CLI, 4 presets, 3005 pts: Z7 ids + strings identical res 0-20, centroids + boundaries within 6.1e-13 deg, whole earth res 1 + 3 all 3 wrap modes, topology res 0-6 = CLI, OK
- new vs 9.1: 2 exact pole ties (IGEO7v1 res 17, IVEA7HL res 5), allowed rule (both cells reach the pole). longdouble lib same, but long double == double on mac arm64 anyway -> nudge changes in 9.2 (scaled by res, upstream #111)? not chased
- `check_arrow.py` OK (uv env: pyarrow geoarrow-pyarrow shapely geopandas pyproj numpy), rss flat 525 MB over 50 round trips
- wasm32-wasi `test.mjs` OK: res 20 0 ids differ (1 pole tie), neighbours whole earth res 6 = CLI, boundaries 9.1e-13 deg. `dggrid.wasm` 974 KB
- cross build double: x86_64 + aarch64-linux-musl, x86_64-windows-gnu ok, not run
- CLI from the copy, 39 examples, 200 output files: longdouble 0 + double 0 differ vs root CLI (mac arm64). bench hash `b90723bb9bf21ffb` unchanged
- karula 2026-11-10 (`bin/proto-v9.2/`, verify.sh + slim verify3.sh): longdouble lib vs gcc 16 + zig gnu CLI (x87) 0 fails, topology res 0-6 equal. double lib vs x87 CLI 7 fails in both, all ISEA pole cells (vertex count + 2.2e-6 deg at res 17) = the 9.2 pole snap, see limits. IVEA clean
- karula examples 39/39, 196 files: longdouble copy = upstream byte for byte, double vs x87 58 differ (9.1: 60), gcc vs zig gnu 21 (multipleOrientations). test + test musl 12/12 both types, bench hash same, wasm node 22 OK, check_arrow both types OK, rss flat
- `TOPO_RES` default 6 -> 5 (CLI children output at res 6 = ca 56 of 71 s per preset)

### checks 2026-11-02 (reference platforms: M2 Pro native, karula x86_64 native; DGGRID 9.1 @ 4f8bf61)

- `zig build test`: 9/9, double + long double, mac arm64 + karula gnu + karula musl
- `check_cli.py` vs unmodified root CLI, 4 presets, 3005 pts (random on the sphere + poles, ±180, vert0, Tartu): Z7 ids + strings identical at res 0/1/5/9/13/17/20; centroids + boundaries of those cells and whole earth res 1 + 3 (3432 cells, 12 pentagons) in all 3 wrap modes, longitudes strict, within 5.1e-13 deg (= CLI print precision 12)
- fuzz IGEO7v2 + IVEA7HL (scratch, not in repo): ca 17k valid ids -> centroid -> same cell 100%, 200k pts res 0/3/9/20 incl. lat 1e-300 and 90 - 1e-14, no fatal. 1 mismatch, res 20, 1e-14 deg from the pole
- Julia ccall ok, same ids as CLI (IGEO7v2, IVEA7HL Tartu res 9)
- aarch64-linux-musl in podman: smoke + bench, double and quad long double, same cell + hash
- 7 targets x 2 real types build (macos x86_64/arm64, linux musl x86_64/arm64, linux gnu.2.17 x86_64, windows gnu x86_64/arm64), windows not run
- karula, API vs gcc CLI (80-bit) + vs zig CLI: long double 0 fails, 0 ties, 5.1e-13 deg. double 0 fails, 3003 of 3005 pts identical ids at res 0-20 in all presets, the 2 others = exact pole ties, 5e-12 deg
- mac arm64 CLI vs karula gcc CLI directly: same cell sets, 5e-12 deg, ids differ only at exact poles

native via ctypes, 200k pts res 9, k/s:

| preset | geo -> Z7 | Z7 -> centroid | Z7 -> boundary |
|---|---|---|---|
| IGEO7v2 | 397 | 751 | 170 |
| IGEO7v1 | 406 | 887 | 208 |
| IVEA7HL | 562 | 938 | 234 |
| IVEA7HS | 581 | 1137 | 308 |

-> WGS84 costs 15-24% on outputs (Newton per latitude), input ca 2%. IVEA faster than ISEA. ctx new ca 1 ms

## Arrow + GeoArrow

`include/dggrid_arrow.h`, `dgarrow.c`: Arrow C Data Interface over the public C API, no DGGRID classes, in libdggrid + dggrid.wasm. all encodings through geoarrow-c's reader / writer visitors, no WKT detour

| function | in | out |
|---|---|---|
| `dg_arrow_geo_to_z7` | geoarrow.point (struct, interleaved), geoarrow.wkb, geoarrow.wkt | uint64 `z7` |
| `dg_arrow_lonlat_to_z7` | plain lon + lat, float64 / float32 | uint64 `z7` |
| `dg_arrow_z7_to_points` | uint64 / int64 ids (mixed res ok) | point, encoding `DG_ARROW_NATIVE` / `INTERLEAVED` / `WKB` / `WKT` |
| `dg_arrow_z7_to_polygons` | same | polygon, same encodings |

- plain arrays out: `DG_ARROW_NATIVE` points are struct<x, y> of 2 float64 children, ie. lon + lat arrays
- inputs borrowed (sliced arrays ok), outputs owned by the caller -> release callbacks, `pa.Array._import_from_c`. on error outputs have release NULL + `dg_last_error`
- null in -> null out, POINT EMPTY or NaN + NaN = null. only one NaN = error
- input CRS: none = the preset's datum. WGS84 presets take OGC:CRS84 / EPSG:4326 (string or PROJJSON, top level GeographicCRS), authalic presets take none, else error, nothing reprojects. output: WGS84 presets OGC:CRS84 PROJJSON, authalic presets no CRS
- longitudes: `dg_ctx_set_lon_wrap`, see below. no `edges` tag, cell edges aren't planar lon/lat lines or exact great circles

### longitude wrap

`dg_ctx_set_lon_wrap(ctx, DG_UNWRAP_EAST | DG_UNWRAP_WEST | DG_WRAP)`, = CLI `longitude_wrap_mode` via upstream's `DgGeoSphRF::lonWrap` (cell spanning >= 120 deg -> all vertices to one side). applies to `dg_z7_to_boundary` + polygons out. **default of a ctx = UNWRAP_EAST, CLI default = WRAP**

- centroids stay in -180..180 (= CLI `unwrap_points FALSE`), points go back in as ids. point input takes up to +-360 and normalises -> shapely centroid of an unwrapped cell works too
- east vs west: same cells, same counts, mirror images. east -> lon just past 180, up to 344 for the polar cells

whole earth IGEO7v2, planar lon/lat, invalid in shapely / span > 120 deg / sum of areas (box = 64800):

| res | WRAP | UNWRAP_EAST |
|---|---|---|
| 0 | 0 / 5 / 72000 | 0 / 4 / 58484 |
| 1 | 5 / 12 / 96964 | 2 / 4 / 58389 |
| 2 | 6 / 25 / 115553 | 0 / 4 / 64279 |
| 3 | 20 / 65 / 123119 | 2 / 4 / 63876 |
| 4 | 42 / 169 / 126833 | 0 / 4 / 64724 |
| 5 | 113 / 436 / 128412 | 2 / 4 / 64668 |

-> remaining 4 cells at every res = the 2 per pole whose shared edge runs through the pole (vertices jump exactly 180 deg). no longitude shift can fix these, would need extra vertices at the pole (lon +-180, lat +-90) or dropping to geography types. at even res they pass `is_valid` with a wrong shape. other presets same picture

`check_arrow.py`, reference = raw buffer API + CLI cells.geojson: all 4 presets, all encodings + nulls, slices, int64 ids, empty arrays, 20 error cases incl. context usable after. consumers: pyarrow `validate(full=True)` + geoarrow-pyarrow, shapely (WKB / WKT), geopandas 1.2 both ways (own GeoArrow code, no geoarrow-c). wasm32 (other struct layout): dggrid.mjs reads the C structs, ids + polygons + nulls + CRS tag in test.mjs

200k pts res 9, IGEO7v2, k/s:

| | mac arm64 double | karula x86_64 double | karula x86_64 long double |
|---|---|---|---|
| points struct -> z7 | 389 | 291 | 69 |
| points wkb -> z7 | 392 | 290 | 68 |
| lon, lat -> z7 | 393 | 292 | 69 |
| z7 -> points | 744 | 705 | 214 |
| z7 -> polygons | 173 | 189 | 42 |
| z7 -> polygons wkb | 172 | 188 | 42 |

-> Arrow layer overhead not measurable next to DGGRID (raw geo -> Z7 397k/s). x87 long double 4-5x slower -> double for the lib

## Z7 topology (2026-11-03)

pure index arithmetic in `z7.zig`, the same for every preset (Z7 = topology of the icosahedron net, orientation / projection / datum don't enter). ctx only carries the error message, `NULL` ok

| C | Arrow | out |
|---|---|---|
| `dg_z7_neighbors` | `dg_arrow_z7_neighbors` | 6 per cell in GBT direction order 1..6, pentagon gap = `DG_Z7_NONE` (= UINT64_MAX) / null element of a `fixed_size_list<uint64>[6]` |
| `dg_z7_children` | `dg_arrow_z7_children` | 7 per cell in digit order, pentagon skip digit (2 for base cells 0-5, 5 for 6-11) = `DG_Z7_NONE` / `list<uint64>` of 7 or 6 |
| `dg_z7_parent(.., res)` | `dg_arrow_z7_parent` | ancestor at res, -1 = one level up; base cell + -1, or res > the cell's -> error |
| `dg_z7_res_batch` | | int8 per id, -1 invalid |
| | `dg_arrow_z7_to_string` / `_from_string` | utf8 <-> uint64, large_utf8 in ok, null -> null |

- neighbours: Generalized Balanced Ternary addition, CW tables at odd / CCW at even resolutions, carry into the neighbouring base cell, rotations into / out of the polar base cells 0 + 11, exclusion zone rotation next to pentagons. ported from z7py (Apache-2.0) <- z7_julia <- the C++ Z7 reference (W. J. Renoud, J. Jimenez Shaw, github.com/wrenoud/Z7)
- the 3 reference implementations (z7py numba, z7_julia `Z7IndexUInt64` + `Z7IndexComp`): same slot arrays as `z7.zig` for all 196,092 cells res 0-5 (order + gaps). C++ itself not built (download misses `BitFieldProxy.h`), its test vectors are in `z7.zig`
- differences found in the references, all edge cases: no input validation anywhere (base cell 12-15 = out of bounds table read; a 7 inside the digits: C++ counts the resolution from the end, Python/Julia take the first 7). C++ indexes `pole_0_rotations[row-1][col-1]` and `elem[first_non_zero]` unchecked (0 / 21 possible in principle), z7py + Julia guard both, `z7.zig` too. upstream test checks only "DGGRID's neighbours are among the reported ones", res 2-3, 8.x ISEA7H
- convenience functions in z7py / Julia, not taken over: hex <-> digit lists (bindings: `%016x`), `local_pos` (= last digit, wrong at res 0: "05" -> parent "0"), monotonic range index (z7py, base * 7^L + digits, keeps pentagon gaps -> next), C++ `operator++` walks into deleted pentagon ids (`0002`)

checks:
- `zig build test`: the reference vectors (single GBT steps, exclusion zone 1-4, pentagons 00 / 0800 / 090 at res 1, 19, 20)
- `check_cli.py` vs the 9.1 CLI `neighbor_output_type` + `children_output_type`, whole earth res 0-6 (1.37M cells per preset), all 4 presets: neighbour sets equal (6, pentagons 5), Z7 children = the first 7 (6) of the CLI's children = its interior children (the CLI also lists the 6 (5) res + 1 cells straddling the edge), parent(children) = cell
- res 7-20, 1000 random cells + the 12 pentagon centres per res, all presets: every neighbour shares exactly 2 vertices (1e-9 deg) with the cell, relation symmetric
- `check_arrow.py`: Arrow outputs = raw, types, nulls, slices, NULL ctx errors. wasm `test.mjs`: vectors + GBT vs CLI neighbour file, 1.18M cells per preset

- karula x86_64 native, double + long double: zig tests (gnu + musl), check_cli vs the gcc 80-bit CLI res 0-5 + geometry res 6-20 all presets, check_arrow, demo.py OK

speed, mac arm64, 200k res 9 ids (karula: 12.3M/s raw in both real types, integer only): neighbours raw 14.6M/s, Arrow 11.3M/s (fixed_size_list), children Arrow 21M/s, to string 19M/s. ca 40x a point -> cell, wasm neighbours ca free next to geoToZ7

## what setup_src.sh does

- `git archive` of the pinned DGGRID (src/, examples/) + geoarrow-c (src/) commits -> plain files, local edits in the submodules can't leak in
- `ci/apply_patches.sh .src/DGGRID ../../patches patches` -> release patches first, then prototype-only ones
- `patches/dgreal.py` rewrite -> `diff -ru ../../DGGRID/src .src/DGGRID/src` shows everything

## patches (prototype only)

- `0101-fatal-hook.patch`: `DgBase::setFatalHook()`, called on every Fatal report before printing and regardless of `minReportLevel`. default NULL -> CLI unchanged (print + `exit(1)`). native lib: hook throws, C API catches. wasm: no exceptions -> abort/trap
- `0102-coordtrans-atan2.patch`: dropped 2026-11-02, upstream's 9.1 `coordtrans` uses atan2l itself ("loss of precision near rotated icosahedron vertices"). bench hash native == wasm double without it
- `dgreal.py` (generated, not a static patch: ~2300 replacements in 158 files on 9.1): `long double` -> `dgreal`, `sinl()` etc -> `std::sin()` (9.1 adds `atanhl`, `log1pl`, `hypotl`, `copysignl`), `1.5L` -> `DGR(1.5)`, `%LF` -> `"%" DG_RFMT_L "F"`, `LDBL_MAX` etc -> `DGR_MAX`. `dglib/DgReal.h` picks the type, `-DDG_REAL_DOUBLE` (= `-Ddgreal=double`) -> double. idempotent, prints what it changed

## verification 2026-11-02 (39 examplesNoGDALorH3, byte compare of all 196 output files)

| build | vs | differ |
|---|---|---|
| longdouble mac arm64 | upstream mac arm64 | 0 |
| double mac arm64 | upstream mac arm64 | 0 (long double == double there) |
| longdouble karula | upstream karula (zig gnu) | 0 |
| zig gnu karula | gcc karula | 21, only multipleOrientations (libc rand) |
| zig musl karula | gcc karula | 23, + superfundGrid (1 ulp shp, known) |
| double karula | upstream karula | 60. text outputs: 48 numbers, 41 = the bits of long double in the log, 7 = last printed digit or lon at a pole, no structure diffs |

-> rewrite is exact in long double mode. bench hash (200k pts geo -> Q2DI res9) `b90723bb9bf21ffb` on mac arm64, karula double + long double, wasm double

## next

- the 4 pole cells: pole vertices? (= leaves CLI parity)
- whole table / ArrowArrayStream, chunked input is a loop on the caller's side for now
- JS: arrow-js-ffi instead of the hand written struct reader in dggrid.mjs, untested
- Z7 k-ring / disk on top of `dg_z7_neighbors` (dedupe), range index (z7py `z7_to_monotonic_int`)
- Z7 hex string form like the CLI
- hot loop still allocates per element inside DGGRID's convert() chain (malloc heavy, cf. karula perf in build_notes)
- shared lib exports all of dglib's C++ symbols too -> visibility / export list like the wasm build
- windows-x86_64 here needs the `src/mingw_ldouble_numput.cpp` shim + `__USE_MINGW_ANSI_STDIO` like the root build, not wired yet (only matters in long double mode)
