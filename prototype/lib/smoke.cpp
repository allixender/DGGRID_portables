// smoke test: DGGRID library (no file IO) -> IGEO7v2 cell polygon (WGS84) -> GeoArrow WKB array
#include <cstdio>
#include <sstream>
#include <iomanip>
#include <string>
#include <dglib/DgAuthalicConverter.h>
#include <dglib/DgIDGGS7H.h>
#include <dglib/DgGeoSphRF.h>
#include <dglib/DgPolygon.h>
#include "geoarrow/geoarrow.h"

int main() {
  DgRFNetwork net0;
  const DgGeoSphRF& geoRF = *(DgGeoSphRF::makeRF(net0, "GS0"));
  DgGeoCoord vert0(11.20, M_ICOSA_VERT0_LAT_DEG, false);  // ISEAL orientation
  const DgIDGGS7H& idggs = *DgIDGGS7H::makeRF(net0, geoRF, vert0, 0.0, 10);
  const DgIDGG& dgg = idggs.idgg(5);

  // Tartu -> cell -> boundary
  DgGeoCoord tartu(26.7290, 58.3780, false);  // geodetic -> authalic latitude
  tartu.setLat(DgAuthalic::geodeticToAuthalicLatitude(tartu.lat()));
  DgLocation* pt = geoRF.makeLocation(tartu);
  dgg.convert(pt);
  DgPolygon verts;
  dgg.setVertices(*pt, verts, 0);

  std::ostringstream wkt; wkt << std::setprecision(10) << "POLYGON ((";
  for (int i = 0; i <= verts.size(); i++) {
    const DgGeoCoord& c = *geoRF.getAddress(verts[i % verts.size()]);
    wkt << (i ? ", " : "") << c.lonDegs() << " " << DgAuthalic::authalicToGeodeticLatitude(c.lat()) * M_180_PI;
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
