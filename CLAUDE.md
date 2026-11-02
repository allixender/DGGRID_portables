# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Portable, GDAL-free DGGRID binaries (Linux musl static, macOS 11.0+, Windows MinGW; x86_64 + arm64), cross-compiled with Zig 0.16.0 from upstream `sahrk/DGGRID` as a git submodule. The repo adds a Zig build, CI, release packaging and a small set of patches. **Never edit files under `DGGRID/` directly.** Fixes go into `patches/` (see below). `geoarrow-c/` is a second submodule that only `prototype/` uses.

`build_notes.md` is the running engineering log, with the findings behind every build choice (targets, flags, long double behaviour per platform, Windows printf bugs, perf, CI history) and an "open / next" list at the end. Read the relevant section before changing build flags or CI. Append new findings to the matching section in the same terse style. `todo_notes.md` is gitignored and local-only.

## Commands

```bash
git submodule update --init           # required, build.zig globs DGGRID/src
ci/apply_patches.sh                   # apply patches/*.patch to the submodule (idempotent); skip it and you build plain upstream
ci/use_line.sh --reset v8.44          # submodule -> another upstream line's pinned commit + its patches (needs jq); back with `--reset master`
zig build -Doptimize=ReleaseFast      # host binary -> zig-out/bin/dggrid
zig build -Dtarget=x86_64-windows-gnu # cross-compile one target
zig build release                     # all 6 release targets, ReleaseFast + stripped -> zig-out/release/<platform>/
zig build -Doptimize=ReleaseSafe -Dubsan=true   # UBSan trap mode (CI check, not for shipping)
zig build run -- path/to/file.meta    # run dggrid

ci/run_examples.sh zig-out/bin/dggrid /tmp/dggrid-examples   # all examplesNoGDALorH3 of the checked-out line (39 on 9.1); fails on rc!=0 or missing output files
python3 ci/compare_outputs.py /tmp/dggrid-examples [refdir]  # numeric tolerance compare, informational only (always exit 0)
```

To run a single example, cd into `DGGRID/examples/<name>` (or a scratch copy, since outputs land in `outputfiles/`) and run `dggrid <name>.meta`.

## Architecture

