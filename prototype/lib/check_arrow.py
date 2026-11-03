#!/usr/bin/env python3
"""check_arrow.py <libdggrid> [check_cli workdir]

Consumer test of dg_arrow_* (include/dggrid_arrow.h) over the Arrow C Data Interface:
  pyarrow + geoarrow-pyarrow build the inputs + import the outputs, geopandas (own GeoArrow
  code, no geoarrow-c) is a second reader + writer, shapely reads WKB / WKT.
Reference = the raw buffer API (dg_geo_to_z7 ...), which check_cli.py verifies against the
CLI. With a check_cli workdir also polygons directly vs the CLI's cells.geojson.

needs: pip install pyarrow geoarrow-pyarrow shapely geopandas pyproj numpy
"""
import ctypes as C
import json
import os
import resource
import sys
import time

import geoarrow.pyarrow as ga
import geopandas as gpd
import numpy as np
import pyarrow as pa
import pyproj
import shapely

lib = C.CDLL(sys.argv[1])
work = sys.argv[2] if len(sys.argv) > 2 else None
vp, dbl, u64, u8 = C.c_void_p, C.POINTER(C.c_double), C.POINTER(C.c_uint64), C.POINTER(C.c_uint8)
lib.dg_preset_new.argtypes, lib.dg_preset_new.restype = [C.c_int], vp
lib.dg_ctx_free.argtypes = [vp]
lib.dg_ctx_set_lon_wrap.argtypes = [vp, C.c_int]
lib.dg_last_error.argtypes, lib.dg_last_error.restype = [vp], C.c_char_p
lib.dg_geo_to_z7.argtypes = [vp, C.c_int, dbl, dbl, C.c_size_t, u64]
lib.dg_z7_to_centroid.argtypes = [vp, u64, C.c_size_t, dbl, dbl]
lib.dg_z7_to_boundary.argtypes = [vp, u64, C.c_size_t, dbl, u8]
lib.dg_arrow_geo_to_z7.argtypes = [vp, C.c_int, vp, vp, vp, vp]
lib.dg_arrow_lonlat_to_z7.argtypes = [vp, C.c_int, vp, vp, vp, vp, vp, vp]
lib.dg_arrow_z7_to_points.argtypes = [vp, vp, vp, C.c_int, vp, vp]
lib.dg_arrow_z7_to_polygons.argtypes = [vp, vp, vp, C.c_int, vp, vp]
lib.dg_arrow_release_schema.argtypes = [vp]
lib.dg_arrow_release_array.argtypes = [vp]
for f in (lib.dg_z7_neighbors, lib.dg_z7_children):
    f.argtypes = [vp, u64, C.c_size_t, u64]
lib.dg_z7_parent.argtypes = [vp, u64, C.c_size_t, C.c_int, u64]
lib.dg_z7_to_string.argtypes = [C.c_uint64, C.c_char_p, C.c_size_t]
lib.dg_z7_from_string.argtypes = [C.c_char_p, C.c_size_t, u64]
for f in (lib.dg_arrow_z7_neighbors, lib.dg_arrow_z7_children, lib.dg_arrow_z7_to_string, lib.dg_arrow_z7_from_string):
    f.argtypes = [vp, vp, vp, vp, vp]
lib.dg_arrow_z7_parent.argtypes = [vp, vp, vp, C.c_int, vp, vp]

NATIVE, INTERLEAVED, WKB, WKT = 0, 1, 2, 3
PRESETS = {"IGEO7v2": 0, "IGEO7v1": 1, "IVEA7HL": 2, "IVEA7HS": 3}
WGS84 = {"IGEO7v2", "IVEA7HL"}
fails = 0


def check(cond, what):
    global fails
    if not cond:
        fails += 1
        print("FAIL", what)


class Exported:
    """a pyarrow array exported to C structs, borrowed by the call, released here"""
    def __init__(self, arr):
        self.s, self.a = C.create_string_buffer(72), C.create_string_buffer(80)
        self.ps, self.pa = C.addressof(self.s), C.addressof(self.a)
        arr._export_to_c(self.pa, self.ps)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        lib.dg_arrow_release_array(self.pa)
        lib.dg_arrow_release_schema(self.ps)


