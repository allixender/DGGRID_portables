prototypes from 2026-10-02 session, see ../build_notes.md

- `dggrid-exe/build.zig` -> dggrid exe, glob over src (expects `src -> ../../DGGRID/src` symlink), unsorted glob (fixed in lib-geoarrow-smoke)
- `lib-geoarrow-smoke/` -> libdglib.a + libgeoarrow.a + smoke exe (expects `dg -> ../../DGGRID/src`, `ga -> ../../geoarrow-c/src`), `zig build smoke`
- `scripts/runex.sh` -> examplesNoGDAL runner (env EXE, WORK, SRC), `scripts/numdiff.py <outroot> <refroot>` -> numeric tolerance compare

setup: `cd dggrid-exe && ln -s ../../DGGRID/src src`, `cd lib-geoarrow-smoke && ln -s ../../DGGRID/src dg && ln -s ../../geoarrow-c/src ga`
