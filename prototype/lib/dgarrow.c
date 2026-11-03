// dgarrow.c: Arrow C Data Interface + GeoArrow over the public C API (dggrid.h). No DGGRID
// classes here, all validation of coordinates + ids stays in dggrid.zig. Every input and
// output encoding goes through geoarrow-c's reader / writer visitors, coordinates are
// collected into plain buffers for the batch functions.
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "geoarrow/geoarrow.h"
#include "nanoarrow/nanoarrow.h"

#include "dggrid_arrow.h"

// dggrid.zig
void dgz_set_error(dg_ctx* ctx, const char* msg);
int dg_ctx_datum(const dg_ctx* ctx);

static int fail(dg_ctx* ctx, int code, const char* msg) {
  if (ctx) dgz_set_error(ctx, msg);  // the z7 topology functions take ctx NULL
  return code;
}

static void* alloc_n(int64_t n, size_t size) { return malloc((size_t)(n > 0 ? n : 1) * size); }

static void clear_out(struct ArrowSchema* out_schema, struct ArrowArray* out) {
  out_schema->release = NULL;
  out->release = NULL;
}

static void release_out(struct ArrowSchema* out_schema, struct ArrowArray* out) {
  if (out_schema->release) out_schema->release(out_schema);
  if (out->release) out->release(out);
  clear_out(out_schema, out);
}

// ---- points in ----

typedef struct {
  double* lon;
  double* lat;
  uint8_t* valid;
  int64_t i;
  int seen;
} Collect;

static int c_feat_start(struct GeoArrowVisitor* v) {
  Collect* c = (Collect*)v->private_data;
  c->seen = 0;
  c->valid[c->i] = 0;
  return GEOARROW_OK;
}

static int c_geom_start(struct GeoArrowVisitor* v, enum GeoArrowGeometryType type,
                        enum GeoArrowDimensions dims) {
  (void)dims;
  if (type != GEOARROW_GEOMETRY_TYPE_POINT) {
    GeoArrowErrorSet(v->error, "feature %lld is not a point",
                     (long long)((Collect*)v->private_data)->i);
    return EINVAL;
  }
  return GEOARROW_OK;
}

static int c_coords(struct GeoArrowVisitor* v, const struct GeoArrowCoordView* coords) {
  Collect* c = (Collect*)v->private_data;
  if (coords->n_coords == 0) return GEOARROW_OK;
  if (c->seen || coords->n_coords > 1) {
    GeoArrowErrorSet(v->error, "feature %lld has more than one coordinate", (long long)c->i);
    return EINVAL;
  }
  c->seen = 1;
  c->lon[c->i] = coords->values[0][0];
  c->lat[c->i] = coords->values[1][0];
  c->valid[c->i] = !(isnan(c->lon[c->i]) && isnan(c->lat[c->i]));  // NaN, NaN = POINT EMPTY
  return GEOARROW_OK;
}

static int c_feat_end(struct GeoArrowVisitor* v) {
  ((Collect*)v->private_data)->i++;
  return GEOARROW_OK;
}

static int contains(struct GeoArrowStringView s, const char* needle) {
  const size_t m = strlen(needle);
  for (int64_t i = 0; i + (int64_t)m <= s.size_bytes; i++) {
    if (memcmp(s.data + i, needle, m) == 0) return 1;
  }
  return 0;
}

static int equals(struct GeoArrowStringView s, const char* text) {
  return s.size_bytes == (int64_t)strlen(text) && memcmp(s.data, text, (size_t)s.size_bytes) == 0;
}