def released(buf, offset):
    """release pointer of an ArrowSchema (offset 56) / ArrowArray (offset 64), 64 bit"""
    return C.c_void_p.from_buffer(buf, offset).value is None


def call(ctx, fn, *args, expect_ok=True):
    """fn(*args, out_schema, out_array) -> pyarrow array, or None on an expected error"""
    s, a = C.create_string_buffer(72), C.create_string_buffer(80)
    rc = fn(*args, C.addressof(s), C.addressof(a))
    if rc != 0:
        msg = lib.dg_last_error(ctx).decode()
        check(released(s, 56) and released(a, 64), f"outputs not cleared on error: {msg}")
        check(not expect_ok, f"{fn.__name__}: {msg}")
        return None if not expect_ok else pa.nulls(0)
    check(expect_ok, f"{fn.__name__}: expected an error")
    return pa.Array._import_from_c(C.addressof(a), C.addressof(s))


def raw_ids(ctx, res, lon, lat):
    lon, lat = np.ascontiguousarray(lon, dtype=float), np.ascontiguousarray(lat, dtype=float)
    n, out = len(lon), (C.c_uint64 * len(lon))()
    assert lib.dg_geo_to_z7(ctx, res, lon.ctypes.data_as(dbl), lat.ctypes.data_as(dbl), n, out) == 0
    return np.frombuffer(out, dtype=np.uint64).copy()


def raw_centroids(ctx, ids):
    ids = np.asarray(ids, dtype=np.uint64)
    n = len(ids)
    a, b = (C.c_double * n)(), (C.c_double * n)()
    assert lib.dg_z7_to_centroid(ctx, ids.ctypes.data_as(u64), n, a, b) == 0
    return np.frombuffer(a).copy(), np.frombuffer(b).copy()


def raw_rings(ctx, ids):
    ids = np.asarray(ids, dtype=np.uint64)
    n = len(ids)
    ll, nv = (C.c_double * (12 * n))(), (C.c_uint8 * n)()
    assert lib.dg_z7_to_boundary(ctx, ids.ctypes.data_as(u64), n, ll, nv) == 0
    ll = np.frombuffer(ll).reshape(n, 6, 2)
    return [ll[i, :nv[i]].copy() for i in range(n)]


def geo_to_z7(ctx, res, arr, expect_ok=True):
    with Exported(arr) as e:
        return call(ctx, lib.dg_arrow_geo_to_z7, ctx, res, e.ps, e.pa, expect_ok=expect_ok)


def lonlat_to_z7(ctx, res, lon, lat, expect_ok=True):
    with Exported(lon) as a, Exported(lat) as b:
        return call(ctx, lib.dg_arrow_lonlat_to_z7, ctx, res, a.ps, a.pa, b.ps, b.pa, expect_ok=expect_ok)


def z7_to_points(ctx, ids, enc=NATIVE, expect_ok=True):
    with Exported(ids) as e:
        return call(ctx, lib.dg_arrow_z7_to_points, ctx, e.ps, e.pa, enc, expect_ok=expect_ok)


def z7_to_polygons(ctx, ids, enc=NATIVE, expect_ok=True):
    with Exported(ids) as e:
        return call(ctx, lib.dg_arrow_z7_to_polygons, ctx, e.ps, e.pa, enc, expect_ok=expect_ok)


def with_crs(arr, crs):
    return arr.type.with_crs(crs).wrap_array(arr.storage)


def all_ids(res):
    """every cell at res, from the Z7 digit rule: a pentagon (base cell + zeros) skips one digit"""
    out = []
    for q in range(12):
        skip = 2 if q <= 5 else 5
        level = [(q << 60, True)]
        for r in range(1, res + 1):
            shift = (20 - r) * 3
            level = [(z | (d << shift), pent and d == 0) for z, pent in level for d in range(7)
                     if not (pent and d == skip)]
        padding = sum(7 << ((20 - r) * 3) for r in range(res + 1, 21))
        out += [z | padding for z, _ in level]
    return np.array(out, dtype=np.uint64)


