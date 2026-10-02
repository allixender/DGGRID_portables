// smoke test: DGGRID library (no file IO) -> cell polygon -> GeoArrow WKB array
#include <cstdio>
#include <sstream>
#include <iomanip>
#include <string>
#include <dglib/DgIDGGS7H.h>
#include <dglib/DgGeoSphRF.h>
#include <dglib/DgPolygon.h>
#include "geoarrow/geoarrow.h"

int main() {
  DgRFNetwork net0;
  const DgGeoSphRF& geoRF = *(DgGeoSphRF::makeRF(net0, "GS0"));
  DgGeoCoord vert0(11.25L, 58.28252559L, false);
  const DgIDGGS7H& idggs = *DgIDGGS7H::makeRF(net0, geoRF, vert0, 0.0L, 10);
  const DgIDGG& dgg = idggs.idgg(5);

  // Tartu -> cell -> boundary
  DgLocation* pt = geoRF.makeLocation(DgGeoCoord(26.7290, 58.3780, false));
  dgg.convert(pt);
  DgPolygon verts;
  dgg.setVertices(*pt, verts, 0);

  std::ostringstream wkt; wkt << std::setprecision(10) << "POLYGON ((";
  for (int i = 0; i <= verts.size(); i++) {
    const DgGeoCoord& c = *geoRF.getAddress(verts[i % verts.size()]);
    wkt << (i ? ", " : "") << c.lonDegs() << " " << c.latDegs();
  }
  wkt << "))";
  std::string s = wkt.str();
  std::printf("cell %s\nwkt  %s\n", pt->asString().c_str(), s.c_str());

  struct GeoArrowWKTReader reader; struct GeoArrowWKBWriter writer; struct GeoArrowVisitor v;
  struct GeoArrowError err; struct ArrowArray arr;
  if (GeoArrowWKTReaderInit(&reader) || GeoArrowWKBWriterInit(&writer)) return 1;
  GeoArrowWKBWriterInitVisitor(&writer, &v); v.error = &err;
  struct GeoArrowStringView sv = { s.c_str(), (int64_t)s.size() };
  if (GeoArrowWKTReaderVisit(&reader, sv, &v) != GEOARROW_OK) { std::printf("visit err: %s\n", err.message); return 2; }
  if (GeoArrowWKBWriterFinish(&writer, &arr, &err) != GEOARROW_OK) { std::printf("finish err: %s\n", err.message); return 3; }
  const int32_t* off = (const int32_t*)arr.buffers[1];
  std::printf("geoarrow WKB array: length=%lld, wkb bytes=%d (verts=%d)\n", (long long)arr.length, off[1] - off[0], verts.size());
  arr.release(&arr); GeoArrowWKBWriterReset(&writer); GeoArrowWKTReaderReset(&reader);
  delete pt;
  return 0;
}