// is the "type" member of the outermost PROJJSON object GeographicCRS? a projected CRS has
// a nested base_crs of that type which mentions 4326, so a plain substring test is wrong
static int projjson_is_geographic(struct GeoArrowStringView s) {
  static const char key[] = "\"type\"";
  static const char want[] = "\"GeographicCRS\"";
  const int64_t nk = (int64_t)sizeof(key) - 1, nw = (int64_t)sizeof(want) - 1;
  int depth = 0, in_string = 0;
  for (int64_t i = 0; i < s.size_bytes; i++) {
    const char ch = s.data[i];
    if (in_string) {
      if (ch == '\\') i++;
      else if (ch == '"') in_string = 0;
      continue;
    }
    if (ch == '{' || ch == '[') {
      depth++;
    } else if (ch == '}' || ch == ']') {
      depth--;
    } else if (ch == '"') {
      if (depth == 1 && i + nk <= s.size_bytes && memcmp(s.data + i, key, (size_t)nk) == 0) {
        int64_t j = i + nk;
        while (j < s.size_bytes && (s.data[j] == ' ' || s.data[j] == ':')) j++;
        return j + nw <= s.size_bytes && memcmp(s.data + j, want, (size_t)nw) == 0;
      }
      in_string = 1;
    }
  }
  return 0;
}

// see dggrid_arrow.h
static int check_crs(dg_ctx* ctx, const struct ArrowSchema* schema) {
  struct GeoArrowSchemaView sv;
  struct GeoArrowMetadataView meta;
  struct GeoArrowError gerr;
  gerr.message[0] = 0;
  if (GeoArrowSchemaViewInit(&sv, schema, &gerr) != GEOARROW_OK ||
      GeoArrowMetadataViewInit(&meta, sv.extension_metadata, &gerr) != GEOARROW_OK) {
    return fail(ctx, DG_EINVAL, gerr.message);
  }
  if (meta.crs_type == GEOARROW_CRS_TYPE_NONE) return DG_OK;
  if (dg_ctx_datum(ctx) != DG_DATUM_WGS84) {
    return fail(ctx, DG_EINVAL, "authalic preset takes latitudes on the authalic sphere, input has a CRS");
  }
  // a JSON string or object in the metadata, PROJJSON can come as either
  const int64_t need = GeoArrowUnescapeCrs(meta.crs, NULL, 0);
  char* text = (char*)malloc((size_t)need + 1);
  if (!text) return fail(ctx, DG_ENOMEM, "out of memory");
  GeoArrowUnescapeCrs(meta.crs, text, need + 1);
  struct GeoArrowStringView crs = {text, need};
  int ok;
  if (need > 0 && text[0] == '{') {
    ok = projjson_is_geographic(crs) && (contains(crs, "CRS84") || contains(crs, "4326"));
  } else {
    ok = equals(crs, "OGC:CRS84") || equals(crs, "EPSG:4326");
  }
  free(text);
  if (!ok) return fail(ctx, DG_EINVAL, "input CRS is not OGC:CRS84 / EPSG:4326, reproject first");
  return DG_OK;
}

// ---- z7 out ----

// z7 (valid elements only, as many as valid[] has 1s) -> uint64 array with nulls
static int finish_ids(dg_ctx* ctx, const uint64_t* z7, const uint8_t* valid, int64_t n,
                      struct ArrowSchema* out_schema, struct ArrowArray* out) {
  int rc = ArrowSchemaInitFromType(out_schema, NANOARROW_TYPE_UINT64);
  if (rc == NANOARROW_OK) rc = ArrowSchemaSetName(out_schema, "z7");
  if (rc == NANOARROW_OK) rc = ArrowArrayInitFromType(out, NANOARROW_TYPE_UINT64);
  if (rc == NANOARROW_OK) rc = ArrowArrayStartAppending(out);
  int64_t k = 0;
  for (int64_t i = 0; rc == NANOARROW_OK && i < n; i++) {
    rc = valid[i] ? ArrowArrayAppendUInt(out, z7[k++]) : ArrowArrayAppendNull(out, 1);
  }
  if (rc == NANOARROW_OK) rc = ArrowArrayFinishBuildingDefault(out, NULL);
  if (rc != NANOARROW_OK) {
    release_out(out_schema, out);
    return fail(ctx, DG_ENOMEM, "building the z7 array failed");
  }
  return DG_OK;
}

// lon/lat with n elements (holes where !valid) -> compacted batch -> ids
static int points_to_ids(dg_ctx* ctx, int res, double* lon, double* lat, const uint8_t* valid,
                         int64_t n, struct ArrowSchema* out_schema, struct ArrowArray* out) {
  int64_t k = 0;
  for (int64_t i = 0; i < n; i++) {
    if (valid[i]) {
      lon[k] = lon[i];
      lat[k] = lat[i];
      k++;
    }
  }
  uint64_t* z7 = (uint64_t*)alloc_n(k, sizeof(uint64_t));
  if (!z7) return fail(ctx, DG_ENOMEM, "out of memory");
  int rc = dg_geo_to_z7(ctx, res, lon, lat, (size_t)k, z7);
  if (rc == DG_OK) rc = finish_ids(ctx, z7, valid, n, out_schema, out);
  free(z7);
  return rc;
}

