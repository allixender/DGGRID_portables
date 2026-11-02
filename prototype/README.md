prototypes, see ../build_notes.md (2026-10-02 + 2026-11-02 sessions)

- `lib/` -> library build on DGGRID 9.1: C API for the IGEO7v2 / IGEO7v1 / IVEA7HL / IVEA7HS presets (`include/dggrid.h`, dggrid.zig over dgcore.cpp) + Arrow / GeoArrow (`include/dggrid_arrow.h`, dgarrow.c) as shared lib + wasm reactor, from a patched plain source copy (`lib/setup_src.sh`, `.src/` gitignored), prototype-only patch (fatal hook) + `dgreal` typedef rewrite (`-Ddgreal=double`). see `lib/README.md`
- `wasm/` -> `dggrid.mjs` JS wrapper for dggrid.wasm, `test.mjs`, wasm32-wasi findings (`NOTES.md`), `run.mjs` node WASI runner for command modules
- `dggrid-exe/build.zig` -> first scratch dggrid exe build, superseded by the root build.zig (expects `src -> ../../DGGRID/src` symlink, unsorted glob)
- `scripts/runex.sh`, `scripts/numdiff.py` -> superseded by `ci/run_examples.sh`, `ci/compare_outputs.py`