def to_shapely(arr):
    return shapely.from_wkb(ga.as_wkb(arr).storage.to_numpy(zero_copy_only=False))


def ids_equal(arrow_ids, ref, what):
    check(isinstance(arrow_ids, pa.UInt64Array), f"{what}: not a uint64 array, {arrow_ids.type}")
    got = arrow_ids.to_pylist()
    want = [None if r is None else int(r) for r in ref]
    nd = sum(a != b for a, b in zip(got, want))
    check(len(got) == len(want) and nd == 0, f"{what}: {nd} of {len(want)} ids differ")


rng = np.random.default_rng(11)
N = 20000
lon = np.concatenate([rng.uniform(-180, 180, N), [0.0, 180.0, -180.0, 11.2, 26.729]])
lat = np.concatenate([np.degrees(np.arcsin(rng.uniform(-1, 1, N))), [90.0, -90.0, 0.0, 58.28, 58.378]])
N = len(lon)
RES = 9

for name, preset in PRESETS.items():
    ctx = lib.dg_preset_new(preset)
    assert ctx
    wgs84 = name in WGS84
    ref = raw_ids(ctx, RES, lon, lat)
    idarr = pa.array(ref, type=pa.uint64())

    # ---- plain lon + lat arrays ----
    plon, plat = pa.array(lon), pa.array(lat)
    ids_equal(lonlat_to_z7(ctx, RES, plon, plat), ref, f"{name} lonlat float64")
    ids_equal(lonlat_to_z7(ctx, RES, plon.slice(7, 1000), plat.slice(7, 1000)), ref[7:1007], f"{name} lonlat sliced")
    f32lon, f32lat = lon[:1000].astype(np.float32), lat[:1000].astype(np.float32)
    ids_equal(lonlat_to_z7(ctx, RES, pa.array(f32lon), pa.array(f32lat)),
              raw_ids(ctx, RES, f32lon.astype(float), f32lat.astype(float)), f"{name} lonlat float32")
    # null in lon only, in lat only, NaN + NaN
    nlon, nlat = [1.0, None, 3.0, float("nan"), 5.0], [1.0, 2.0, None, float("nan"), 5.0]
    r = lonlat_to_z7(ctx, RES, pa.array(nlon, type=pa.float64()), pa.array(nlat, type=pa.float64()))
    a15 = raw_ids(ctx, RES, np.array([1.0, 5.0]), np.array([1.0, 5.0]))
    ids_equal(r, [a15[0], None, None, None, a15[1]], f"{name} lonlat nulls")
    check(r.null_count == 3, f"{name} lonlat null_count {r.null_count}")

    # ---- geoarrow points in, every encoding ----
    struct_pts = ga.point().from_geobuffers(None, lon, lat)
    inter_buf = np.column_stack([lon, lat]).ravel()
    inter_pts = ga.point().with_coord_type(ga.CoordType.INTERLEAVED).from_geobuffers(None, inter_buf)
    for what, arr in [("struct", struct_pts), ("interleaved", inter_pts), ("wkb", ga.as_wkb(struct_pts))]:
        ids_equal(geo_to_z7(ctx, RES, arr), ref, f"{name} geoarrow {what}")
        ids_equal(geo_to_z7(ctx, RES, arr.slice(3, 500)), ref[3:503], f"{name} geoarrow {what} sliced")
    # WKT text doesn't round trip every double -> reference = the coordinates it parses to
    for what, arr in [("wkt", ga.as_wkt(struct_pts)), ("wkt sliced", ga.as_wkt(struct_pts).slice(3, 500))]:
        back = np.array([p.coords[0] for p in to_shapely(arr)])
        ids_equal(geo_to_z7(ctx, RES, arr), raw_ids(ctx, RES, back[:, 0], back[:, 1]), f"{name} geoarrow {what}")
    # nulls, POINT EMPTY, z dropped
    mixed = ga.array(["POINT (1 1)", None, "POINT EMPTY", "POINT Z (5 5 9)"])
    ids_equal(geo_to_z7(ctx, RES, mixed), [a15[0], None, None, a15[1]], f"{name} wkt nulls + empty + z")
    ids_equal(geo_to_z7(ctx, RES, ga.as_geoarrow(ga.array(["POINT (1 1)", None, "POINT (5 5)"]), ga.point())),
              [a15[0], None, a15[1]], f"{name} native point nulls")
    # producer without geoarrow-c: geopandas -> GeoArrow
    gs = gpd.GeoSeries(shapely.points(lon[:2000], lat[:2000]), crs="OGC:CRS84" if wgs84 else None)
    for enc in ("geoarrow", "WKB"):
        arr = pa.array(gs.to_arrow(geometry_encoding=enc))
        ids_equal(geo_to_z7(ctx, RES, arr), ref[:2000], f"{name} from geopandas {enc}")

    # ---- CRS ----
    if wgs84:
        ids_equal(geo_to_z7(ctx, RES, with_crs(struct_pts, ga.OGC_CRS84)), ref, f"{name} crs CRS84")
        ids_equal(geo_to_z7(ctx, RES, with_crs(struct_pts, pyproj.CRS("EPSG:4326").to_json())), ref, f"{name} crs 4326 projjson")
        ids_equal(geo_to_z7(ctx, RES, with_crs(struct_pts, "EPSG:4326")), ref, f"{name} crs 4326 code")
    else:
        geo_to_z7(ctx, RES, with_crs(struct_pts, ga.OGC_CRS84), expect_ok=False)
    for crs in (pyproj.CRS("EPSG:3857").to_json(), pyproj.CRS("EPSG:4258").to_json(), "EPSG:3857"):
        geo_to_z7(ctx, RES, with_crs(struct_pts, crs), expect_ok=False)

    # ---- points out ----
    clon, clat = raw_centroids(ctx, ref)
    pts = z7_to_points(ctx, idarr)
    pts.validate(full=True)
    sa = pts.storage
    check(np.array_equal(sa.field(0).to_numpy(), clon) and np.array_equal(sa.field(1).to_numpy(), clat), f"{name} points struct != raw")
    check((pts.type.crs is not None) == wgs84, f"{name} points crs {pts.type.crs}")
    ipts = z7_to_points(ctx, idarr, INTERLEAVED)
    ipts.validate(full=True)
    iv = np.array(ipts.storage.values)
    check(np.array_equal(iv[0::2], clon) and np.array_equal(iv[1::2], clat), f"{name} points interleaved != raw")
    wkb = to_shapely(z7_to_points(ctx, idarr, WKB))
    check(np.array_equal(shapely.get_x(wkb), clon) and np.array_equal(shapely.get_y(wkb), clat), f"{name} points wkb != raw")
    wkt = to_shapely(z7_to_points(ctx, idarr, WKT))
    check(max(np.abs(shapely.get_x(wkt) - clon).max(), np.abs(shapely.get_y(wkt) - clat).max()) < 1e-11, f"{name} points wkt != raw")
    ids_equal(geo_to_z7(ctx, RES, pts), [int(x) for x in raw_ids(ctx, RES, clon, clat)], f"{name} points -> ids, own output")
    gp = gpd.GeoSeries.from_arrow(pts)
    check(np.array_equal(gp.x.to_numpy(), clon), f"{name} geopandas points")
    check((gp.crs == pyproj.CRS("OGC:CRS84")) if wgs84 else gp.crs is None, f"{name} geopandas crs {gp.crs}")

    # ---- polygons out, ids at mixed resolutions, nulls, slice ----
    ids2 = np.concatenate([ref[:3000], raw_ids(ctx, 3, lon[:3000], lat[:3000])])
    ids_nn = pa.array(ids2, type=pa.uint64())
    rings = raw_rings(ctx, ids2)
    polys = z7_to_polygons(ctx, ids_nn)
    polys.validate(full=True)
    bad = 0
    for ring, got in zip(rings, polys.storage.to_pylist()):
        got = got[0]
        c = [(p["x"], p["y"]) for p in got]
        closed = c[0] == c[-1] and len(c) == len(ring) + 1
        same = closed and all(a == float(x) and b == float(y) for (a, b), (x, y) in zip(c, ring))
        bad += not same
    check(bad == 0, f"{name} polygons: {bad} rings != raw")
    ip = z7_to_polygons(ctx, ids_nn, INTERLEAVED)
    ip.validate(full=True)
    shp = {e: to_shapely(a) for e, a in (("native", polys), ("interleaved", ip),
                                         ("wkb", z7_to_polygons(ctx, ids_nn, WKB)),
                                         ("wkt", z7_to_polygons(ctx, ids_nn, WKT)))}
    check(shapely.equals_exact(shp["native"], shp["interleaved"], 0).all(), f"{name} polygon native != interleaved")
    check(shapely.equals_exact(shp["native"], shp["wkb"], 0).all(), f"{name} polygon native != wkb")
    check(shapely.equals_exact(shp["native"], shp["wkt"], 1e-11).all(), f"{name} polygon native != wkt")
    gpoly = gpd.GeoSeries.from_arrow(polys)
    check(shapely.equals_exact(gpoly.values, shp["native"], 0).all(), f"{name} geopandas polygons")
    nullable = pa.array([int(ids2[0]), None, int(ids2[1])], type=pa.uint64())
    pn = z7_to_polygons(ctx, nullable)
    check(pn.null_count == 1 and pn[1].as_py() is None, f"{name} polygon nulls")
    check(z7_to_points(ctx, nullable).null_count == 1, f"{name} point nulls")
    sl = z7_to_polygons(ctx, ids_nn.slice(2000, 2000))
    check(shapely.equals_exact(to_shapely(sl), shp["native"][2000:4000], 0).all(), f"{name} polygons from sliced ids")
    # int64 with base cells 8-11 = negative
    neg = pa.array(ids2.astype(np.int64))
    check(shapely.equals_exact(to_shapely(z7_to_polygons(ctx, neg)), shp["native"], 0).all(), f"{name} polygons from int64 ids")
    # empty arrays
    check(len(lonlat_to_z7(ctx, RES, pa.array([], type=pa.float64()), pa.array([], type=pa.float64()))) == 0, f"{name} empty lonlat")
    check(len(z7_to_polygons(ctx, pa.array([], type=pa.uint64()))) == 0, f"{name} empty polygons")
    check(len(geo_to_z7(ctx, RES, struct_pts.slice(0, 0))) == 0, f"{name} empty points")

    # geometry: whole earth by resolution, unwrapped east (default) vs west vs CLI default WRAP.
    # planar lon/lat: invalid or shifted only at the poles, areas add up to the 360 x 180 box
    stats = []
    for res in range(0, 6):
        cells = pa.array(all_ids(res), type=pa.uint64())
        check(len(cells) == 10 * 7 ** res + 2, f"{name} res {res}: {len(cells)} ids")
        row = [res]
        for mode in (2, 0, 1):  # east last = stays set
            assert lib.dg_ctx_set_lon_wrap(ctx, mode) == 0
            g = to_shapely(z7_to_polygons(ctx, cells))
            xy = [shapely.get_coordinates(p) for p in g]
            spn = np.array([np.ptp(c[:, 0]) for c in xy])
            near = np.array([np.abs(c[:, 1]).max() for c in xy])
            ok = shapely.is_valid(g)
            row.append((int((~ok).sum()), int((spn > 120).sum()), float(shapely.area(g).sum())))
            if mode != 0:
                # every bad cell reaches a pole, nothing else stays wrong
                bad = ~ok | (spn > 120)
                cap = 90 - 1.5 * 0.62 * np.sqrt(510.0656e6 / (10 * 7 ** res + 2)) / 111.2
                check(res < 2 or (near[bad] > cap).all(), f"{name} res {res} mode {mode}: bad cells away from the poles")
        stats.append(row)
    print(f"{name} whole earth: res, (invalid, span > 120, planar area) WEST | WRAP | EAST")
    for row in stats:
        print(f"  res {row[0]}: {row[1][0]:3d} {row[1][1]:3d} {row[1][2]:9.1f} | {row[2][0]:4d} {row[2][1]:5d} {row[2][2]:9.1f} | {row[3][0]:3d} {row[3][1]:3d} {row[3][2]:9.1f}")
    assert lib.dg_ctx_set_lon_wrap(ctx, 9) != 0
    # centroids stay normal points, vertices of an unwrapped cell go back in
    c = np.array(z7_to_points(ctx, pa.array(all_ids(3), type=pa.uint64())).storage.field(0))
    check(np.abs(c).max() <= 180, f"{name} centroid lon out of range")
    ids_equal(lonlat_to_z7(ctx, RES, pa.array(np.where(lon < 0, lon + 360, lon)), plat), ref, f"{name} lon 0-360 input")

    # ---- errors, context stays usable ----
    geo_to_z7(ctx, RES, ga.array(["LINESTRING (0 0, 1 1)"]), expect_ok=False)
    geo_to_z7(ctx, RES, ga.array(["MULTIPOINT ((0 0), (1 1))"]), expect_ok=False)
    geo_to_z7(ctx, RES, ga.as_geoarrow(ga.array(["POLYGON ((0 0, 1 0, 1 1, 0 0))"])), expect_ok=False)
    geo_to_z7(ctx, RES, ga.array(["POINT (0 91)"]), expect_ok=False)
    geo_to_z7(ctx, RES, ga.array(["POINT (0 nonsense"]), expect_ok=False)
    geo_to_z7(ctx, 21, ga.array(["POINT (0 0)"]), expect_ok=False)
    geo_to_z7(ctx, RES, pa.array([1.0, 2.0]), expect_ok=False)  # no extension type
    lonlat_to_z7(ctx, RES, pa.array([1.0]), pa.array([1.0, 2.0]), expect_ok=False)
    lonlat_to_z7(ctx, RES, pa.array([1]), pa.array([1]), expect_ok=False)
    lonlat_to_z7(ctx, RES, pa.array([float("nan")]), pa.array([1.0]), expect_ok=False)
    z7_to_polygons(ctx, pa.array([2 ** 64 - 1], type=pa.uint64()), expect_ok=False)
    z7_to_points(ctx, pa.array([1.5]), expect_ok=False)
    z7_to_points(ctx, idarr, 99, expect_ok=False)
    ids_equal(lonlat_to_z7(ctx, RES, plon, plat), ref, f"{name} after errors")

    # ---- CLI directly ----
    if work:
        with open(os.path.join(work, name, "cells.geojson")) as f:
            feats = json.load(f)["features"]
        cli_ids = pa.array([int(ft["properties"]["name"], 16) for ft in feats], type=pa.uint64())
        rows = z7_to_polygons(ctx, cli_ids).storage.to_pylist()
        bmax = 0.0
        for row, ft in zip(rows, feats):
            for p, (x, y) in zip(row[0], ft["geometry"]["coordinates"][0]):
                d = abs((p["x"] - x + 180) % 360 - 180) if abs(p["y"]) < 89.999 else 0.0
                bmax = max(bmax, d, abs(p["y"] - y))
            check(len(row[0]) == len(ft["geometry"]["coordinates"][0]), f"{name} CLI ring length")
        check(bmax < 1e-9, f"{name} polygons vs CLI {bmax}")
        print(f"{name}: {len(rows)} polygons vs CLI cells.geojson, max diff {bmax:.1e} deg")

    lib.dg_ctx_free(ctx)