int dg_arrow_geo_to_z7(dg_ctx* ctx, int res, const struct ArrowSchema* in_schema,
                       const struct ArrowArray* in, struct ArrowSchema* out_schema,
                       struct ArrowArray* out) {
  clear_out(out_schema, out);
  int rc = check_crs(ctx, in_schema);
  if (rc != DG_OK) return rc;

  const int64_t n = in->length;
  double* lon = (double*)alloc_n(n, sizeof(double));
  double* lat = (double*)alloc_n(n, sizeof(double));
  uint8_t* valid = (uint8_t*)alloc_n(n, 1);
  struct GeoArrowArrayReader reader;
  struct GeoArrowError gerr;
  gerr.message[0] = 0;
  int have_reader = 0;
  if (!lon || !lat || !valid) {
    rc = fail(ctx, DG_ENOMEM, "out of memory");
  } else if (GeoArrowArrayReaderInitFromSchema(&reader, in_schema, &gerr) != GEOARROW_OK) {
    rc = fail(ctx, DG_EINVAL, gerr.message);
  } else {
    have_reader = 1;
    Collect c = {lon, lat, valid, 0, 0};
    struct GeoArrowVisitor v;
    GeoArrowVisitorInitVoid(&v);
    v.feat_start = &c_feat_start;
    v.geom_start = &c_geom_start;
    v.coords = &c_coords;
    v.feat_end = &c_feat_end;
    v.private_data = &c;
    v.error = &gerr;
    if (GeoArrowArrayReaderSetArray(&reader, in, &gerr) != GEOARROW_OK ||
        GeoArrowArrayReaderVisit(&reader, 0, n, &v) != GEOARROW_OK) {
      rc = fail(ctx, DG_EINVAL, gerr.message);
    } else {
      rc = points_to_ids(ctx, res, lon, lat, valid, n, out_schema, out);
    }
  }
  if (have_reader) GeoArrowArrayReaderReset(&reader);
  free(lon);
  free(lat);
  free(valid);
  return rc;
}

// a float64 / float32 array as a checked view. *view is initialised on any return
static int float_view(dg_ctx* ctx, const struct ArrowSchema* schema, const struct ArrowArray* array,
                      struct ArrowArrayView* view) {
  struct ArrowError aerr;
  aerr.message[0] = 0;
  struct ArrowSchemaView sv;
  ArrowArrayViewInitFromType(view, NANOARROW_TYPE_UNINITIALIZED);
  if (ArrowSchemaViewInit(&sv, schema, &aerr) != NANOARROW_OK) return fail(ctx, DG_EINVAL, aerr.message);
  if (sv.type != NANOARROW_TYPE_DOUBLE && sv.type != NANOARROW_TYPE_FLOAT) {
    return fail(ctx, DG_EINVAL, "lon and lat must be float64 or float32");
  }
  ArrowArrayViewInitFromType(view, sv.type);
  if (ArrowArrayViewSetArray(view, array, &aerr) != NANOARROW_OK) return fail(ctx, DG_EINVAL, aerr.message);
  return DG_OK;
}

