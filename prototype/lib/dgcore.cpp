// dgcore.cpp: the only file that touches DGGRID classes. Aperture 7 hexagons (ISEA or
// IVEA) + the Z7 hierarchical index system, built the way DGGRID 9.2's SubOpDGG does:
//   IDGGS on the WGS84 authalic sphere, DgIDGGSBase::makeRF(.., Z7)
//   wgs84: coordinates at the API are geodetic. longitude is unaffected, latitude goes
//          through DgAuthalic per value (= Dg2WayAuthalicConverter, without the network
//          path and its allocations)
//
// Plain C entry points for the Zig API layer (dggrid.zig), batch shaped, no STL or
// exceptions across the boundary. Coordinates in degrees. Return 0 on success, -1 on a
// DGGRID error (message via dgc_last_error). Inputs are validated on the Zig side.
//
// DGGRID reports fatal errors through report(..., Fatal), which exits the process.
// With patch 0101 a hook turns that into a C++ exception here; on wasm (no exception
// support) the default print + exit stays, so validation upfront matters there.
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>

#include <dglib/DgReal.h>
#include <dglib/DgAuthalicConverter.h>
#include <dglib/DgBase.h>
#include <dglib/DgConstants.h>
#include <dglib/DgGeoSphRF.h>
#include <dglib/DgHierNdx.h>
#include <dglib/DgHierNdxIntRF.h>
#include <dglib/DgHierNdxSystemRFBase.h>
#include <dglib/DgHierNdxSystemRFSBase.h>
#include <dglib/DgIDGGSBase.h>
#include <dglib/DgLocation.h>
#include <dglib/DgPolygon.h>
#include <dglib/DgRFNetwork.h>

#if defined(__cpp_exceptions) && !defined(__wasm__)
#define DGC_TRY try {
#define DGC_CATCH(ctx)                                              \
   } catch (const std::exception& e) { return (ctx)->fail(e.what()); } \
     catch (...) { return (ctx)->fail("unknown C++ exception"); }
#else
#define DGC_TRY {
#define DGC_CATCH(ctx) }
#endif

struct dgc_ctx {
   DgRFNetwork net;
   const DgGeoSphRF* geoRF = nullptr;
   const DgIDGGSBase* dggs = nullptr;
   const DgHierNdxSystemRFSBase* z7 = nullptr;
   bool wgs84 = false;
   DgGeoSphRF::DgLonWrapMode lonWrap = DgGeoSphRF::UnwrapEast;
   int maxRes = 0;
   std::string err;

   int fail(const char* msg) { err = msg; return -1; }
};

#if defined(__cpp_exceptions) && !defined(__wasm__)
static void throwFatal(const std::string& message) { throw std::runtime_error(message); }
#endif

// API point in degrees -> grid sphere. 90 * M_PI_180 may round to just above DgAuthalic's
// pi/2, which is a fatal error there, so the poles go in exact.
static DgGeoCoord toGrid(const dgc_ctx* ctx, double lonDeg, double latDeg)
{
   // an unwrapped cell's vertices and centres go up to +-360, see dgc_set_lon_wrap
   if (lonDeg > 180.0) lonDeg -= 360.0;
   else if (lonDeg < -180.0) lonDeg += 360.0;
   DgGeoCoord g(lonDeg, latDeg, false);
   if (ctx->wgs84) {
      const dgreal halfPi = M_2PI / DGR(4.0);
      const dgreal phi = g.lat();
      g.setLat(DgAuthalic::geodeticToAuthalicLatitude(
            fabs(latDeg) == 90.0 ? std::copysign(halfPi, phi) : phi));
   }
   return g;
}

// grid sphere -> API degrees
static void fromGrid(const dgc_ctx* ctx, const DgGeoCoord& c, double* lonDeg, double* latDeg)
{
   *lonDeg = (double) c.lonDegs();
   *latDeg = (double) (ctx->wgs84 ? DgAuthalic::authalicToGeodeticLatitude(c.lat()) * M_180_PI
                                  : c.latDegs());
}

