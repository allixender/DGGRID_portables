# DGGRID_portables build notes

running log, newest findings appended per section. prototype build.zig files + harness scripts in `prototype/` (see prototype/README.md), until the real build.zig lands at repo root.

## setup

- 2026-10-02 repo moved out of DGGRIDv9_latest_work (was untracked there, parent repo never saw it -> no cleanup in DGGRID fork needed)
- submodules: `DGGRID` -> sahrk/DGGRID (688940b, v8.44-72, CMake says 9.0), `geoarrow-c` -> geoarrow/geoarrow-c (6f3824e, geoarrow-c-python-0.4.0)
- zig 0.16.0 via zvm (`zvm env --fish | source`)

## context / prior work

- `../zig-builds` (allixender/zig-builds): vendored DGGRID src copy v8.x (295 files) + hardcoded source lists in build.zig -> already 10 files behind upstream v9 (DgHierNdx*, Z3/Z7/ZOrderSystem, OLDSYS/ moved) -> would not link against current master
- `../DGGRIDv9_latest_work/.github/workflows/portables.yml` (CMake, 4 native runners) -> upstream run sahrk/DGGRID 29713254086: linux/macos ok, windows (MSVC) fails
- MSVC failure is NOT math defines, real template issues:
  - C3200 `DgDiscTopoRFS.h:313` -> `DgDiscRFSGrids<DgDiscTopoRF, ...>` in mem-initializer, MSVC resolves `DgDiscTopoRF` as injected-class-name (type) not template -> likely fix `::DgDiscTopoRF` (untested on MSVC)
  - `DgRF.hpp:308` `add == undefAddress()` with A=DgHierNdx, "cannot convert const A to const std::string"
  - clang accepts both -> zig windows-gnu (MinGW) target builds fine
  - worth upstreaming both fixes regardless of zig route (needed for MSVC-ABI libs eg. python wheels)

## prototype build (scratch build.zig)

- single module, glob of `src/lib/{dglib,dgaplib,proj4lib,shapelib}/lib/*.c(pp)` + `src/apps/dggrid/*.cpp`, non-recursive (skips OLDSYS/)
- glob == upstream CMakeLists source lists, exact match all 5 targets -> no hardcoded lists needed, follows upstream automatically
- flags: `-std=c++11 -D_USE_MATH_DEFINES` (c: `-std=c99`), `sanitize_c = .off` unless `-Dubsan=true`
- zig 0.16 API churn: dir access now via `b.graph.io` (`openDir(io, ...)`, `it.next(io)`, `d.close(io)`) -> pin zig version in CI + `minimum_zig_version` in zon
- no GDAL anywhere (DgInGdalFile/DgOutGdalFile compile empty, `#ifdef USE_GDAL`)

### cross-compile from mac host (ReleaseFast), no source patches

| target | result |
|---|---|
| native aarch64-macos | ok, ca 25s on 5 cores, 2.3 MB |
| x86_64-macos.11.0 | ok |
| x86_64-linux-musl | ok, static |
| aarch64-linux-musl | ok, static |
| x86_64-linux-gnu.2.17 | ok, dynamic glibc |
| x86_64-windows-gnu | ok (.exe + .pdb) |
| aarch64-windows-gnu | ok (.exe + .pdb) |

windows binaries NOT run yet (no wine/runner) -> need windows-latest / windows-11-arm test job

### example regression (examples/examplesNoGDAL.lst, 32 examples)

- harness: run each `<ex>.meta`, diff outputfiles vs `examples/sampleOutput/<ex>`, numeric compare per token
- all 32 rc=0 on mac arm64 native + x86_64 (rosetta)
- zero integer / cell-ID diffs vs sampleOutput, both arches
- diffs are: last printed digit (1e-6/1e-7 at 7 decimals), `-0.0000000` vs `0.0000000`, .prj radius digits (`...474682` vs `...475000`), shp/shx binary (bbox doubles)
- `z3CellClip` line count 4108 vs 4076, identical on both arches -> sampleOutput stale upstream, not a build issue
- `zNums` x86_64: north pole vertex lon -179.1 vs 0.0 at lat 90 -> same point, degenerate, breaks byte diff only
- arm64 vs x86_64 directly: 2 lines in 95k differ (1e-6) + the pole thing
- sampleOutput .prj digits match x86 -> reference generated with x87 80-bit long double
- upstream `doexamples*.sh` uses `diff -r` -> will "fail" on any non-x86 build -> our CI needs tolerance diff