int dg_arrow_lonlat_to_z7(dg_ctx* ctx, int res, const struct ArrowSchema* lon_schema,
                          const struct ArrowArray* lon_in, const struct ArrowSchema* lat_schema,
                          const struct ArrowArray* lat_in, struct ArrowSchema* out_schema,
                          struct ArrowArray* out) {
  clear_out(out_schema, out);
  if (lon_in->length != lat_in->length) return fail(ctx, DG_EINVAL, "lon and lat differ in length");
  const int64_t n = lon_in->length;
  struct ArrowArrayView vlon, vlat;
  int rc = float_view(ctx, lon_schema, lon_in, &vlon);
  ArrowArrayViewInitFromType(&vlat, NANOARROW_TYPE_UNINITIALIZED);
  if (rc == DG_OK) rc = float_view(ctx, lat_schema, lat_in, &vlat);
  if (rc == DG_OK) {
    double* lon = (double*)alloc_n(n, sizeof(double));
    double* lat = (double*)alloc_n(n, sizeof(double));
    uint8_t* valid = (uint8_t*)alloc_n(n, 1);
    if (!lon || !lat || !valid) {
      rc = fail(ctx, DG_ENOMEM, "out of memory");
    } else {
      for (int64_t i = 0; i < n; i++) {
        const int isnull = ArrowArrayViewIsNull(&vlon, i) || ArrowArrayViewIsNull(&vlat, i);
        lon[i] = isnull ? NAN : ArrowArrayViewGetDoubleUnsafe(&vlon, i);
        lat[i] = isnull ? NAN : ArrowArrayViewGetDoubleUnsafe(&vlat, i);
        valid[i] = !(isnan(lon[i]) && isnan(lat[i]));
      }
      rc = points_to_ids(ctx, res, lon, lat, valid, n, out_schema, out);
    }
    free(lon);
    free(lat);
    free(valid);
  }
  ArrowArrayViewReset(&vlon);
  ArrowArrayViewReset(&vlat);
  return rc;
}

// ---- z7 in, geometry out ----

// *z7 = the k non null ids, valid = n flags, both malloc'ed
static int read_z7(dg_ctx* ctx, const struct ArrowSchema* schema, const struct ArrowArray* array,
                   uint64_t** z7, uint8_t** valid, int64_t* k) {
  struct ArrowError aerr;
  aerr.message[0] = 0;
  struct ArrowSchemaView sv;
  if (ArrowSchemaViewInit(&sv, schema, &aerr) != NANOARROW_OK) return fail(ctx, DG_EINVAL, aerr.message);
  if (sv.type != NANOARROW_TYPE_UINT64 && sv.type != NANOARROW_TYPE_INT64) {
    return fail(ctx, DG_EINVAL, "z7 must be uint64 or int64");
  }
  struct ArrowArrayView view;
  ArrowArrayViewInitFromType(&view, sv.type);
  if (ArrowArrayViewSetArray(&view, array, &aerr) != NANOARROW_OK) {
    ArrowArrayViewReset(&view);
    return fail(ctx, DG_EINVAL, aerr.message);
  }
  const int64_t n = array->length;
  *z7 = (uint64_t*)alloc_n(n, sizeof(uint64_t));
  *valid = (uint8_t*)alloc_n(n, 1);
  if (!*z7 || !*valid) {
    free(*z7);
    free(*valid);
    ArrowArrayViewReset(&view);
    return fail(ctx, DG_ENOMEM, "out of memory");
  }
  const uint64_t* values = (const uint64_t*)array->buffers[1] + array->offset;
  int64_t m = 0;
  for (int64_t i = 0; i < n; i++) {
    (*valid)[i] = !ArrowArrayViewIsNull(&view, i);
    if ((*valid)[i]) (*z7)[m++] = values[i];
  }
  *k = m;
  ArrowArrayViewReset(&view);
  return DG_OK;
}

static int encoding_type(int encoding, enum GeoArrowType native, enum GeoArrowType interleaved,
                         enum GeoArrowType* type) {
  switch (encoding) {
    case DG_ARROW_NATIVE: *type = native; return 1;
    case DG_ARROW_INTERLEAVED: *type = interleaved; return 1;
    case DG_ARROW_WKB: *type = GEOARROW_TYPE_WKB; return 1;
    case DG_ARROW_WKT: *type = GEOARROW_TYPE_WKT; return 1;
    default: return 0;
  }
}