# ---- z7 topology + strings (preset independent; ctx only for messages, NULL allowed) ----
NONE = 2**64 - 1
ctx = lib.dg_preset_new(0)


def raw_slots(fn, ids, k, c=None):
    ids = np.ascontiguousarray(ids, dtype=np.uint64)
    out = np.empty(len(ids) * k, dtype=np.uint64)
    assert fn(c, ids.ctypes.data_as(u64), len(ids), out.ctypes.data_as(u64)) == 0
    return out.reshape(-1, k)


topo_ids = np.concatenate([all_ids(r) for r in range(5)] + [raw_ids(ctx, r, lon[:2000], lat[:2000]) for r in (9, 15, 19)])
tarr = pa.array(topo_ids, type=pa.uint64())
nb_raw = raw_slots(lib.dg_z7_neighbors, topo_ids, 6)
with Exported(tarr) as e:
    nb = call(ctx, lib.dg_arrow_z7_neighbors, ctx, e.ps, e.pa)
nb.validate(full=True)
check(pa.types.is_fixed_size_list(nb.type) and nb.type.list_size == 6 and nb.type.value_type == pa.uint64(), f"neighbors type {nb.type}")
want = [[None if x == NONE else int(x) for x in row] for row in nb_raw]
check(nb.to_pylist() == want, "arrow neighbors != raw (pentagon gap = null element)")
check(sum(row.count(None) for row in want) == 12 * 5, "pentagon gaps: 12 per whole earth resolution 0-4")
with Exported(tarr) as e:
    ch = call(ctx, lib.dg_arrow_z7_children, ctx, e.ps, e.pa)