### long double per target (556 uses in dglib headers)

| target | LDBL_MANT_DIG |
|---|---|
| aarch64-macos, aarch64-windows, MSVC | 53 (= double) |
| all x86_64 (linux, macos, mingw) | 64 (x87) |
| aarch64-linux | 113 (soft-float quad) |

-> last-digit output differences across platforms are by design, not a bug
-> `-mlong-double-64` rejected by clang on aarch64-linux, no flag fix; real fix only an upstream precision typedef

### UBSan

- `-Dubsan=true` (sanitize_c trap) + ReleaseSafe: 32/32 examples, no traps
- still: ship ReleaseFast, keep a UBSan job in CI (ReleaseSafe would SIGILL on any UB in user data)

### performance (mac arm64, examples, 5 runs avg)

| build | determineRes | isea7hGen | size |
|---|---|---|---|
| ReleaseFast | 0.161s | 0.229s | 2.3 MB |
| ReleaseSafe | 0.227s | 0.231s | 2.3 MB |
| ReleaseFast + `-fno-inline -fno-eliminate-unused-debug-types` (old zig-builds flags) | 0.254s | 0.259s | 3.3 MB |

-> drop the old debug-ish flags

aarch64-linux-musl in podman VM (applehv, same M-series) vs mac native:
- determineRes 5.95s vs 0.17s, igeo7WholeEarth 3.23s vs 0.08s, isea7hGen 9.74s vs 0.22s -> 35-45x
- microbench in same VM: long double 7x slower than double, double itself ca 13x slower than mac (VM + musl libm)
- decision 2026-10-02: aarch64-linux low priority, mostly linux containers on arm macs -> native mac binary is the fast alternative there. caveat: graviton / ampere / raspi users have no faster alternative (x86 emulation worse)

## geoarrow-c

- goal (future): DGGRID as library, fast in-memory / arrow IO without GDAL -> esp. for the portables
- `../zig-builds/geoarrow-c/build.zig`: hardcoded `/Users/akmoch/micromamba/...` arrow path in test target, test_case broken against zig libc++ (`std::char_traits<unsigned char>`)
- first step: get libgeoarrow (C99 + bundled nanoarrow) compiling for all targets in the same build.zig, link test later

### 2026-10-02 libgeoarrow + libdglib prototype (`prototype/lib-geoarrow-smoke/`)

- libgeoarrow.a from submodule src directly, no CMake: 17 C sources (= CMake GEOARROW_SOURCES) + double_print.c + ryu/d2s.c + double_parse_fast_float.cc (c++11) + vendor/nanoarrow/nanoarrow.c
- `geoarrow_config.h` via zig `addConfigHeader(.{ .style = .cmake })` from `geoarrow_config.h.in` (version 0.2.0-SNAPSHOT, fast_float + ryu on)
- namespaced: `GEOARROW_NAMESPACE DgGeoArrow`, `NANOARROW_NAMESPACE=DgGeoArrowNanoarrow` -> no symbol clash if later linked next to pyarrow/other nanoarrow copies
- libdglib.a = dglib + proj4lib + shapelib (no dgaplib, no apps), sorted glob
- smoke.cpp: ISEA7H res 5 cell around Tartu (`ISEA7H05{q04:(42, 336)}`) -> setVertices -> WKT -> GeoArrowWKTReader -> GeoArrowWKBWriter -> ArrowArray, length=1, 125 WKB bytes (7-pt ring, correct)
- builds all 6 targets (linux musl x86_64/aarch64, linux gnu.2.17, macos x86_64, windows gnu x86_64/aarch64) -> `.a` / `.lib`
- smoke runs identical on mac arm64, rosetta x86_64, karula musl, centos:7 gnu.2.17
- not touched: geoarrow-c's own tests (gtest + arrow C++), `hpp/` C++ API, fast_float off fallback
- -> link path DGGRID lib + geoarrow proven, next would be a DgOutGeoArrow-ish writer or a C API on top of dglib (no file IO)

