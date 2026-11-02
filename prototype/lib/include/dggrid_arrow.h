/* dggrid_arrow.h: Arrow C Data Interface + GeoArrow on top of dggrid.h.
 *
 * Input arrays are borrowed, nothing is kept after the call. Output (schema + array) is
 * caller allocated, filled here, owned by the caller -> release callbacks, or hand it to
 * pyarrow etc. On error (negative code, dg_last_error(ctx)) the outputs have release NULL.
 *
 * Nulls: null in -> null out, an empty point (POINT EMPTY, or NaN, NaN) counts as null.
 *
 * points in (dg_arrow_geo_to_z7): any GeoArrow encoding, geoarrow.point (struct or
 * interleaved), geoarrow.wkb, geoarrow.wkt. Only points, anything else is an error. CRS:
 * none is taken as the preset's datum. WGS84 presets accept OGC:CRS84 / EPSG:4326, authalic
 * presets accept no CRS, the rest is an error, nothing here reprojects.
 *
 * ids: uint64 "z7", int64 accepted on input (same bits, base cells 8-11 look negative).
 *
 * geometry out: encoding DG_ARROW_*, WGS84 presets tagged OGC:CRS84, authalic ones have no
 * CRS. Polygon rings closed, longitudes per dg_ctx_set_lon_wrap, default UNWRAP_EAST: lon
 * above 180 for cells across the antimeridian. Cells touching a pole are not valid planar
 * polygons. Not tagged with edges, cell edges are neither planar lon/lat lines nor exactly
 * great circles.
 */
#ifndef DGGRID_ARROW_H
#define DGGRID_ARROW_H

#include <stdint.h>

#include "dggrid.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Arrow C Data Interface, https://arrow.apache.org/docs/format/CDataInterface.html */
#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE
struct ArrowSchema {
  const char* format;
  const char* name;
  const char* metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema** children;
  struct ArrowSchema* dictionary;
  void (*release)(struct ArrowSchema*);
  void* private_data;
};
struct ArrowArray {
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void** buffers;
  struct ArrowArray** children;
  struct ArrowArray* dictionary;
  void (*release)(struct ArrowArray*);
  void* private_data;
};
#endif

#define DG_ARROW_NATIVE       0  /* geoarrow.point / polygon, struct<x, y> coords */
#define DG_ARROW_INTERLEAVED  1  /* same, fixed_size_list<xy: double>[2] coords */
#define DG_ARROW_WKB          2  /* geoarrow.wkb */
#define DG_ARROW_WKT          3  /* geoarrow.wkt */

/* GeoArrow points -> z7 */
int dg_arrow_geo_to_z7(dg_ctx* ctx, int res,
                       const struct ArrowSchema* in_schema, const struct ArrowArray* in,
                       struct ArrowSchema* out_schema, struct ArrowArray* out);
/* plain lon + lat arrays, float64 or float32, no CRS check -> z7 */
int dg_arrow_lonlat_to_z7(dg_ctx* ctx, int res,
                          const struct ArrowSchema* lon_schema, const struct ArrowArray* lon,
                          const struct ArrowSchema* lat_schema, const struct ArrowArray* lat,
                          struct ArrowSchema* out_schema, struct ArrowArray* out);
/* z7 -> cell centre points */
int dg_arrow_z7_to_points(dg_ctx* ctx, const struct ArrowSchema* z7_schema,
                          const struct ArrowArray* z7, int encoding,
                          struct ArrowSchema* out_schema, struct ArrowArray* out);
/* z7 -> cell boundary polygons */
int dg_arrow_z7_to_polygons(dg_ctx* ctx, const struct ArrowSchema* z7_schema,
                            const struct ArrowArray* z7, int encoding,
                            struct ArrowSchema* out_schema, struct ArrowArray* out);

/* call the release callback, for callers that can't call a function pointer (wasm/JS) */
void dg_arrow_release_schema(struct ArrowSchema* schema);
void dg_arrow_release_array(struct ArrowArray* array);

#ifdef __cplusplus
}
#endif

#endif