static int finish_geometry(dg_ctx* ctx, enum GeoArrowType type, const char* name,
                           struct GeoArrowArrayWriter* w, struct GeoArrowError* gerr,
                           struct ArrowSchema* out_schema, struct ArrowArray* out) {
  int rc = GeoArrowArrayWriterFinish(w, out, gerr);
  if (rc == GEOARROW_OK) rc = GeoArrowSchemaInitExtension(out_schema, type);
  if (rc == GEOARROW_OK) rc = ArrowSchemaSetName(out_schema, name);
  if (rc == GEOARROW_OK && dg_ctx_datum(ctx) == DG_DATUM_WGS84) {
    struct GeoArrowMetadataView meta;
    struct GeoArrowStringView empty = {NULL, 0};
    rc = GeoArrowMetadataViewInit(&meta, empty, gerr);
    GeoArrowMetadataSetLonLat(&meta);
    if (rc == GEOARROW_OK) rc = GeoArrowSchemaSetMetadata(out_schema, &meta);
  }
  if (rc != GEOARROW_OK) {
    release_out(out_schema, out);
    return fail(ctx, DG_ENOMEM, "building the geometry array failed");
  }
  return DG_OK;
}

int dg_arrow_z7_to_points(dg_ctx* ctx, const struct ArrowSchema* z7_schema,
                          const struct ArrowArray* z7_in, int encoding,
                          struct ArrowSchema* out_schema, struct ArrowArray* out) {
  clear_out(out_schema, out);
  enum GeoArrowType type;
  if (!encoding_type(encoding, GEOARROW_TYPE_POINT, GEOARROW_TYPE_INTERLEAVED_POINT, &type)) {
    return fail(ctx, DG_EINVAL, "unknown encoding");
  }
  uint64_t* z7;
  uint8_t* valid;
  int64_t k;
  int rc = read_z7(ctx, z7_schema, z7_in, &z7, &valid, &k);
  if (rc != DG_OK) return rc;

  double* lon = (double*)alloc_n(k, sizeof(double));
  double* lat = (double*)alloc_n(k, sizeof(double));
  if (!lon || !lat) rc = fail(ctx, DG_ENOMEM, "out of memory");
  if (rc == DG_OK) rc = dg_z7_to_centroid(ctx, z7, (size_t)k, lon, lat);

  struct GeoArrowArrayWriter w;
  if (rc == DG_OK) {
    struct GeoArrowError gerr;
    gerr.message[0] = 0;
    struct GeoArrowVisitor v;
    int g = GeoArrowArrayWriterInitFromType(&w, type);
    if (g == GEOARROW_OK) {
      g = GeoArrowArrayWriterInitVisitor(&w, &v);
      v.error = &gerr;
      int64_t m = 0;
      for (int64_t i = 0; g == GEOARROW_OK && i < z7_in->length; i++) {
        g = v.feat_start(&v);
        if (g == GEOARROW_OK && !valid[i]) {
          g = v.null_feat(&v);
        } else if (g == GEOARROW_OK) {
          struct GeoArrowCoordView c;
          memset(&c, 0, sizeof(c));
          c.values[0] = &lon[m];
          c.values[1] = &lat[m];
          c.n_coords = 1;
          c.n_values = 2;
          c.coords_stride = 1;
          m++;
          g = v.geom_start(&v, GEOARROW_GEOMETRY_TYPE_POINT, GEOARROW_DIMENSIONS_XY);
          if (g == GEOARROW_OK) g = v.coords(&v, &c);
          if (g == GEOARROW_OK) g = v.geom_end(&v);
        }
        if (g == GEOARROW_OK) g = v.feat_end(&v);
      }
      rc = g == GEOARROW_OK ? finish_geometry(ctx, type, "centroid", &w, &gerr, out_schema, out)
                            : fail(ctx, DG_ENOMEM, gerr.message);
      GeoArrowArrayWriterReset(&w);
    } else {
      rc = fail(ctx, DG_ENOMEM, "writer init failed");
    }
  }
  free(lon);
  free(lat);
  free(z7);
  free(valid);
  return rc;
}