ch.validate(full=True)
ch_raw = raw_slots(lib.dg_z7_children, topo_ids, 7)
check(ch.to_pylist() == [[int(x) for x in row if x != NONE] for row in ch_raw], "arrow children != raw")
check(sorted(set(map(len, ch.to_pylist()))) == [6, 7], "children per cell 6 / 7")
for res_arg in (-1, 0):
    with Exported(tarr.slice(12)) as e:  # no base cells, they have no parent at -1
        par = call(ctx, lib.dg_arrow_z7_parent, ctx, e.ps, e.pa, res_arg)
    out = np.empty(len(topo_ids) - 12, dtype=np.uint64)
    assert lib.dg_z7_parent(ctx, topo_ids[12:].ctypes.data_as(u64), len(out), res_arg, out.ctypes.data_as(u64)) == 0
    ids_equal(par, out, f"arrow parent res {res_arg}")
# children -> parent = the cell, via Arrow both ways
kids = pa.array([x for row in ch.to_pylist() for x in row], type=pa.uint64())
with Exported(kids) as e:
    up = call(ctx, lib.dg_arrow_z7_parent, ctx, e.ps, e.pa, -1)
ids_equal(up, [int(z) for z, row in zip(topo_ids, ch_raw) for x in row if x != NONE], "parent(children) = cell")
# strings, utf8 + large_utf8, nulls; NULL ctx
with Exported(tarr) as e:
    st = call(None, lib.dg_arrow_z7_to_string, None, e.ps, e.pa)
