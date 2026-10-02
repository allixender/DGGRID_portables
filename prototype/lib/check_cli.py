#!/usr/bin/env python3
"""check_cli.py <libdggrid> <dggrid-cli> <workdir>

Cross-check of the C API, called via ctypes (= how a Python binding would use it),
against the dggrid CLI with dggs_type IGEO7. Build both with the same -Ddgreal:

  - random points -> Z7 int at several resolutions (TRANSFORM_POINTS GEO -> HIERNDX)
  - Z7 -> Z7 string (CLI DIGIT_STRING) and back
  - those cells' centroids + boundaries (GENERATE_GRID ADDRESS_FILES, GeoJSON + TEXT)
  - whole earth grids at res 1 and 3: every cell incl. the 12 pentagons

Exits 1 on any mismatch.
"""
import ctypes as C
import json
import math
import os
import random
import subprocess
import sys

lib_path, cli, work = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
os.makedirs(work, exist_ok=True)

lib = C.CDLL(lib_path)
dbl_p, u64_p, u8_p = C.POINTER(C.c_double), C.POINTER(C.c_uint64), C.POINTER(C.c_uint8)
lib.dg_igeo7_new.restype = C.c_void_p
lib.dg_ctx_free.argtypes = [C.c_void_p]
lib.dg_last_error.argtypes = [C.c_void_p]
lib.dg_last_error.restype = C.c_char_p
lib.dg_geo_to_z7.argtypes = [C.c_void_p, C.c_int, dbl_p, dbl_p, C.c_size_t, u64_p]
lib.dg_z7_to_centroid.argtypes = [C.c_void_p, u64_p, C.c_size_t, dbl_p, dbl_p]
lib.dg_z7_to_boundary.argtypes = [C.c_void_p, u64_p, C.c_size_t, dbl_p, u8_p]
lib.dg_z7_to_string.argtypes = [C.c_uint64, C.c_char_p, C.c_size_t]
lib.dg_z7_from_string.argtypes = [C.c_char_p, C.c_size_t, u64_p]

ctx = lib.dg_igeo7_new()
assert ctx, lib.dg_last_error(None)
fails = 0


def check(cond, what):
    global fails
    if not cond:
        fails += 1
        print("FAIL", what)


def call(rc):
    if rc != 0:
        sys.exit(f"API error {rc}: {lib.dg_last_error(ctx).decode()}")


def run_cli(name, params):
    meta = os.path.join(work, name + ".meta")
    with open(meta, "w") as f:
        f.write("dggs_type IGEO7\nprecision 12\n")
        for k, v in params.items():
            f.write(f"{k} {v}\n")
    r = subprocess.run([cli, name + ".meta"], cwd=work, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"dggrid {name} failed:\n{r.stdout}\n{r.stderr}")


def read_lines(name):
    with open(os.path.join(work, name)) as f:
        return [l.split() for l in f if l.strip()]


def geo_to_z7(res, lons, lats):
    n = len(lons)
    out = (C.c_uint64 * n)()
    call(lib.dg_geo_to_z7(ctx, res, (C.c_double * n)(*lons), (C.c_double * n)(*lats), n, out))
    return list(out)


def centroids(ids):
    n = len(ids)
    lon, lat = (C.c_double * n)(), (C.c_double * n)()
    call(lib.dg_z7_to_centroid(ctx, (C.c_uint64 * n)(*ids), n, lon, lat))
    return list(lon), list(lat)


def boundaries(ids):
    n = len(ids)
    ll, nv = (C.c_double * (n * 12))(), (C.c_uint8 * n)()
    call(lib.dg_z7_to_boundary(ctx, (C.c_uint64 * n)(*ids), n, ll, nv))
    return [[(ll[i * 12 + 2 * v], ll[i * 12 + 2 * v + 1]) for v in range(nv[i])] for i in range(n)]


def lon_diff(a, b):
    return abs((a - b + 180) % 360 - 180)


# GENERATE_GRID output: GeoJSON cells (name = Z7 hex) + TEXT centre points "z7,lon,lat"
gen_common = {"dggrid_operation": "GENERATE_GRID", "cell_output_type": "GEOJSON",
              "cell_output_file_name": "cells", "point_output_type": "TEXT",
              "point_output_file_name": "cpts", "output_cell_label_type": "OUTPUT_ADDRESS_TYPE",
              "output_address_type": "HIERNDX", "output_hier_ndx_system": "Z7",
              "output_hier_ndx_form": "INT64", "densification": 0}


