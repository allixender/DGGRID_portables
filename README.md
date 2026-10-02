# DGGRID_portables

Portable, GDAL-free [DGGRID](https://github.com/sahrk/DGGRID) binaries for Linux, macOS and Windows (x86_64 + aarch64), cross-compiled with [Zig](https://ziglang.org) 0.16.

This repo wraps upstream `sahrk/DGGRID` as a git submodule and does not modify its sources. It adds a Zig build, CI and release packaging. [geoarrow-c](https://github.com/geoarrow/geoarrow-c) is included as a submodule for future library builds (Arrow/GeoArrow output without GDAL).

Status: prototype. See `build_notes.md` for findings and `prototype/` for the current build experiments.

```bash
git clone --recursive git@github.com:allixender/DGGRID_portables.git
```

## License

AGPL-3.0, same as DGGRID. Release binaries contain DGGRID and are distributed under its AGPL-3.0 license.
