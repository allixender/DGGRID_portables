#!/usr/bin/env python3
"""check_cli.py <libdggrid> <dggrid-cli> <workdir> [preset ...]

Cross-check of the C API, called via ctypes (= how a Python binding would use it),
against the dggrid CLI, per dggs_type preset (default all: IGEO7v2 IGEO7v1 IVEA7HL
IVEA7HS). The CLI can be any build of the same DGGRID version (9.2), best the unmodified root one (../../zig-out/bin/dggrid):

  - random points -> Z7 int at several resolutions (TRANSFORM_POINTS GEO -> HIERNDX)
  - Z7 -> Z7 string (CLI DIGIT_STRING) and back
  - those cells' centroids + boundaries (GENERATE_GRID ADDRESS_FILES, GeoJSON + TEXT)
  - whole earth grids at res 1 and 3: every cell incl. the 12 pentagons, in all 3
    longitude_wrap_mode settings, boundary longitudes strict (no modulo 360)

Exits 1 on any mismatch. Outputs stay in <workdir>/<preset>/ (for ../wasm/test.mjs).
"""
import ctypes as C
import json
import math
import os
import random
import subprocess
import sys

PRESETS = {"IGEO7v2": 0, "IGEO7v1": 1, "IVEA7HL": 2, "IVEA7HS": 3}

lib_path, cli, root_work = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
presets = sys.argv[4:] or list(PRESETS)

lib = C.CDLL(lib_path)
dbl_p, u64_p, u8_p = C.POINTER(C.c_double), C.POINTER(C.c_uint64), C.POINTER(C.c_uint8)
lib.dg_preset_new.argtypes = [C.c_int]
lib.dg_preset_new.restype = C.c_void_p
lib.dg_ctx_free.argtypes = [C.c_void_p]
lib.dg_ctx_set_lon_wrap.argtypes = [C.c_void_p, C.c_int]
lib.dg_last_error.argtypes = [C.c_void_p]
lib.dg_last_error.restype = C.c_char_p
lib.dg_geo_to_z7.argtypes = [C.c_void_p, C.c_int, dbl_p, dbl_p, C.c_size_t, u64_p]
lib.dg_z7_to_centroid.argtypes = [C.c_void_p, u64_p, C.c_size_t, dbl_p, dbl_p]
lib.dg_z7_to_boundary.argtypes = [C.c_void_p, u64_p, C.c_size_t, dbl_p, u8_p]
lib.dg_z7_to_string.argtypes = [C.c_uint64, C.c_char_p, C.c_size_t]
lib.dg_z7_from_string.argtypes = [C.c_char_p, C.c_size_t, u64_p]
for fn in (lib.dg_z7_neighbors, lib.dg_z7_children):
    fn.argtypes = [C.c_void_p, u64_p, C.c_size_t, u64_p]
lib.dg_z7_parent.argtypes = [C.c_void_p, u64_p, C.c_size_t, C.c_int, u64_p]

lib.dg_last_error.restype = C.c_char_p
fails = 0
ctx = work = preset = None


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
        f.write(f"dggs_type {preset}\nprecision 12\n")
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
              "output_hier_ndx_form": "INT64", "densification": 0,
              "longitude_wrap_mode": "UNWRAP_EAST", "unwrap_points": "FALSE"}


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
    # cells within 1 deg of a pole separately: near the pole a double build differs from a
    # long double CLI by up to ca 2.5e-7 deg at res 20 (sqrt(eps) in the projection, ca 3 cm)
    clon, clat = centroids(ids)
    cmax = pmax = bmax = 0.0
    bad = npent = 0
    for z, a, b in zip(ids, clon, clat):
        d = max(lon_diff(a, cpts[z][0]) * (abs(b) < 89.999), abs(b - cpts[z][1]))
        if abs(b) > 89:
            pmax = max(pmax, d)
        else:
            cmax = max(cmax, d)
    for z, poly in zip(ids, boundaries(ids)):
        ring = rings[z]
        npent += len(poly) == 5
        if len(ring) != len(poly):
            bad += 1
            continue
        for (a, b), (c, d) in zip(poly, ring):
            e = max(abs(a - c) * (abs(b) < 89.999), abs(b - d))  # strict, unwrapped lons count
            if abs(b) > 89:
                pmax = max(pmax, e)
            else:
                bmax = max(bmax, e)
    check(cmax < 1e-9, f"{label}: centroid max diff {cmax:.2e} deg vs CLI")
    check(bad == 0 and bmax < 1e-9, f"{label}: {bad} vertex count mismatches, vertex max diff {bmax:.2e}")
    check(pmax < 1e-6, f"{label}: within 1 deg of a pole max diff {pmax:.2e}")
    if pentagons is not None:
        check(npent == pentagons, f"{label}: {npent} pentagons, expected {pentagons}")
    print(f"{label}: {len(ids)} cells ({npent} pentagons), centroid max diff {cmax:.1e}, "
          f"boundary max diff {bmax:.1e} deg, within 1 deg of a pole {pmax:.1e}")