def compare_cells(label, ids, pentagons=None):
    """centroids + boundaries of ids from the API vs the last GENERATE_GRID run"""
    with open(os.path.join(work, "cells.geojson")) as f:
        rings = {int(ft["properties"]["name"], 16): ft["geometry"]["coordinates"][0][:-1]
                 for ft in json.load(f)["features"]}  # GeoJSON repeats the first vertex
    cpts = {}
    with open(os.path.join(work, "cpts.txt")) as f:
        for l in f:
            if "," in l:
                z, a, b = l.strip().split(",")
                cpts[int(z, 16)] = (float(a), float(b))
    check(set(rings) == set(ids) == set(cpts), f"{label}: CLI generated a different cell set")
    clon, clat = centroids(ids)
    cmax = max(max(lon_diff(a, cpts[z][0]) * (abs(b) < 89.999), abs(b - cpts[z][1]))
               for z, a, b in zip(ids, clon, clat))
    bmax, bad, npent = 0.0, 0, 0
    for z, poly in zip(ids, boundaries(ids)):
        ring = rings[z]
        npent += len(poly) == 5
        if len(ring) != len(poly):
            bad += 1
            continue
        for (a, b), (c, d) in zip(poly, ring):
            bmax = max(bmax, lon_diff(a, c) * (abs(b) < 89.999), abs(b - d))
    check(cmax < 1e-9, f"{label}: centroid max diff {cmax:.2e} deg vs CLI")
    check(bad == 0 and bmax < 1e-9, f"{label}: {bad} vertex count mismatches, vertex max diff {bmax:.2e}")
    if pentagons is not None:
        check(npent == pentagons, f"{label}: {npent} pentagons, expected {pentagons}")
    print(f"{label}: {len(ids)} cells ({npent} pentagons), centroid max diff {cmax:.1e}, "
          f"boundary max diff {bmax:.1e} deg")


# ---- random points: ids, strings, centroids ----
rnd = random.Random(7)
lons = [rnd.uniform(-180, 180) for _ in range(3000)]
lats = [math.degrees(math.asin(rnd.uniform(-1, 1))) for _ in range(3000)]  # uniform on the sphere
lons += [0.0, 180.0, -180.0, 11.25, 26.729]
lats += [90.0, -90.0, 0.0, 58.28252559, 58.378]
with open(os.path.join(work, "pts.txt"), "w") as f:
    for lo, la in zip(lons, lats):
        f.write(f"{lo:.12f} {la:.12f}\n")
lons = [float(f"{x:.12f}") for x in lons]  # what the CLI reads
lats = [float(f"{x:.12f}") for x in lats]

for res in (0, 1, 5, 9, 13, 17, 20):
    common = {"dggrid_operation": "TRANSFORM_POINTS", "dggs_res_spec": res,
              "input_delimiter": '" "', "output_delimiter": '" "'}
    run_cli("geo2z7", {**common, "input_file_name": "pts.txt", "input_address_type": "GEO",
                       "output_file_name": "z7.txt", "output_address_type": "HIERNDX",
                       "output_hier_ndx_system": "Z7", "output_hier_ndx_form": "INT64"})
    cli_ids = [int(l[0], 16) for l in read_lines("z7.txt")]
    ids = geo_to_z7(res, lons, lats)
    nd = sum(a != b for a, b in zip(ids, cli_ids))
    check(len(ids) == len(cli_ids) and nd == 0, f"res {res}: {nd} of {len(ids)} Z7 ids differ from CLI")

    run_cli("z72str", {**common, "input_file_name": "z7.txt", "input_address_type": "HIERNDX",
                       "input_hier_ndx_system": "Z7", "input_hier_ndx_form": "INT64",
                       "output_file_name": "z7str.txt", "output_address_type": "HIERNDX",
                       "output_hier_ndx_system": "Z7", "output_hier_ndx_form": "DIGIT_STRING"})
    buf = C.create_string_buffer(32)
    bad = 0
    for z, (s,) in zip(ids, read_lines("z7str.txt")):
        n = lib.dg_z7_to_string(z, buf, 32)
        back = C.c_uint64()
        ok = n == len(s) and buf.value.decode() == s
        ok = ok and lib.dg_z7_from_string(s.encode(), len(s), C.byref(back)) == 0 and back.value == z
        bad += not ok
    check(bad == 0, f"res {res}: {bad} Z7 strings differ from CLI / don't round trip")
    print(f"res {res:2d}: {len(ids)} pts -> Z7 ids + strings identical to CLI")

    run_cli("gen", {**gen_common, "dggs_res_spec": res, "clip_subset_type": "ADDRESS_FILES",
                    "clip_region_files": "z7.txt", "input_address_type": "HIERNDX",
                    "input_hier_ndx_system": "Z7", "input_hier_ndx_form": "INT64"})
    compare_cells(f"res {res:2d}: {len(ids)} pts", sorted(set(ids)))

# ---- whole earth: every cell incl. the 12 pentagons ----
for res in (1, 3):
    run_cli("gen", {**gen_common, "dggs_res_spec": res, "clip_subset_type": "WHOLE_EARTH"})
    with open(os.path.join(work, "cells.geojson")) as f:
        ids = [int(ft["properties"]["name"], 16) for ft in json.load(f)["features"]]
    compare_cells(f"res {res:2d}: whole earth", ids, pentagons=12)

lib.dg_ctx_free(ctx)
print("OK" if fails == 0 else f"{fails} checks FAILED")
sys.exit(1 if fails else 0)