buf = C.create_string_buffer(32)
check(st.to_pylist() == [buf.value.decode() for z in topo_ids if lib.dg_z7_to_string(int(z), buf, 32) > 0], "arrow z7 -> string != raw")
for t in (pa.string(), pa.large_string()):
    with Exported(st.cast(t)) as e:
        ids_equal(call(ctx, lib.dg_arrow_z7_from_string, ctx, e.ps, e.pa), topo_ids, f"arrow string -> z7 {t}")
nulls = pa.array([int(topo_ids[100]), None], type=pa.uint64())
for fn, extra in ((lib.dg_arrow_z7_neighbors, ()), (lib.dg_arrow_z7_children, ()), (lib.dg_arrow_z7_parent, (0,)), (lib.dg_arrow_z7_to_string, ())):
    with Exported(nulls) as e:
        r = call(ctx, fn, ctx, e.ps, e.pa, *extra)
    check(r.null_count == 1 and r[1].as_py() is None, f"{fn.__name__} null in -> null out")
def from_str(s):
    z = C.c_uint64()
    assert lib.dg_z7_from_string(s.encode(), len(s), C.byref(z)) == 0
    return z.value


with Exported(pa.array(["0401234", None, "05"])) as e:
    ids_equal(call(ctx, lib.dg_arrow_z7_from_string, ctx, e.ps, e.pa), [from_str("0401234"), None, from_str("05")], "from_string nulls")