NONE = 2**64 - 1
# whole earth res 0..TOPO_RES vs the CLI's neighbour + children output. 5 = 168k cells, CLI
# ca 11 s per preset on M2 Pro; 6 = 1.18M cells, ca 80 s (children output = 3/4 of it), the
# index arithmetic is the same per digit -> TOPO_RES=6 only for a full run
TOPO_RES = int(os.environ.get("TOPO_RES", "5"))


def z7_batch(fn, ids, slots):
    n = len(ids)
    out = (C.c_uint64 * (n * slots))()
    call(fn(ctx, (C.c_uint64 * n)(*ids), n, out))
    return [out[i * slots:(i + 1) * slots] for i in range(n)]


def z7_string(z):
    buf = C.create_string_buffer(32)
    return buf.value.decode() if lib.dg_z7_to_string(z, buf, 32) > 0 else hex(z)


def topology(res):
    """GBT neighbours + index children + parent vs the CLI's neighbor / children output,
    whole earth. CLI children = all res + 1 cells overlapping the cell: the 7 (pentagon 6)
    interior ones = the Z7 index children first, then the 6 (5) straddling its edge"""
    params = {**gen_common, "dggs_res_spec": res, "clip_subset_type": "WHOLE_EARTH",
              "cell_output_type": "NONE", "point_output_type": "NONE",
              "neighbor_output_type": "TEXT", "neighbor_output_file_name": "nbr"}
    if res < 20:
        params.update(children_output_type="TEXT", children_output_file_name="chd")
    run_cli("topo", params)
    cli_nbr = {int(l[0], 16): {int(x, 16) for x in l[1:]} for l in read_lines("nbr.nbr")}
    ids = sorted(cli_nbr)
    check(len(ids) == 10 * 7 ** res + 2, f"res {res}: CLI has {len(ids)} cells")
    nbad = npent = 0
    for z, nb in zip(ids, z7_batch(lib.dg_z7_neighbors, ids, 6)):
        mine = [x for x in nb if x != NONE]
        npent += len(mine) == 5
        if len(set(mine)) != len(mine) or set(mine) != cli_nbr[z]:
            nbad += 1
            if nbad <= 3:
                print(f"  neighbours of {z7_string(z)}: GBT {[z7_string(x) for x in nb]}, "
                      f"CLI {sorted(z7_string(x) for x in cli_nbr[z])}")
    check(nbad == 0 and npent == 12, f"res {res}: {nbad} neighbour sets differ from CLI, {npent} pentagons")
    cbad = pbad = 0
    if res < 20:
        cli_chd = {int(l[0], 16): [int(x, 16) for x in l[1:]] for l in read_lines("chd.chd")}
        for z, ch in zip(ids, z7_batch(lib.dg_z7_children, ids, 7)):
            mine = [x for x in ch if x != NONE]
            if set(mine) != set(cli_chd[z][:len(mine)]):
                cbad += 1
                if cbad <= 3:
                    print(f"  children of {z7_string(z)}: {[z7_string(x) for x in mine]}, "
                          f"CLI {[z7_string(x) for x in cli_chd[z]]}")
            up = (C.c_uint64 * len(mine))()
            call(lib.dg_z7_parent(ctx, (C.c_uint64 * len(mine))(*mine), len(mine), -1, up))
            pbad += any(u != z for u in up)
        check(cbad == 0 and pbad == 0, f"res {res}: {cbad} children sets differ from CLI, {pbad} parent mismatches")
    print(f"res {res:2d}: whole earth {len(ids)} cells, GBT neighbours = CLI neighbours"
          f"{', index children = CLI interior children, parent(children) = cell' if res < 20 else ''}"
          f"{'' if nbad == cbad == pbad == 0 else ' -> MISMATCH'}")


def unit(lon, lat):
    lo, la = math.radians(lon), math.radians(lat)
    return (math.cos(la) * math.cos(lo), math.cos(la) * math.sin(lo), math.sin(la))


def geometry(res, lons, lats):
    """GBT neighbours without the CLI: each shares exactly 2 boundary vertices (one edge)
    with the cell, and the relation is symmetric"""
    ids = sorted(set(geo_to_z7(res, lons, lats)))
    nbs = z7_batch(lib.dg_z7_neighbors, ids, 6)
    flat = sorted({x for nb in nbs for x in nb if x != NONE} | set(ids))
    verts = dict(zip(flat, ([unit(*v) for v in ring] for ring in boundaries(flat))))
    back = dict(zip(flat, z7_batch(lib.dg_z7_neighbors, flat, 6)))
    tol = math.radians(1e-9)
    ebad = sbad = 0
    for z, nb in zip(ids, nbs):
        for x in nb:
            if x == NONE:
                continue
            shared = sum(1 for a in verts[z] for b in verts[x] if math.dist(a, b) < tol)
            ebad += shared != 2
            sbad += z not in back[x]
    check(ebad == 0 and sbad == 0, f"res {res}: {ebad} neighbours not sharing one edge, {sbad} not symmetric")
    return len(ids)


