// bench: dglib without file IO, geo -> Q2DI at res 9 for N pseudo-random points.
// Prints the Tartu cell + its vertices, timing, and a hash over all Q2DI results
// (equal hash = identical cells). Native builds also test the fatal hook (0101 patch).
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <stdexcept>
#include <string>
#include <dglib/DgReal.h>
#include <dglib/DgBase.h>
#include <dglib/DgIDGGS7H.h>
#include <dglib/DgGeoSphRF.h>
#include <dglib/DgPolygon.h>

#if defined(__cpp_exceptions) && !defined(__wasm__)
static void throwFatal(const std::string& message) { throw std::runtime_error(message); }

static void testFatalHook()
{
   DgBase::setFatalHook(throwFatal);
   DgBase::setMinReportLevel(DgBase::Silent);  // hook must fire anyway
   try {
      report("bench: deliberate fatal", DgBase::Fatal);
      std::printf("fatal hook: FAILED, report() returned\n");
   } catch (const std::runtime_error& e) {
      std::printf("fatal hook: caught \"%s\"\n", e.what());
   }
   DgBase::setMinReportLevel(DgBase::Info);
   DgBase::setFatalHook(NULL);
}
#else
static void testFatalHook() { std::printf("fatal hook: skipped (no exceptions)\n"); }
#endif

int main(int argc, char** argv)
{
   int n = argc > 1 ? std::atoi(argv[1]) : 100000;
   testFatalHook();

   DgRFNetwork net0;
   const DgGeoSphRF& geoRF = *(DgGeoSphRF::makeRF(net0, "GS0"));
   DgGeoCoord vert0(11.25, 58.28252559, false);
   const DgIDGGS7H& idggs = *DgIDGGS7H::makeRF(net0, geoRF, vert0, 0.0, 10);
   const DgIDGG& dgg = idggs.idgg(9);

   DgLocation* pt = geoRF.makeLocation(DgGeoCoord(26.7290, 58.3780, false));
   dgg.convert(pt);
   std::printf("cell %s  sizeof(dgreal)=%d\n", pt->asString().c_str(), (int)sizeof(dgreal));
   DgPolygon verts;
   dgg.setVertices(*pt, verts, 0);
   for (int i = 0; i < verts.size(); i++) {
      const DgGeoCoord& c = *geoRF.getAddress(verts[i]);
      std::printf("  %.12f %.12f\n", (double)c.lonDegs(), (double)c.latDegs());
   }
   delete pt;

   unsigned long long h = 0, s = 88172645463325252ULL;
   clock_t t0 = clock();
   for (int k = 0; k < n; k++) {
      s ^= s << 13; s ^= s >> 7; s ^= s << 17;
      double lon = (s % 3600000) / 10000.0 - 180.0;
      double lat = ((s >> 24) % 1700000) / 10000.0 - 85.0;
      DgLocation* p = geoRF.makeLocation(DgGeoCoord(lon, lat, false));
      dgg.convert(p);
      const DgQ2DICoord& q = *dgg.getAddress(*p);
      h = h * 31 + q.quadNum() * 1000003ULL + q.coord().i() * 7919ULL + q.coord().j();
      delete p;
   }
   double secs = double(clock() - t0) / CLOCKS_PER_SEC;
   std::printf("%d pts geo->Q2DI res9: %.3fs (%.0f pts/s) hash %llx\n", n, secs, n / secs, h);
   std::fflush(stdout);
   return 0;
}
