"""demo.py: usage of the igeo7 stub module. python demo.py (from this folder)

needs numpy; the Arrow part needs pyarrow + geoarrow-pyarrow, shapely for the WKB part.
"""
import time

import numpy as np

from igeo7 import DggridError, Grid

TARTU = (26.729, 58.378)

with Grid("IGEO7v2") as g:
    print(g)

    # point -> cell -> centre + boundary
    ids = g.lonlat_to_z7(9, [TARTU[0]], [TARTU[1]])
    z = ids[0]
    print(f"Tartu res 9: {int(z):#018x} = {g.z7_to_string(z)!r}, res {g.z7_res(z)}")
    lon, lat = g.z7_to_centroid(ids)
    print(f"  centroid {lon[0]:.6f}, {lat[0]:.6f}")
    print("  boundary", np.round(g.z7_to_boundary(ids)[0], 6).tolist())
    assert g.z7_from_string(g.z7_to_string(z)) == z

    # the same point at every resolution: parent chain by string prefix
    chain = [g.z7_to_string(g.lonlat_to_z7(r, [TARTU[0]], [TARTU[1]])[0]) for r in range(0, 10)]
    print("  res 0..9:", " ".join(chain))

    # errors are exceptions, the context stays usable
    for what, fn in [("lat 91", lambda: g.lonlat_to_z7(5, [0], [91])),
                     ("res 21", lambda: g.lonlat_to_z7(21, [0], [0])),
                     ("bad string", lambda: g.z7_from_string("002"))]:
        try:
            fn()
        except DggridError as e:
            print(f"  {what} -> {e}")

    # antimeridian cell, the 3 wrap modes
    am = g.lonlat_to_z7(3, [180.0], [10.0])
    for mode in ("east", "west", "none"):
        g.set_lon_wrap(mode)
        ring = g.z7_to_boundary(am)[0]
        print(f"  antimeridian cell, wrap {mode:4}: lon {ring[:, 0].min():8.3f} .. {ring[:, 0].max():8.3f}")
    g.set_lon_wrap("east")

    # batch: 1M random points
    rng = np.random.default_rng(42)
    n = 1_000_000
    plon, plat = rng.uniform(-180, 180, n), np.degrees(np.arcsin(rng.uniform(-1, 1, n)))
    t = time.perf_counter()
    cells = g.lonlat_to_z7(9, plon, plat)
    dt = time.perf_counter() - t
    print(f"batch: {n} pts -> res 9 in {dt:.2f}s ({n / dt / 1e3:.0f}k pts/s), {len(np.unique(cells))} distinct cells")

    # ---- Arrow ----
    try:
        import geoarrow.pyarrow as ga
        import pyarrow as pa
    except ImportError:
        print("no pyarrow / geoarrow-pyarrow, Arrow part skipped")
        raise SystemExit(0)

    # plain lon/lat arrays -> uint64 array, nulls pass through
    z = g.lonlat_to_z7_arrow(9, pa.array([TARTU[0], None, 0.0]), pa.array([TARTU[1], None, 0.0]))
    print("arrow ids:", z.type, z.to_pylist())

    # GeoArrow points (CRS84) in
    pts = ga.point().with_crs("OGC:CRS84").from_geobuffers(None, np.array([TARTU[0], 0.0]), np.array([TARTU[1], 0.0]))
    print("geoarrow points in:", g.geo_to_z7_arrow(9, pts).to_pylist())

    # cell centres + polygons out, geoarrow extension types with CRS
    cpts = g.z7_to_points_arrow(z.drop_null())
    polys = g.z7_to_polygons_arrow(z.drop_null())
    print("points out:", cpts.type, "| polygons out:", polys.type.extension_name, len(polys))
    print("  crs:", polys.type.crs.to_json_dict().get("id") if polys.type.crs else None)

    # WKB/WKT encodings, e.g. straight into shapely
    wkt = g.z7_to_polygons_arrow(z.drop_null(), encoding="wkt")
    print("  wkt:", wkt.storage[0].as_py()[:80], "...")
    try:
        import shapely
        wkb = g.z7_to_polygons_arrow(cells[:1000], encoding="wkb")
        geoms = shapely.from_wkb(wkb.storage.to_numpy(zero_copy_only=False))
        print(f"  shapely: {len(geoms)} polygons from WKB, all valid: {bool(shapely.is_valid(geoms).all())}")
    except ImportError:
        pass

    # into a pyarrow Table, eg. for GeoParquet via geopandas or straight parquet
    tbl = pa.table({"z7": z.drop_null(), "geometry": polys})
    print("table:", tbl.schema.names, tbl.num_rows, "rows")
