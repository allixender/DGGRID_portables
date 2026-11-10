# prototype/demo/julia: using the library from Julia

`IGEO7.jl` is a stub binding of `../../lib/include/dggrid.h` (+ part of `dggrid_arrow.h`), plain `ccall` against `libdggrid`. It needs no compiler and no packages beyond Base + Libdl. `demo.jl` shows the calls, mirroring `../python/demo.py`. It's a plain `include`, not a registered package.

```
Project.toml, Manifest.toml   environment of this folder (julia 1.12.7): JSON3, LibGEOS + stdlibs
IGEO7.jl                      module IGEO7: Grid, plain API, Z7 topology, WKB / WKT via the Arrow C API
demo.jl                       usage demo, writes tartu_rings.geojson (gitignored)
_lib/                         libdggrid.{dylib,so} / dggrid.dll, copied by ../copy_libs.sh (gitignored)
```

## Run

```sh
cd ../../lib && zig build -Ddgreal=double -Doptimize=ReleaseFast
cd ../demo && ./copy_libs.sh           # -> python/igeo7/_lib/ + julia/_lib/ (+ web/ if the wasm is built)

cd julia
julia --project=. -e 'using Pkg; Pkg.instantiate()'   # once
julia --project=. demo.jl
```

`DGGRID_LIB=/path/to/libdggrid.dylib` overrides `_lib/`, e.g. to point straight at `../../lib/zig-out/lib/`.

## API in short

```julia
include("IGEO7.jl"); using .IGEO7

Grid(:IGEO7v2) do g                          # :IGEO7v1, :IVEA7HL, :IVEA7HS, Grid(:ISEA, :WGS84, 11.2)
    ids = lonlat_to_z7(g, 9, lon, lat)       # Vector{UInt64}
    lon, lat = z7_to_centroid(g, ids)
    rings = z7_to_boundary(g, ids)           # [nverts × 2 Matrix (lon, lat)], 6 or 5, open ring
    z7_string(ids[1]); z7_parse("00010224541"); z7_res(ids[1])
    set_lon_wrap!(g, :east)                  # default; :west, :none = CLI WRAP
    z7_neighbors(g, ids)                     # 6 × n, GBT direction order, Z7_NONE = pentagon gap
    z7_children(g, ids)                      # 7 × n, Z7_NONE = a pentagon's skipped digit
    z7_parent(g, ids); z7_parent(g, ids, 3)  # one level up / ancestor at res 3
    z7_to_polygons_wkb(g, ids)               # Vector of WKB blobs (closed rings), e.g. LibGEOS.readgeom
    z7_to_polygons_wkt(g, ids); z7_to_points_wkb(g, ids)
end
```

- The C side writes `out[k * i + j]`, so in Julia the topology results come out as `k × n` matrices, with column `i` belonging to cell `i`. No copy or transpose is needed.
- `Grid` wraps one `dg_ctx*`. `close(g)` frees it, and so does the finalizer or the end of the do-block. A context is not thread-safe, so use one per task / thread.
- Errors raise `DggridError` with the message from `dg_last_error`. The context stays usable after an error.
- Latitudes are geodetic WGS84 for the WGS84 presets (`:IGEO7v2`, `:IVEA7HL`) and authalic for the others, as in `dggrid.h`.

## Arrow

Arrow.jl reads IPC streams and files, not the Arrow C Data Interface. So `IGEO7.jl` mirrors the two C structs (`ArrowSchema`, `ArrowArray`) itself:

- **Input:** a `uint64` array borrowed for the duration of the call, with no copy. Its release callback only marks the struct released, because nanoarrow rejects `release == NULL`.
- **Output:** `geoarrow.wkb` / `geoarrow.wkt` (binary / utf8, int32 offsets) is copied into Julia vectors and then released through `dg_arrow_release_*`.

The native GeoArrow encodings (struct / interleaved coords) and the Arrow topology outputs aren't wrapped. The plain API covers the same ground.

## Checked 2026-11-10 (mac arm64, julia 1.12.7, lib on proto/lib 8c605b6)

- `demo.jl` output matches `../python/demo.py` line for line:
  - Tartu res 9 = `0x004252c3ffffffff` (`00010224541`), same as the CLI
  - centroid and boundary
  - res 0-9 chain
  - neighbours and children
  - pentagon `0800` gap at direction 5
  - ring 1 = 6, ring 2 = 12
  - the 3 wrap modes of the antimeridian cell
- The pole cells at res 18 have 6 vertices (`patches/0003`).
- 1M random points to res 9 run at about 540k pts/s, against 394k in the numpy demo. The Julia vectors go to C as they are, with no conversion.
- 1000 WKB polygons go into LibGEOS, and all are valid. The GeoJSON (19 cells) parses and its rings are closed.
- `Grid(:ISEA, :WGS84, 11.2)` gives the same ids as `:IGEO7v2`. A closed `Grid`, a bad orientation and res 20 children all raise `DggridError`.

## Not here

- No package (`Project.toml` has no name / uuid) and no JLL: the shared lib comes from `copy_libs.sh` or `DGGRID_LIB`. A real package would ship `libdggrid` as a BinaryBuilder JLL per platform.
- No GeoInterface / GeometryBasics types for the rings, plain matrices. WKB covers the hand-off to LibGEOS, ArchGDAL, GeoDataFrames.
- Not tried on karula / linux yet. Nothing in it is mac specific, the lib name is picked per OS.