# errors
for fn, arr, extra in ((lib.dg_arrow_z7_neighbors, pa.array([NONE], type=pa.uint64()), ()),
                       (lib.dg_arrow_z7_children, pa.array([int(raw_ids(ctx, 20, [1.0], [1.0])[0])], type=pa.uint64()), ()),
                       (lib.dg_arrow_z7_parent, pa.array([from_str("05")], type=pa.uint64()), (-1,)),
                       (lib.dg_arrow_z7_parent, pa.array([from_str("0401234")], type=pa.uint64()), (6,)),
                       (lib.dg_arrow_z7_to_string, pa.array([NONE], type=pa.uint64()), ()),
                       (lib.dg_arrow_z7_from_string, pa.array(["002"]), ()),
                       (lib.dg_arrow_z7_from_string, pa.array([1.0]), ())):
    with Exported(arr) as e:
        call(ctx, fn, ctx, e.ps, e.pa, *extra, expect_ok=False)
    with Exported(arr) as e:  # NULL ctx: error code, no crash
        s, a = C.create_string_buffer(72), C.create_string_buffer(80)
        check(fn(None, e.ps, e.pa, *extra, C.addressof(s), C.addressof(a)) != 0, f"{fn.__name__} NULL ctx error")
print(f"topology: {len(topo_ids)} ids res 0-4, 9, 15, 19: arrow neighbors / children / parent / strings = raw API, nulls, errors")
lib.dg_ctx_free(ctx)

