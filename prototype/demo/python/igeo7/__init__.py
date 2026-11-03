"""igeo7: stub Python binding of the prototype DGGRID library (../../lib/include/dggrid.h).

ctypes only, no compiler. numpy for the plain API, pyarrow (+ geoarrow-pyarrow for the
extension types) for the Arrow API. The shared library is looked up in _lib/ next to this
file (copied there by ../../copy_libs.sh) or taken from $DGGRID_LIB.

    from igeo7 import Grid
    with Grid("IGEO7v2") as g:
        ids = g.lonlat_to_z7(9, [26.729], [58.378])     # np.uint64
        g.z7_to_string(ids[0])                           # '0400...'
        lon, lat = g.z7_to_centroid(ids)
        rings = g.z7_to_boundary(ids)                    # [array (6, 2)]
        polys = g.z7_to_polygons_arrow(ids)              # geoarrow.polygon
"""
import ctypes as C
import os
import sys

import numpy as np

__all__ = ["Grid", "PRESETS", "WRAP", "ENCODING", "NONE", "DggridError"]

PRESETS = {"IGEO7v2": 0, "IGEO7v1": 1, "IVEA7HL": 2, "IVEA7HS": 3}
WRAP = {"none": 0, "east": 1, "west": 2}
ENCODING = {"native": 0, "interleaved": 1, "wkb": 2, "wkt": 3}
MAX_RES = 20
NONE = np.uint64(2**64 - 1)  # a pentagon's missing neighbour / child in the raw outputs


class DggridError(RuntimeError):
    pass


def _load():
    path = os.environ.get("DGGRID_LIB")
    if not path:
        name = {"darwin": "libdggrid.dylib", "win32": "dggrid.dll"}.get(sys.platform, "libdggrid.so")
        path = os.path.join(os.path.dirname(__file__), "_lib", name)
    if not os.path.exists(path):
        raise ImportError(f"{path} not found, run copy_libs.sh or set DGGRID_LIB")
    lib = C.CDLL(path)
    vp, dbl, u64, u8 = C.c_void_p, C.POINTER(C.c_double), C.POINTER(C.c_uint64), C.POINTER(C.c_uint8)
    sigs = {
        "dg_preset_new": ([C.c_int], vp),
        "dg_ctx_new": ([C.c_int, C.c_int, C.c_double, C.c_double, C.c_double], vp),
        "dg_ctx_free": ([vp], None),
        "dg_ctx_set_lon_wrap": ([vp, C.c_int], C.c_int),
        "dg_last_error": ([vp], C.c_char_p),
        "dg_geo_to_z7": ([vp, C.c_int, dbl, dbl, C.c_size_t, u64], C.c_int),
        "dg_z7_to_centroid": ([vp, u64, C.c_size_t, dbl, dbl], C.c_int),
        "dg_z7_to_boundary": ([vp, u64, C.c_size_t, dbl, u8], C.c_int),
        "dg_z7_res": ([C.c_uint64], C.c_int),
        "dg_z7_to_string": ([C.c_uint64, C.c_char_p, C.c_size_t], C.c_int),
        "dg_z7_from_string": ([C.c_char_p, C.c_size_t, u64], C.c_int),
        "dg_arrow_geo_to_z7": ([vp, C.c_int, vp, vp, vp, vp], C.c_int),
        "dg_arrow_lonlat_to_z7": ([vp, C.c_int, vp, vp, vp, vp, vp, vp], C.c_int),
        "dg_arrow_z7_to_points": ([vp, vp, vp, C.c_int, vp, vp], C.c_int),
        "dg_arrow_z7_to_polygons": ([vp, vp, vp, C.c_int, vp, vp], C.c_int),
        "dg_arrow_release_schema": ([vp], None),
        "dg_arrow_release_array": ([vp], None),
        "dg_z7_parent": ([vp, u64, C.c_size_t, C.c_int, u64], C.c_int),
        "dg_z7_children": ([vp, u64, C.c_size_t, u64], C.c_int),
        "dg_z7_neighbors": ([vp, u64, C.c_size_t, u64], C.c_int),
        "dg_arrow_z7_parent": ([vp, vp, vp, C.c_int, vp, vp], C.c_int),
        "dg_arrow_z7_children": ([vp, vp, vp, vp, vp], C.c_int),
        "dg_arrow_z7_neighbors": ([vp, vp, vp, vp, vp], C.c_int),
        "dg_arrow_z7_to_string": ([vp, vp, vp, vp, vp], C.c_int),
        "dg_arrow_z7_from_string": ([vp, vp, vp, vp, vp], C.c_int),
    }
    for fn, (args, res) in sigs.items():
        getattr(lib, fn).argtypes, getattr(lib, fn).restype = args, res
    return lib