int dg_arrow_z7_to_polygons(dg_ctx* ctx, const struct ArrowSchema* z7_schema,
                            const struct ArrowArray* z7_in, int encoding,
                            struct ArrowSchema* out_schema, struct ArrowArray* out) {
  clear_out(out_schema, out);
  enum GeoArrowType type;
  if (!encoding_type(encoding, GEOARROW_TYPE_POLYGON, GEOARROW_TYPE_INTERLEAVED_POLYGON, &type)) {
    return fail(ctx, DG_EINVAL, "unknown encoding");
  }
  uint64_t* z7;
  uint8_t* valid;
  int64_t k;
  int rc = read_z7(ctx, z7_schema, z7_in, &z7, &valid, &k);
  if (rc != DG_OK) return rc;

  double* ll = (double*)alloc_n(k * 12, sizeof(double));
  uint8_t* nv = (uint8_t*)alloc_n(k, 1);
  if (!ll || !nv) rc = fail(ctx, DG_ENOMEM, "out of memory");
  if (rc == DG_OK) rc = dg_z7_to_boundary(ctx, z7, (size_t)k, ll, nv);

  struct GeoArrowArrayWriter w;
  if (rc == DG_OK) {
    struct GeoArrowError gerr;
    gerr.message[0] = 0;
    struct GeoArrowVisitor v;
    int g = GeoArrowArrayWriterInitFromType(&w, type);
    if (g == GEOARROW_OK) {
      g = GeoArrowArrayWriterInitVisitor(&w, &v);
      v.error = &gerr;
      int64_t m = 0;
      for (int64_t i = 0; g == GEOARROW_OK && i < z7_in->length; i++) {
        g = v.feat_start(&v);
        if (g == GEOARROW_OK && !valid[i]) {
          g = v.null_feat(&v);
        } else if (g == GEOARROW_OK) {
          double x[7], y[7];
          const int nverts = nv[m];
          for (int j = 0; j < nverts; j++) {
            x[j] = ll[m * 12 + 2 * j];
            y[j] = ll[m * 12 + 2 * j + 1];
          }
          x[nverts] = x[0];  // closed ring
          y[nverts] = y[0];
          m++;
          struct GeoArrowCoordView c;
          memset(&c, 0, sizeof(c));
          c.values[0] = x;
          c.values[1] = y;
          c.n_coords = nverts + 1;
          c.n_values = 2;
          c.coords_stride = 1;
          g = v.geom_start(&v, GEOARROW_GEOMETRY_TYPE_POLYGON, GEOARROW_DIMENSIONS_XY);
          if (g == GEOARROW_OK) g = v.ring_start(&v);
          if (g == GEOARROW_OK) g = v.coords(&v, &c);
          if (g == GEOARROW_OK) g = v.ring_end(&v);
          if (g == GEOARROW_OK) g = v.geom_end(&v);
        }
        if (g == GEOARROW_OK) g = v.feat_end(&v);
      }
      rc = g == GEOARROW_OK ? finish_geometry(ctx, type, "cell", &w, &gerr, out_schema, out)
                            : fail(ctx, DG_ENOMEM, gerr.message);
      GeoArrowArrayWriterReset(&w);
    } else {
      rc = fail(ctx, DG_ENOMEM, "writer init failed");
    }
  }
  free(ll);
  free(nv);
  free(z7);
  free(valid);
  return rc;
}

// ---- z7 topology + strings ----

int dg_arrow_z7_parent(dg_ctx* ctx, const struct ArrowSchema* z7_schema, const struct ArrowArray* z7_in,
                       int res, struct ArrowSchema* out_schema, struct ArrowArray* out) {
  clear_out(out_schema, out);
  uint64_t* z7;
  uint8_t* valid;
  int64_t k;
  int rc = read_z7(ctx, z7_schema, z7_in, &z7, &valid, &k);
  if (rc != DG_OK) return rc;
  uint64_t* up = (uint64_t*)alloc_n(k, sizeof(uint64_t));
  if (!up) rc = fail(ctx, DG_ENOMEM, "out of memory");
  if (rc == DG_OK) rc = dg_z7_parent(ctx, z7, (size_t)k, res, up);
  if (rc == DG_OK) rc = finish_ids(ctx, up, valid, z7_in->length, out_schema, out);
  free(up);
  free(z7);
  free(valid);
  return rc;
}