# ---- release: repeated round trips must not grow ----
ctx = lib.dg_preset_new(0)
ref = raw_ids(ctx, RES, lon, lat)
idarr = pa.array(ref, type=pa.uint64())
struct_pts = ga.point().from_geobuffers(None, lon, lat)


def round_trips(k):
    for _ in range(k):
        geo_to_z7(ctx, RES, struct_pts)
        z7_to_polygons(ctx, idarr)
        z7_to_points(ctx, idarr, WKB)


def rss():
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return r / 1e6 if sys.platform == "darwin" else r / 1e3  # MB


round_trips(10)
r0 = rss()
round_trips(50)
r1 = rss()
check(r1 - r0 < 20, f"max rss grew {r1 - r0:.0f} MB over 50 round trips")
print(f"max rss {r0:.0f} -> {r1:.0f} MB over 50 round trips of {N} elements")

# ---- throughput, res 9 ----
M = 200000
lon2, lat2 = rng.uniform(-180, 180, M), np.degrees(np.arcsin(rng.uniform(-1, 1, M)))
pts2 = ga.point().from_geobuffers(None, lon2, lat2)
wkb2 = ga.as_wkb(pts2)
ids2 = pa.array(raw_ids(ctx, RES, lon2, lat2), type=pa.uint64())


def topo_call(fn, ids):
    with Exported(ids) as e:
        return call(ctx, fn, ctx, e.ps, e.pa)


for what, fn in [("points struct -> z7", lambda: geo_to_z7(ctx, RES, pts2)),
                 ("points wkb -> z7", lambda: geo_to_z7(ctx, RES, wkb2)),
                 ("lon, lat -> z7", lambda: lonlat_to_z7(ctx, RES, pa.array(lon2), pa.array(lat2))),
                 ("z7 -> points", lambda: z7_to_points(ctx, ids2)),
                 ("z7 -> polygons", lambda: z7_to_polygons(ctx, ids2)),
                 ("z7 -> polygons wkb", lambda: z7_to_polygons(ctx, ids2, WKB)),
                 ("z7 -> neighbors raw", lambda: raw_slots(lib.dg_z7_neighbors, np.asarray(ids2), 6)),
                 ("z7 -> neighbors arrow", lambda: topo_call(lib.dg_arrow_z7_neighbors, ids2)),
                 ("z7 -> children arrow", lambda: topo_call(lib.dg_arrow_z7_children, ids2)),
                 ("z7 -> string arrow", lambda: topo_call(lib.dg_arrow_z7_to_string, ids2))]:
    t = time.time()
    fn()
    print(f"| {what} | {M / (time.time() - t) / 1000:.0f}k/s |")
lib.dg_ctx_free(ctx)

print("OK" if fails == 0 else f"{fails} checks FAILED")
sys.exit(1 if fails else 0)