## karula (fedora 44, i9-14900K, 32 threads, gcc 16.2.1, cmake 4.3, podman 5.8.4)

test dir `karula:/home/akmoch/dev/build/DGGRID_portable_tests` (DGGRID src copy, zig 0.16.0 tarball unpacked locally, build-cmake/, zigproj/, exwork/, ref-gcc/)

### builds

- upstream CMake `-DWITH_GDAL=OFF` + gcc 16: ok, 12s at -j32, 2.4 MB
- zig 0.16 linux host, 7 targets in parallel (x86_64/aarch64 linux musl, gnu.2.17, x86_64/aarch64 macos.11.0, x86_64/aarch64 windows-gnu): all ok, 74s total -> one ubuntu runner can build all release artefacts
- mac-host vs linux-host zig builds NOT byte-identical, also after strip (.text 0x12f51a vs 0x12edca) -> likely unsorted dir glob (APFS vs linux iteration order -> link order) -> sort source list (done in lib-geoarrow-smoke), recheck reproducibility
- unstripped 2.3 MB -> stripped 1.6 MB -> release with `.strip = true`

### example regression x86_64 linux native

- cmake-gcc, zig-musl, zig-gnu217: all 32 rc=0, and ALL THREE fail the same 16 vs sampleOutput -> sampleOutput doesn't even match upstream's own native gcc build -> useless as byte oracle
- zig-gnu217 vs cmake-gcc: zero diffs, 32/32
- zig-musl vs cmake-gcc: mixedAperture/mixedPts.kml 12 of 107k lines at 1e-5 + superfundGrid/orgrid_2.shp binary -> musl/zig libm vs glibc libm
- -> regression oracle for CI: native gcc build on x86_64 linux (or a pinned zig-gnu output), tolerance compare, not upstream sampleOutput

### performance karula (10 runs avg)

| example | gcc (glibc) | zig gnu.2.17 | zig musl static |
|---|---|---|---|
| determineRes | 0.180s | 0.236s | 0.145s |
| isea7hGen | 0.262s | 0.350s | 0.204s |
| mixedAperture | 1.033s | 1.390s | 0.747s |
| igeo7WholeEarth | 0.083s | 0.109s | 0.068s |
| superfundGrid | 0.414s | 0.438s | 0.465s |

- zig musl fastest in 4/5 (20-30% faster than gcc), zig gnu ca 30% slower than gcc
- glibc target version irrelevant (2.17/2.28/2.34 same speed, same libm symbol versions) -> my first guess wrong
- perf mixedAperture zig-gnu: 65% in glibc long double trig (`__kernel_rem_pio2` 39%, `__kernel_cosl`, `__kernel_sinl`, `__acosl_finite`) -> `snyderInv` (ISEA projection) hot path
- perf zig-musl: zig 0.16 ships own compiler_rt `rem_pio2l` + own allocator (`heap.SmpAllocator`, `c.malloc`) -> cheaper trig, but malloc/free ca 38% -> DGGRID very allocation heavy
- gcc faster than zig-gnu on same glibc -> probably gcc sincosl fusion / libstdc++ vs libc++, not chased
- -> long double is THE cost on x86_64 too, not only aarch64-linux. upstream precision typedef would help everywhere
- -> linux release artefact: static musl (fastest, runs everywhere incl alpine)

### distro matrix (podman on karula, isea7hGen, compared to gcc ref)

