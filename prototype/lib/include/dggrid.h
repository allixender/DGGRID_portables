/* dggrid.h: prototype IGEO7 library (DGGRID ISEA aperture 7 hexagons + Z7 index).
 *
 * Implemented in dggrid.zig on top of dgcore.cpp (DGGRID). Coordinates are degrees,
 * lon in [-180, 180], lat in [-90, 90]. Batch functions return DG_OK or a negative
 * code, with a message from dg_last_error(ctx). A context is not thread-safe, use one
 * per thread.
 *
 * Z7 int: bits 60-63 base cell 0-11, then 20 radix-7 digits of 3 bits (res 1 at bits
 * 57-59 ... res 20 at bits 0-2), digits beyond the cell's resolution are 7.
 * Z7 string: 2-digit base cell + one digit per resolution, e.g. "0401234" (res 5).
 */
#ifndef DGGRID_H
#define DGGRID_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DG_OK        0
#define DG_EINVAL   -1   /* invalid argument (resolution, coordinate, Z7 index) */
#define DG_EDGGRID  -2   /* error reported by DGGRID */
#define DG_ENOMEM   -3

#define DG_MAX_RES  20

typedef struct dg_ctx dg_ctx;

/* IGEO7: vert0 (11.25, 58.28252559), azimuth 0 (= DGGRID dggs_type IGEO7) */
dg_ctx* dg_igeo7_new(void);
/* ISEA7H + Z7 with another icosahedron orientation */
dg_ctx* dg_ctx_new(double vert0_lon, double vert0_lat, double azimuth);
void    dg_ctx_free(dg_ctx* ctx);
/* message of the last error on ctx; ctx == NULL: why the last dg_*_new failed */
const char* dg_last_error(const dg_ctx* ctx);

/* cells containing the points, at resolution res (0..DG_MAX_RES) */
int dg_geo_to_z7(dg_ctx* ctx, int res, const double* lon, const double* lat, size_t n,
                 uint64_t* out);
/* cell centre points; resolution taken from each index */
int dg_z7_to_centroid(dg_ctx* ctx, const uint64_t* z7, size_t n, double* lon, double* lat);
/* cell boundaries: lonlat gets n * 6 (lon, lat) pairs, nverts 6, or 5 for the 12
 * pentagons per resolution (6th pair NaN) */
int dg_z7_to_boundary(dg_ctx* ctx, const uint64_t* z7, size_t n, double* lonlat,
                      uint8_t* nverts);

/* Z7 helpers, no context needed */
int dg_z7_res(uint64_t z7);                                  /* -1 if invalid */
int dg_z7_to_string(uint64_t z7, char* buf, size_t len);     /* length, -1 on error */
int dg_z7_from_string(const char* s, size_t len, uint64_t* out);

/* malloc/free of this library, for callers sharing no allocator (wasm/JS) */
void* dg_alloc(size_t n);
void  dg_free(void* p);

#ifdef __cplusplus
}
#endif

#endif