def touches_pole(z, res):
    """cell centre closer to a pole than 1.5 * the cell's circumradius (hexagon: 0.62 * sqrt(area))"""
    area_km2 = 510.0656e6 / (10 * 7 ** res + 2)
    return 90 - abs(centroids([z])[1][0]) < 1.5 * 0.62 * math.sqrt(area_km2) / 111.2


# ---- random points: ids, strings, centroids ----
rnd = random.Random(7)
lons = [rnd.uniform(-180, 180) for _ in range(3000)]
lats = [math.degrees(math.asin(rnd.uniform(-1, 1))) for _ in range(3000)]  # uniform on the sphere
lons += [0.0, 180.0, -180.0, 11.25, 26.729]
lats += [90.0, -90.0, 0.0, 58.28252559, 58.378]
pts_txt = "".join(f"{lo:.12f} {la:.12f}\n" for lo, la in zip(lons, lats))
lons = [float(f"{x:.12f}") for x in lons]  # what the CLI reads
lats = [float(f"{x:.12f}") for x in lats]

for preset in presets:
    print(f"---- {preset}")
    work = os.path.join(root_work, preset)
    os.makedirs(work, exist_ok=True)
    with open(os.path.join(work, "pts.txt"), "w") as f:
        f.write(pts_txt)
    ctx = lib.dg_preset_new(PRESETS[preset])
    assert ctx, lib.dg_last_error(None)

    for res in (0, 1, 5, 9, 13, 17, 20):
        common = {"dggrid_operation": "TRANSFORM_POINTS", "dggs_res_spec": res,
                  "input_delimiter": '" "', "output_delimiter": '" "'}
        run_cli("geo2z7", {**common, "input_file_name": "pts.txt", "input_address_type": "GEO",
                           "output_file_name": "z7.txt", "output_address_type": "HIERNDX",
                           "output_hier_ndx_system": "Z7", "output_hier_ndx_form": "INT64"})
        cli_ids = [int(l[0], 16) for l in read_lines("z7.txt")]
        ids = geo_to_z7(res, lons, lats)
        # an input exactly on a pole lies on a cell edge, a CLI with another float type can
        # round to the neighbour (other base cell, also other digits at the north pole).
        # allowed only if both cells reach the pole, then go on with the CLI's id
        ties = [i for i, (a, b) in enumerate(zip(ids, cli_ids))
                if a != b and abs(lats[i]) == 90 and touches_pole(a, res) and touches_pole(b, res)]
        for i in ties:
            ids[i] = cli_ids[i]
        nd = sum(a != b for a, b in zip(ids, cli_ids))
        check(len(ids) == len(cli_ids) and nd == 0, f"res {res}: {nd} of {len(ids)} Z7 ids differ from CLI")
        if ties:
            print(f"res {res:2d}: {len(ties)} exact pole ties")

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

    # ---- whole earth: every cell incl. the 12 pentagons, all wrap modes. EAST last, the
    # default, ../wasm/test.mjs + check_arrow.py read that run
    for mode, wrap in ((0, "WRAP"), (2, "UNWRAP_WEST"), (1, "UNWRAP_EAST")):
        assert lib.dg_ctx_set_lon_wrap(ctx, mode) == 0
        for res in (1, 3):
            run_cli("gen", {**gen_common, "dggs_res_spec": res, "clip_subset_type": "WHOLE_EARTH",
                            "longitude_wrap_mode": wrap})
            with open(os.path.join(work, "cells.geojson")) as f:
                ids = [int(ft["properties"]["name"], 16) for ft in json.load(f)["features"]]
            compare_cells(f"res {res:2d}: whole earth {wrap}", ids, pentagons=12)

    # ---- topology: neighbours, children, parent vs the CLI
    for res in range(TOPO_RES + 1):
        topology(res)
    # beyond the whole earth runs: random cells + their neighbours, plus pentagon centres
    pent_lon, pent_lat = map(list, zip(*(centroids([q << 60 | (2**60 - 1)]) for q in range(12))))
    glon, glat = lons[:1000] + [x[0] for x in pent_lon], lats[:1000] + [x[0] for x in pent_lat]
    for res in range(TOPO_RES + 1, 21):
        n = geometry(res, glon, glat)
    print(f"res {TOPO_RES + 1}-20: {n} cells each incl. the 12 pentagons, every GBT neighbour shares one edge, symmetric")

    lib.dg_ctx_free(ctx)

print("OK" if fails == 0 else f"{fails} checks FAILED")
sys.exit(1 if fails else 0)