| image | zig musl | zig gnu.2.17 |
|---|---|---|
| ubuntu:16.04 / 18.04 / 20.04 / 24.04 | ok, 0 diff | ok, 0 diff |
| centos:7 (glibc 2.17) | ok, 0 diff | ok, 0 diff |
| alpine:latest | ok, 0 diff | n/a (no glibc, expected) |

- podman on fedora runs ubuntu images fine -> "ubuntu thing" = `podman run docker.io/library/ubuntu:24.04 ...`, also ok for running the GH workflow locally with `act` (podman socket) if ever needed

## 2026-10-02 repo + CI (github.com/allixender/DGGRID_portables, public, AGPL-3.0)

- scope decision: base dggrid binaries first, geoarrow/lib prototype stays in `prototype/` (review later, once CI/CD runs)
- root `build.zig`: dggrid exe only, sorted non-recursive globs over `DGGRID/src`, `-Dubsan`, `-Dstrip`, `zig build release` -> `zig-out/release/<platform>/dggrid[.exe]`, ReleaseFast + strip, no pdb
- release matrix: linux-x86_64 / linux-arm64 (musl static), macos-x86_64 / macos-arm64 (11.0), windows-x86_64 / windows-arm64 (gnu/MinGW). gnu.2.17 dropped (musl faster + runs everywhere)
- `zig build release` mac M-series: 2:02 for 6 targets, binaries 1.6-1.9 MB
- reproducibility: mac host vs karula, sorted globs + strip -> all 6 release binaries byte-identical (sha256) -> fixed
- `ci/run_examples.sh <exe> <workdir>`: examplesNoGDAL, fails on rc!=0 or missing output file vs sampleOutput listing, md table to step summary. `nullglob` needed: dymaxionIcosa has no sampleOutput dir at all -> rc check only
- `ci/compare_outputs.py <workdir> [ref]`: numeric compare, informational only (sampleOutput not a valid oracle, see karula section)
- `.github/workflows/build.yml`:
  - build (ubuntu-24.04): `zig build release`, llvm-lipo -> macos-universal, package `dggrid-<platform>.tar.gz|zip` (dir `dggrid-<ver>-<platform>/` with dggrid, LICENSE, BUILDINFO.txt), SHA256SUMS
  - asset names without version -> stable URLs `releases/download/edge/dggrid-linux-x86_64.tar.gz`
  - ubsan (ubuntu): ReleaseSafe + `-Dubsan=true`, all examples
  - test matrix on native runners from the packaged archives: ubuntu-24.04, ubuntu-24.04-arm, macos-15 (arm64 + universal), macos-15-intel (x86_64 + universal), windows-2025, windows-11-arm. windows: `core.autocrlf false` before checkout (CRLF .meta files otherwise)
  - publish: push main -> rolling `edge` pre-release (delete + recreate), tag `v*` -> release, `-` in tag -> pre-release
- `.github/workflows/watchdog.yml`: daily 05:17 UTC + manual, `git ls-remote` sahrk master vs pinned submodule -> branch `watchdog/dggrid-<sha10>` + PR with upstream commit list -> `gh workflow run build.yml --ref <branch>` (GITHUB_TOKEN PRs don't trigger workflows). needs repo setting "Allow GitHub Actions to create and approve pull requests"
- action versions pinned to majors as of 2026-10: checkout@v7, upload-artifact@v7, download-artifact@v8, setup-zig@v2
- windows deep testing: separate, claude agent on a windows host with this file as context

## open / next

- regression oracle = native gcc linux output, not sampleOutput (step 4, not in CI yet)
- macos gatekeeper / notarisation (cf. CODESIGNING.md in fork)
- universal macos binary: in build.yml via llvm-lipo, verify on runners
- windows binaries: first execution in CI test matrix, deeper tests via agent on windows host
- upstream: MSVC fixes (`::DgDiscTopoRF`, DgRF.hpp:308), precision typedef for long double (perf everywhere + aarch64-linux)
- geoarrow: C API / writer on top of libdglib + libgeoarrow