_lib = _load()
_dbl, _u64, _u8 = C.POINTER(C.c_double), C.POINTER(C.c_uint64), C.POINTER(C.c_uint8)


def _f64(a):
    return np.ascontiguousarray(a, dtype=np.float64)


def _ids(a):
    return np.ascontiguousarray(a, dtype=np.uint64)


class _CStructs:
    """ArrowSchema (72 bytes) + ArrowArray (80 bytes) on 64-bit hosts"""
    def __init__(self):
        self.s, self.a = C.create_string_buffer(72), C.create_string_buffer(80)
        self.ps, self.pa = C.addressof(self.s), C.addressof(self.a)


class _Borrowed(_CStructs):
    """a pyarrow array exported to C for the duration of one call"""
    def __init__(self, arr):
        super().__init__()
        arr._export_to_c(self.pa, self.ps)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        _lib.dg_arrow_release_array(self.pa)
        _lib.dg_arrow_release_schema(self.ps)


class Grid:
    """one DGGRID context: a preset (IGEO7v2 default) or a custom orientation"""

    def __init__(self, preset="IGEO7v2"):
        self._ctx = _lib.dg_preset_new(PRESETS[preset])
        if not self._ctx:
            raise DggridError(_lib.dg_last_error(None).decode())
        self.preset = preset

    @classmethod
    def custom(cls, proj="ISEA", datum="WGS84", vert0_lon=11.2, vert0_lat=float("nan"), azimuth=0.0):
        """another icosahedron orientation; vert0_lat NaN = exact icosahedron vertex latitude"""
        g = cls.__new__(cls)
        g._ctx = _lib.dg_ctx_new({"ISEA": 0, "IVEA": 1}[proj], {"AUTHALIC": 0, "WGS84": 1}[datum],
                                 vert0_lon, vert0_lat, azimuth)
        if not g._ctx:
            raise DggridError(_lib.dg_last_error(None).decode())
        g.preset = f"{proj}/{datum}/{vert0_lon}"
        return g

    def close(self):
        if getattr(self, "_ctx", None):
            _lib.dg_ctx_free(self._ctx)
            self._ctx = None

    __del__ = close

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def __repr__(self):
        return f"Grid({self.preset!r})"

    def _check(self, rc, fn):
        if rc != 0:
            raise DggridError(f"{fn}: {_lib.dg_last_error(self._ctx).decode()}")

    def set_lon_wrap(self, mode):
        """polygon longitudes across the antimeridian: 'east' (default, lon > 180), 'west', 'none' (CLI WRAP)"""
        self._check(_lib.dg_ctx_set_lon_wrap(self._ctx, WRAP[mode]), "dg_ctx_set_lon_wrap")

    # ---- plain numpy API ----

    def lonlat_to_z7(self, res, lon, lat):
        lon, lat = _f64(lon), _f64(lat)
        out = np.empty(len(lon), dtype=np.uint64)
        self._check(_lib.dg_geo_to_z7(self._ctx, res, lon.ctypes.data_as(_dbl), lat.ctypes.data_as(_dbl),
                                      len(lon), out.ctypes.data_as(_u64)), "dg_geo_to_z7")
        return out

    def z7_to_centroid(self, ids):
        ids = _ids(ids)
        lon, lat = np.empty(len(ids)), np.empty(len(ids))
        self._check(_lib.dg_z7_to_centroid(self._ctx, ids.ctypes.data_as(_u64), len(ids),
                                           lon.ctypes.data_as(_dbl), lat.ctypes.data_as(_dbl)), "dg_z7_to_centroid")
        return lon, lat

    def z7_to_boundary(self, ids):
        """list of (nverts, 2) lon/lat arrays, open rings, 6 vertices (5 for pentagons)"""
        ids = _ids(ids)
        ll, nv = np.empty((len(ids), 6, 2)), np.empty(len(ids), dtype=np.uint8)
        self._check(_lib.dg_z7_to_boundary(self._ctx, ids.ctypes.data_as(_u64), len(ids),
                                           ll.ctypes.data_as(_dbl), nv.ctypes.data_as(_u8)), "dg_z7_to_boundary")
        return [ll[i, :nv[i]] for i in range(len(ids))]

    # ---- Z7 topology (index arithmetic, the same for every preset) ----

    def _slots(self, fn, ids, k, *extra):
        ids = _ids(ids)
        out = np.empty((len(ids), k), dtype=np.uint64)
        self._check(getattr(_lib, fn)(self._ctx, ids.ctypes.data_as(_u64), len(ids), *extra,
                                      out.ctypes.data_as(_u64)), fn)
        return out

    def z7_parent(self, ids, res=-1):
        """ancestors at resolution res, -1 = one level up"""
        return self._slots("dg_z7_parent", ids, 1, res)[:, 0]

    def z7_children(self, ids):
        """(n, 7) uint64 in digit order, a pentagon's skipped digit = NONE"""
        return self._slots("dg_z7_children", ids, 7)

    def z7_neighbors(self, ids):
        """(n, 6) uint64 in GBT direction order, a pentagon's missing neighbour = NONE"""
        return self._slots("dg_z7_neighbors", ids, 6)

    # ---- Z7 helpers, no context ----

    @staticmethod
    def z7_res(z7):
        return _lib.dg_z7_res(int(z7))

    @staticmethod
    def z7_to_string(z7):
        buf = C.create_string_buffer(32)
        n = _lib.dg_z7_to_string(int(z7), buf, 32)
        if n < 0:
            raise DggridError(f"invalid Z7 index {int(z7):#018x}")
        return buf.value[:n].decode()

    @staticmethod
    def z7_from_string(s):
        b, out = s.encode(), C.c_uint64()
        if _lib.dg_z7_from_string(b, len(b), C.byref(out)) != 0:
            raise DggridError(f"invalid Z7 string {s!r}")
        return out.value

    # ---- Arrow C Data Interface (pyarrow) ----

    def _arrow_call(self, fn, *args):
        import pyarrow as pa
        out = _CStructs()
        self._check(getattr(_lib, fn)(self._ctx, *args, out.ps, out.pa), fn)
        return pa.Array._import_from_c(out.pa, out.ps)

    def lonlat_to_z7_arrow(self, res, lon, lat):
        """float64/float32 pyarrow arrays (or anything pa.array takes) -> uint64 'z7', nulls kept"""
        import pyarrow as pa
        with _Borrowed(pa.array(lon, pa.float64())) as a, _Borrowed(pa.array(lat, pa.float64())) as b:
            return self._arrow_call("dg_arrow_lonlat_to_z7", res, a.ps, a.pa, b.ps, b.pa)

    def geo_to_z7_arrow(self, res, points):
        """GeoArrow points (geoarrow.point / wkb / wkt; CRS84/EPSG:4326 or none) -> uint64 'z7'"""
        with _Borrowed(points) as p:
            return self._arrow_call("dg_arrow_geo_to_z7", res, p.ps, p.pa)

    def z7_to_points_arrow(self, ids, encoding="native"):
        import pyarrow as pa
        with _Borrowed(pa.array(_ids(ids)) if not isinstance(ids, pa.Array) else ids) as z:
            return self._arrow_call("dg_arrow_z7_to_points", z.ps, z.pa, ENCODING[encoding])

    def z7_to_polygons_arrow(self, ids, encoding="native"):
        import pyarrow as pa
        with _Borrowed(pa.array(_ids(ids)) if not isinstance(ids, pa.Array) else ids) as z:
            return self._arrow_call("dg_arrow_z7_to_polygons", z.ps, z.pa, ENCODING[encoding])

    def _ids_arrow(self, fn, ids, *extra):
        import pyarrow as pa
        with _Borrowed(pa.array(_ids(ids)) if not isinstance(ids, pa.Array) else ids) as z:
            return self._arrow_call(fn, z.ps, z.pa, *extra)

    def z7_parent_arrow(self, ids, res=-1):
        return self._ids_arrow("dg_arrow_z7_parent", ids, res)

    def z7_children_arrow(self, ids):
        """list<uint64>, 7 per cell, 6 for pentagons"""
        return self._ids_arrow("dg_arrow_z7_children", ids)

    def z7_neighbors_arrow(self, ids):
        """fixed_size_list<uint64>[6], a pentagon's missing neighbour = null element"""
        return self._ids_arrow("dg_arrow_z7_neighbors", ids)

    def z7_to_string_arrow(self, ids):
        return self._ids_arrow("dg_arrow_z7_to_string", ids)

    def z7_from_string_arrow(self, strings):
        import pyarrow as pa
        with _Borrowed(pa.array(strings, pa.string()) if not isinstance(strings, pa.Array) else strings) as s:
            return self._arrow_call("dg_arrow_z7_from_string", s.ps, s.pa)


try:  # registers the geoarrow.* extension types, so Arrow outputs come back typed
    import geoarrow.pyarrow  # noqa: F401
except ImportError:
    pass
