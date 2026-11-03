# prototype/demo: using the library from Python and the browser

Stub bindings + usage demos for the prototype library in `../lib/`. Nothing here is built. `copy_libs.sh` copies the artifacts in, and the copies are gitignored.

```
copy_libs.sh                 ../lib/zig-out -> python/igeo7/_lib/, web/
python/igeo7/__init__.py     ctypes binding: numpy API + Arrow API (pyarrow)
python/demo.py
web/index.html, main.js      browser demo: world grid, click -> cell
web/cells.mjs                all cells at a resolution (Z7 digit rule), pole cell test
web/dggrid.d.mts             TypeScript types for dggrid.mjs
```

## Files needed

| use | files | from |
|---|---|---|
| Python / any FFI | `libdggrid.dylib` / `libdggrid.so` / `dggrid.dll` | `../lib/zig-out/lib/` (dll: `bin/`) |
| C callers | + `dggrid.h`, `dggrid_arrow.h` | `../lib/zig-out/include/` |
| browser / node | `dggrid.wasm` + `dggrid.mjs` | `../lib/zig-out/wasm/bin/`, `../wasm/` |

The shared lib is self-contained: DGGRID, geoarrow-c and libc++ are linked in, and on macOS it depends only on libSystem. `libdglib.a` and `libgeoarrow.a` are only needed for static linking. The wasm module needs no WASI runtime, because `dggrid.mjs` stubs the 8 imports itself.

## Run

```sh
cd ../lib && zig build -Ddgreal=double -Doptimize=ReleaseFast \
  && zig build -Dtarget=wasm32-wasi -Ddgreal=double -Doptimize=ReleaseFast -p zig-out/wasm
cd ../demo && ./copy_libs.sh

cd python && python demo.py          # numpy; pyarrow + geoarrow-pyarrow + shapely for the Arrow part
python3 -m http.server -d web 8000   # -> http://localhost:8000 (wasm can't load from file://)
```

The browser demo fetches a Natural Earth land outline from jsdelivr (world-atlas, topojson-client). Offline, it runs without one.

## API in short

```python
from igeo7 import Grid
with Grid("IGEO7v2") as g:                 # IGEO7v1, IVEA7HL, IVEA7HS, Grid.custom(...)
    ids = g.lonlat_to_z7(9, lon, lat)      # np.uint64
    lon, lat = g.z7_to_centroid(ids)
    rings = g.z7_to_boundary(ids)          # [(6|5, 2) arrays]
    g.z7_to_string(ids[0]); g.z7_from_string("00010224541")
    g.lonlat_to_z7_arrow(9, pa_lon, pa_lat)        # pa.uint64, nulls kept
    g.geo_to_z7_arrow(9, geoarrow_points)          # point / wkb / wkt, CRS84 or none
    g.z7_to_points_arrow(ids, "native")            # | interleaved | wkb | wkt
    g.z7_to_polygons_arrow(ids, "wkb")
    g.set_lon_wrap("east")                         # default; "west", "none" = CLI WRAP
    g.z7_neighbors(ids)                            # (n, 6) GBT direction order, NONE = pentagon gap
    g.z7_children(ids); g.z7_parent(ids, res=-1)   # (n, 7) with NONE / ancestors
    g.z7_neighbors_arrow(ids)                      # fixed_size_list<uint64>[6], gap = null
    g.z7_children_arrow(ids); g.z7_to_string_arrow(ids); g.z7_from_string_arrow(strs)
```

```js
import { Igeo7, PRESET } from './dggrid.mjs';
const dg = await Igeo7.load(await (await fetch('dggrid.wasm')).arrayBuffer(), { preset: PRESET.IGEO7v2 });
const ids = dg.geoToZ7(9, [26.729], [58.378]);   // BigUint64Array
dg.z7ToCentroid(ids); dg.z7ToBoundary(ids); dg.z7ToString(ids[0]);
dg.lonLatToZ7Arrow(9, lon, lat); dg.z7ToPolygonsArrow(ids);
dg.z7Neighbors(ids); dg.z7Children(ids); dg.z7Parent(ids);   // index arithmetic, null = pentagon gap
```

The page draws the clicked cell with its 6 GBT neighbours (numbered by direction) and lists parents and children.

## Checked 2026-11-03 (mac arm64)

- `demo.py`: Tartu res 9 = `0x004252c3ffffffff`, same as the CLI value in `../wasm/test.mjs`. 1M points to res 9 at 394k pts/s. The Arrow outputs are geoarrow extension types tagged OGC:CRS84. 1000 WKB polygons go into shapely, all valid.
- web, node: `allCells` res 0-4 = 10·7^r + 2 cells; centroid -> id round trip is exact; 4 pole cells per resolution. Headless Chrome renders the page.
- The `main.js` + `cells.mjs` type check is clean: `npx -p typescript@5.6.3 tsc --noEmit --allowJs --checkJs --strict --module esnext --moduleResolution bundler --target es2022 --lib es2022,dom main.js cells.mjs`.
- On the map, the 4 pole cells are drawn dashed. A cell edge runs through each pole, so two vertices of each of these cells are exactly 180° apart in longitude. The rings are correct on the sphere but not as planar lon/lat polygons, and no wrap mode fixes that.

## Not here

- No Python packaging: run from `python/`, or put `python/` on `PYTHONPATH`. A wheel would need `_lib` per platform.
- No ArrowArrayStream / PyCapsule interface. The Arrow API uses pyarrow's `_export_to_c` / `_import_from_c`.
- The wasm Arrow results are copied out of the C structs by `dggrid.mjs`, not apache-arrow JS tables.