- **`build.zig`**: a single exe module. Sources are globbed (sorted, non-recursive) from `DGGRID/src/lib/{dglib,dgaplib,proj4lib,shapelib}/lib` and `DGGRID/src/apps/dggrid`, which exactly matches upstream's CMakeLists, so submodule bumps need no build edits. The globs must stay sorted, because sorting makes the release binaries byte-identical across mac and linux hosts. Flags: `-std=c++11 -D_USE_MATH_DEFINES` / `-std=c99`. The release matrix lives in `release_targets`. Zig 0.16 API: directory access goes through `b.graph.io`.
- **Windows x86_64 only**: `__USE_MINGW_ANSI_STDIO=1` plus `src/mingw_ldouble_numput.cpp`, a `num_put<char>` facet installed as the global locale. Zig's prebuilt libc++ for MinGW routes `ostream << long double` through UCRT, which misreads 80-bit x87 long doubles. Remove the facet once zig fixes its libc++ flags.
- **`patches/NNNN-*.patch`**: `git format-patch` files against the pinned submodule commit. They are meant for upstream, and there are no fork branches. `ci/apply_patches.sh` applies each patch, skips it if it is already present (for example, merged upstream), and fails if it neither applies nor is present. That failure is the signal to refresh a patch after a submodule bump. Delete a patch once the script reports "already present" after a bump. `.gitattributes` keeps `*.patch` byte-exact (`-text`) and `*.sh` as LF.
- **Upstream lines (`upstream.json`)**: the build follows several upstream refs, one row per line: `master` (release `edge`), the tags `v9.1` and legacy `v8.44` (fixed releases of the same name), a dev branch gets its own rolling row when there is one (none right now). Each row has the upstream ref, the pinned `sha`, the patch dir and the release name. `"sha": null` means the submodule gitlink, which is the pin of the default line `master`. `build.zig` is the same for every line, only the patches differ: `patches/*.patch` is master's set, `patches/<line>/` belongs to the other lines. Keep one row per text line, because the watchdog bumps the sha with sed. `ci/use_line.sh` moves the submodule away from the gitlink; never commit that state.
- **CI (`.github/workflows/`)**:
  - `build.yml`: the entry point with the triggers. `ci/plan_lines.sh` picks the lines for the event, then `line.yml` runs once per line (matrix over a reusable workflow), so one red line does not block the others.
  - `line.yml`: one ubuntu job cross-builds every target with `zig build release`, makes `macos-universal` with llvm-lipo, and packages `dggrid-<platform>.tar.gz|zip` with `BUILDINFO.txt` and `SHA256SUMS`. Native test runners then run the examples from the packaged archives, alongside a UBSan job. Artifacts are `dist-<line>` and `outputs-<line>-<platform>-<runner>`.
  - Per event: a pull request runs master in full and the other lines build-only (patches apply, all targets cross-compile). A push to main runs the rolling lines in full and recreates their pre-releases (`edge`). A tag `vX` or `vX-rN` here publishes the fixed line with release `vX` (`-rN` is a rebuild of the same upstream version); fixed releases are never replaced and never marked "Latest". `workflow_dispatch` runs everything in full without publishing, and its `line` input limits it to one line.
  - Asset names carry no version, so download URLs stay stable per release.
  - `**.md` and `prototype/**` are paths-ignored.
  - `watchdog.yml`: runs daily and loops over the rolling lines. When an upstream branch moves, it opens a PR that bumps the pin (gitlink for master, `sha` in `upstream.json` otherwise), then dispatches `build.yml` for that line on the branch, because PRs created with GITHUB_TOKEN don't trigger workflows.
  - `precision.yml`: the long double libm probe (`ci/precision/`). It runs manually or on a push to `probe/**`, and never publishes.
- **`prototype/`**: experiments that are not part of the release build.
  - `prototype/lib/` is the library build (libdglib + namespaced libgeoarrow, also wasm32-wasi). It works on its own patched plain copy of the sources, `prototype/lib/.src/` (gitignored), created by `prototype/lib/setup_src.sh`.
  - That copy gets `patches/*`, then the prototype-only `prototype/lib/patches/*.patch`, then the `dgreal.py` rewrite (`long double` -> `dgreal` typedef, `-Ddgreal=double`).
  - C API: 9.1 presets IGEO7v2 (default), IGEO7v1, IVEA7HL, IVEA7HS + Z7 ids, point <-> cell, centroid, boundary. `check_cli.py` compares it against the root build's CLI.
  - Never apply prototype patches to the `DGGRID/` submodule. `ci/apply_patches.sh <src-dir> <patch-dir>...` targets other trees.
  - Findings: `prototype/lib/README.md`, `prototype/wasm/NOTES.md`.

## Testing caveats

- Upstream `examples/sampleOutput` is **not** a valid byte oracle. It was generated with x87 80-bit long double, and it doesn't even match upstream's own gcc build. Last-digit float differences across platforms are expected, because `LDBL_MANT_DIG` is 64 on x86_64, 53 on aarch64 macOS/Windows and 113 (software quad) on aarch64 Linux. Integer, cell ID and topology differences are real bugs.
- A return code of 0 is not enough. The Windows x86_64 zero-coordinate bug passed every rc-only check. Compare values across platforms using the `outputs-<line>-<platform>-<runner>` CI artifacts (`gh run download`).
- Known open issue: Windows arm64 prints `%LF` with wrong rounding (UCRT printf, not libm). It is parked, and the edge release notes list it.
- Known open issue: `macos-x86_64` under Rosetta dies on every WGS84 preset (IGEO7, IGEO7v2, *L), `inverse did not converge`. Native Intel is fine, so CI is green. See build_notes.md, 2026-11-02.
- On Windows checkouts, use `core.autocrlf false`, otherwise the CRLF `.meta` files and scripts break.
