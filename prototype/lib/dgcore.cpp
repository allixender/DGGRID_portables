// dgcore.cpp: the only file that touches DGGRID classes. IGEO7 = DgIDGGS7H (ISEA,
// aperture 7 hexagons) + the Z7 hierarchical index system.
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
#include <dglib/DgBase.h>
#include <dglib/DgGeoSphRF.h>
#include <dglib/DgHierNdx.h>
#include <dglib/DgHierNdxIntRF.h>
#include <dglib/DgHierNdxSystemRFBase.h>
#include <dglib/DgIDGGS7H.h>
#include <dglib/DgLocation.h>
#include <dglib/DgPolygon.h>
#include <dglib/DgRFNetwork.h>
#include <dglib/DgZ7System.h>

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
   const DgIDGGS7H* dggs = nullptr;
   const DgZ7System* z7 = nullptr;
   int maxRes = 0;
   std::string err;

   int fail(const char* msg) { err = msg; return -1; }
};

#if defined(__cpp_exceptions) && !defined(__wasm__)
static void throwFatal(const std::string& message) { throw std::runtime_error(message); }
#endif

extern "C" {

// all RFs are owned and deleted by the network
dgc_ctx* dgc_new(double vert0Lon, double vert0Lat, double azimuthDegs, int maxRes,
                 char* err, size_t errLen)
{
   dgc_ctx* ctx = new dgc_ctx;
#if defined(__cpp_exceptions) && !defined(__wasm__)
   DgBase::setFatalHook(throwFatal);
   DgBase::setMinReportLevel(DgBase::Warning);
   try {
#endif
      ctx->geoRF = DgGeoSphRF::makeRF(ctx->net, "GS0");
      ctx->dggs = DgIDGGS7H::makeRF(ctx->net, *ctx->geoRF,
                     DgGeoCoord(vert0Lon, vert0Lat, false), azimuthDegs, maxRes + 1, "IGEO7");
      ctx->z7 = DgZ7System::makeSystem(*ctx->dggs, true, "Z7");
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

int dgc_geo_to_z7(dgc_ctx* ctx, int res, const double* lon, const double* lat, size_t n,
                  uint64_t* out)
{
   DGC_TRY
   const DgHierNdxSystemRFBase& sys = ctx->z7->sysRF(res);
   for (size_t i = 0; i < n; i++) {
      // a fresh location per point: forceAddress() replaces the address but keeps
      // the location's frame, which convert() changed in the previous round
      DgLocation loc(*ctx->geoRF);
      ctx->geoRF->forceAddress(&loc, DgGeoCoord(lon[i], lat[i], false));
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
      const DgGeoCoord& c = *ctx->geoRF->getAddress(loc);
      lon[i] = (double) c.lonDegs();
      lat[i] = (double) c.latDegs();
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
      int nv = poly.size();
      if (nv > 6) return ctx->fail("cell with more than 6 vertices");
      double* o = lonlat + i * 12;
      for (int v = 0; v < 6; v++) {
         if (v < nv) {
            const DgGeoCoord& c = *ctx->geoRF->getAddress(poly[v]);
            o[2 * v] = (double) c.lonDegs();
            o[2 * v + 1] = (double) c.latDegs();
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