extern "C" {

// proj: "ISEA" | "IVEA". vert0Lat NaN: the exact icosahedron vertex latitude of the 9.x
// presets. vert0 is on the authalic sphere, also for wgs84 (preset orientation_datum).
// all RFs are owned and deleted by the network
dgc_ctx* dgc_new(const char* proj, int wgs84, double vert0Lon, double vert0Lat,
                 double azimuthDegs, int maxRes, char* err, size_t errLen)
{
   dgc_ctx* ctx = new dgc_ctx;
#if defined(__cpp_exceptions) && !defined(__wasm__)
   DgBase::setFatalHook(throwFatal);
   DgBase::setMinReportLevel(DgBase::Warning);
   try {
#endif
      ctx->wgs84 = wgs84 != 0;
      ctx->geoRF = DgGeoSphRF::makeRF(ctx->net, "AUTHALIC_SPHERE");
      const dgreal lat0 = vert0Lat == vert0Lat ? (dgreal) vert0Lat : M_ICOSA_VERT0_LAT_DEG;
      ctx->dggs = DgIDGGSBase::makeRF(ctx->net, *ctx->geoRF, DgGeoCoord(vert0Lon, lat0, false),
                     azimuthDegs, 7, maxRes + 1, dgg::topo::Hexagon, dgg::topo::D6, "IDGGS",
                     proj, false, DgApSeq::defaultApSeq, false, 0, false, dgg::addtype::Z7);
      ctx->z7 = ctx->dggs->hierNdxSystem();
      ctx->maxRes = maxRes;
      return ctx;
#if defined(__cpp_exceptions) && !defined(__wasm__)
   } catch (const std::exception& e) {
      if (err && errLen) { std::strncpy(err, e.what(), errLen - 1); err[errLen - 1] = 0; }
      delete ctx;
      return nullptr;
   }
#endif
}

void dgc_free(dgc_ctx* ctx) { delete ctx; }

const char* dgc_last_error(const dgc_ctx* ctx) { return ctx->err.c_str(); }

int dgc_max_res(const dgc_ctx* ctx) { return ctx->maxRes; }

// boundaries only, centroids stay in -180..180 (= CLI unwrap_points FALSE), they are points
// and go back in. 0 WRAP, 1 UNWRAP_EAST, 2 UNWRAP_WEST = CLI longitude_wrap_mode
void dgc_set_lon_wrap(dgc_ctx* ctx, int mode)
{
   ctx->lonWrap = mode == 0 ? DgGeoSphRF::Wrap :
                  mode == 2 ? DgGeoSphRF::UnwrapWest : DgGeoSphRF::UnwrapEast;
}

int dgc_geo_to_z7(dgc_ctx* ctx, int res, const double* lon, const double* lat, size_t n,
                  uint64_t* out)
{
   DGC_TRY
   const DgHierNdxSystemRFBase& sys = ctx->z7->sysRF(res);
   for (size_t i = 0; i < n; i++) {
      // a fresh location per point: forceAddress() replaces the address but keeps
      // the location's frame, which convert() changed in the previous round
      DgLocation loc(*ctx->geoRF);
      ctx->geoRF->forceAddress(&loc, toGrid(ctx, lon[i], lat[i]));
      sys.convert(&loc);  // geo -> Q2DI (cell) -> Z7
      out[i] = sys.getAddress(loc)->intNdx().value();
   }
   return 0;
   DGC_CATCH(ctx)
}

// loc (a fresh location in sysRF(res)) set to Z7 cell `z`, converted to the Q2DI grid
static void setCell(const dgc_ctx* ctx, int res, uint64_t z, DgLocation& loc)
{
   const DgHierNdxSystemRFBase& sys = ctx->z7->sysRF(res);
   DgHierNdx hn(true);
   hn.setIntNdx(DgHierNdxIntCoord(z));
   sys.setStringFromIntCoord(hn);  // invQuantify works from the string form
   sys.forceAddress(&loc, hn);
   ctx->dggs->idggBase(res).convert(&loc);
}

int dgc_z7_to_centroid(dgc_ctx* ctx, int res, const uint64_t* z7, size_t n,
                       double* lon, double* lat)
{
   DGC_TRY
   for (size_t i = 0; i < n; i++) {
      DgLocation loc(ctx->z7->sysRF(res));
      setCell(ctx, res, z7[i], loc);
      ctx->geoRF->convert(&loc);
      fromGrid(ctx, *ctx->geoRF->getAddress(loc), &lon[i], &lat[i]);
   }
   return 0;
   DGC_CATCH(ctx)
}

// lonlat: n * 6 vertices * (lon, lat); pentagons fill 5 and leave the 6th NaN
int dgc_z7_to_boundary(dgc_ctx* ctx, int res, const uint64_t* z7, size_t n,
                       double* lonlat, uint8_t* nverts)
{
   DGC_TRY
   const DgIDGGBase& dgg = ctx->dggs->idggBase(res);
   DgPolygon poly;
   for (size_t i = 0; i < n; i++) {
      DgLocation loc(ctx->z7->sysRF(res));
      setCell(ctx, res, z7[i], loc);
      dgg.setVertices(loc, poly, 0);
      DgGeoSphRF::lonWrap(poly, ctx->lonWrap);
      int nv = poly.size();
      if (nv > 6) return ctx->fail("cell with more than 6 vertices");
      double* o = lonlat + i * 12;
      for (int v = 0; v < 6; v++) {
         if (v < nv) {
            fromGrid(ctx, *ctx->geoRF->getAddress(poly[v]), &o[2 * v], &o[2 * v + 1]);
         } else {
            o[2 * v] = o[2 * v + 1] = __builtin_nan("");
         }
      }
      nverts[i] = (uint8_t) nv;
   }
   return 0;
   DGC_CATCH(ctx)
}

} // extern "C"