// list<uint64> (n_slots per id, DG_Z7_NONE slots left out) or fixed_size_list<uint64>[n_slots]
// (DG_Z7_NONE slots as null elements)
static int finish_id_lists(dg_ctx* ctx, const char* name, int fixed, const uint64_t* ids, int n_slots,
                           const uint8_t* valid, int64_t n, struct ArrowSchema* out_schema,
                           struct ArrowArray* out) {
  ArrowSchemaInit(out_schema);
  int rc = fixed ? ArrowSchemaSetTypeFixedSize(out_schema, NANOARROW_TYPE_FIXED_SIZE_LIST, n_slots)
                 : ArrowSchemaSetType(out_schema, NANOARROW_TYPE_LIST);
  if (rc == NANOARROW_OK) rc = ArrowSchemaSetName(out_schema, name);
  if (rc == NANOARROW_OK) rc = ArrowSchemaSetType(out_schema->children[0], NANOARROW_TYPE_UINT64);
  if (rc == NANOARROW_OK) rc = ArrowSchemaSetName(out_schema->children[0], "z7");
  if (rc == NANOARROW_OK) rc = ArrowArrayInitFromSchema(out, out_schema, NULL);
  if (rc == NANOARROW_OK) rc = ArrowArrayStartAppending(out);
  int64_t m = 0;
  for (int64_t i = 0; rc == NANOARROW_OK && i < n; i++) {
    if (!valid[i]) {
      rc = ArrowArrayAppendNull(out, 1);
      continue;
    }
    for (int s = 0; rc == NANOARROW_OK && s < n_slots; s++) {
      const uint64_t z = ids[m * n_slots + s];
      if (z != DG_Z7_NONE) rc = ArrowArrayAppendUInt(out->children[0], z);
      else if (fixed) rc = ArrowArrayAppendNull(out->children[0], 1);
    }
    m++;
    if (rc == NANOARROW_OK) rc = ArrowArrayFinishElement(out);
  }
  if (rc == NANOARROW_OK) rc = ArrowArrayFinishBuildingDefault(out, NULL);
  if (rc != NANOARROW_OK) {
    release_out(out_schema, out);
    return fail(ctx, DG_ENOMEM, "building the list array failed");
  }
  return DG_OK;
}

typedef int (*IdsToSlots)(dg_ctx*, const uint64_t*, size_t, uint64_t*);

static int z7_to_lists(dg_ctx* ctx, const struct ArrowSchema* z7_schema, const struct ArrowArray* z7_in,
                       IdsToSlots fn, int n_slots, int fixed, const char* name,
                       struct ArrowSchema* out_schema, struct ArrowArray* out) {
  clear_out(out_schema, out);
  uint64_t* z7;
  uint8_t* valid;
  int64_t k;
  int rc = read_z7(ctx, z7_schema, z7_in, &z7, &valid, &k);
  if (rc != DG_OK) return rc;
  uint64_t* slots = (uint64_t*)alloc_n(k * n_slots, sizeof(uint64_t));
  if (!slots) rc = fail(ctx, DG_ENOMEM, "out of memory");
  if (rc == DG_OK) rc = fn(ctx, z7, (size_t)k, slots);
  if (rc == DG_OK) rc = finish_id_lists(ctx, name, fixed, slots, n_slots, valid, z7_in->length, out_schema, out);
  free(slots);
  free(z7);
  free(valid);
  return rc;
}

int dg_arrow_z7_children(dg_ctx* ctx, const struct ArrowSchema* z7_schema, const struct ArrowArray* z7,
                         struct ArrowSchema* out_schema, struct ArrowArray* out) {
  return z7_to_lists(ctx, z7_schema, z7, &dg_z7_children, 7, 0, "children", out_schema, out);
}

int dg_arrow_z7_neighbors(dg_ctx* ctx, const struct ArrowSchema* z7_schema, const struct ArrowArray* z7,
                          struct ArrowSchema* out_schema, struct ArrowArray* out) {
  return z7_to_lists(ctx, z7_schema, z7, &dg_z7_neighbors, 6, 1, "neighbors", out_schema, out);
}

int dg_arrow_z7_to_string(dg_ctx* ctx, const struct ArrowSchema* z7_schema, const struct ArrowArray* z7_in,
                          struct ArrowSchema* out_schema, struct ArrowArray* out) {
  clear_out(out_schema, out);
  uint64_t* z7;
  uint8_t* valid;
  int64_t k;
  int rc = read_z7(ctx, z7_schema, z7_in, &z7, &valid, &k);
  if (rc != DG_OK) return rc;
  for (int64_t i = 0; i < k; i++) {
    if (dg_z7_res(z7[i]) < 0) {
      char msg[96];
      snprintf(msg, sizeof msg, "0x%016llx is not a valid Z7 index", (unsigned long long)z7[i]);
      rc = fail(ctx, DG_EINVAL, msg);
      break;
    }
  }
  int a = NANOARROW_OK;
  if (rc == DG_OK) {
    a = ArrowSchemaInitFromType(out_schema, NANOARROW_TYPE_STRING);
    if (a == NANOARROW_OK) a = ArrowSchemaSetName(out_schema, "z7");
    if (a == NANOARROW_OK) a = ArrowArrayInitFromType(out, NANOARROW_TYPE_STRING);
    if (a == NANOARROW_OK) a = ArrowArrayStartAppending(out);
    int64_t m = 0;
    for (int64_t i = 0; a == NANOARROW_OK && i < z7_in->length; i++) {
      if (!valid[i]) {
        a = ArrowArrayAppendNull(out, 1);
        continue;
      }
      char buf[32];
      const int len = dg_z7_to_string(z7[m++], buf, sizeof buf);
      struct ArrowStringView sv = {buf, len};
      a = ArrowArrayAppendString(out, sv);
    }
    if (a == NANOARROW_OK) a = ArrowArrayFinishBuildingDefault(out, NULL);
    if (a != NANOARROW_OK) {
      release_out(out_schema, out);
      rc = fail(ctx, DG_ENOMEM, "building the string array failed");
    }
  }
  free(z7);
  free(valid);
  return rc;
}

int dg_arrow_z7_from_string(dg_ctx* ctx, const struct ArrowSchema* str_schema, const struct ArrowArray* str,
                            struct ArrowSchema* out_schema, struct ArrowArray* out) {
  clear_out(out_schema, out);
  struct ArrowError aerr;
  aerr.message[0] = 0;
  struct ArrowSchemaView sv;
  if (ArrowSchemaViewInit(&sv, str_schema, &aerr) != NANOARROW_OK) return fail(ctx, DG_EINVAL, aerr.message);
  if (sv.type != NANOARROW_TYPE_STRING && sv.type != NANOARROW_TYPE_LARGE_STRING) {
    return fail(ctx, DG_EINVAL, "Z7 strings must be utf8 or large_utf8");
  }
  struct ArrowArrayView view;
  ArrowArrayViewInitFromType(&view, sv.type);
  if (ArrowArrayViewSetArray(&view, str, &aerr) != NANOARROW_OK) {
    ArrowArrayViewReset(&view);
    return fail(ctx, DG_EINVAL, aerr.message);
  }
  const int64_t n = str->length;
  uint64_t* z7 = (uint64_t*)alloc_n(n, sizeof(uint64_t));
  uint8_t* valid = (uint8_t*)alloc_n(n, 1);
  int rc = (!z7 || !valid) ? fail(ctx, DG_ENOMEM, "out of memory") : DG_OK;
  int64_t k = 0;
  for (int64_t i = 0; rc == DG_OK && i < n; i++) {
    valid[i] = !ArrowArrayViewIsNull(&view, i);
    if (!valid[i]) continue;
    const struct ArrowStringView s = ArrowArrayViewGetStringUnsafe(&view, i);
    if (dg_z7_from_string(s.data, (size_t)s.size_bytes, &z7[k]) != DG_OK) {
      char msg[96];
      snprintf(msg, sizeof msg, "string %lld \"%.*s\" is not a Z7 index", (long long)i,
               (int)(s.size_bytes < 24 ? s.size_bytes : 24), s.data);
      rc = fail(ctx, DG_EINVAL, msg);
    }
    k++;
  }
  if (rc == DG_OK) rc = finish_ids(ctx, z7, valid, n, out_schema, out);
  ArrowArrayViewReset(&view);
  free(z7);
  free(valid);
  return rc;
}

void dg_arrow_release_schema(struct ArrowSchema* schema) {
  if (schema && schema->release) schema->release(schema);
}

void dg_arrow_release_array(struct ArrowArray* array) {
  if (array && array->release) array->release(array);
}
