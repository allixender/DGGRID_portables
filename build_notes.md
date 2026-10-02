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
- test jobs upload example outputs as artifacts `outputs-<platform>-<runner>` (14 days) -> `gh run download <id> -n ...` for cross-platform diffs

### first CI runs (PR #1, runs 37007898855 / 37008932160 / 37009571304)

- run 1: all non-windows test jobs failed in my unpack step: `ls unpacked/*/dggrid unpacked/*/dggrid.exe` under the runner's `bash -e -o pipefail` -> exit 2 when one glob misses. windows passed only because MSYS resolves `dggrid` -> `dggrid.exe`. fixed with a `[ -f ]` loop
- run 2: all green: build 7m47s (zig release on ubuntu, mostly zig cache cold), ubsan ok, 8 native test jobs 32/32 examples rc=0 incl. both macos-universal slices, linux-arm64 native runner ok
- BUT rc=0 is not enough on windows, value compare from the uploaded outputs:

#### windows-x86_64 (windows-2025): long double printing broken

- every `%LF` value printed as `0.0000000` (KML/GeoJSON/gen coords, .prj radius 0.000000000000), param echo `dggs_vert0_lon 3.30407e-312` (= pointer bits read as double)
- cause: zig's MinGW headers -> `__USE_MINGW_ANSI_STDIO=0` (UCRT, `__MSVCRT_VERSION__ >= 0xE00`, clang doesn't define `_GNU_SOURCE` for mingw C++) -> UCRT `snprintf` reads `%Lf` as 64-bit double, but MinGW x86_64 long double is 80-bit x87 (passed by reference in Win64 varargs) -> garbage/0
- fix (build.zig, x86_64 windows only): `__USE_MINGW_ANSI_STDIO=1` -> mingw-w64's own printf handles 80-bit. run 3: 56 output files identical to linux-x86_64 (modulo CRLF) -> parsing + computation were always fine, only printing broken
- still broken: `ostream << long double` inside libc++ (zig-built, our defines don't reach it) -> param echo `4.72715e-312`, .prj radius (`DgOutShapefile.cpp:141`, `prjFile << std::fixed << earthRadiusM`), superfundGrid .shp differs (not chased). looks like zig/libc++-on-mingw-ucrt bug -> check llvm-mingw behaviour, report to zig? workaround options: custom num_put, or upstream printf instead of ostream for long double
- windows-arm64 (windows-11-arm): printing ok (long double == double, UCRT `%Lf` matches)

#### windows-arm64: precision ca 1e-5 deg vs macos-arm64

- same LDBL width (53) as macos-arm64, but 23 files differ: up to 6e-5 deg (ca 6.7 m) in isea7hGen/determineRes/igeo7, plus ±0 and pole-lon (39.88 deg) artefacts
- clip examples select different cells: z3CellClip 4140 lines (win-arm64) vs 4108 (mac/linux) vs 4076 (sampleOutput), zCellClip 4172 vs 4140
- integer outputs (mixed.chd/.nbr) identical -> topology fine, float math less accurate -> suspect mingw-w64 arm64 libm (`sinl`/`cosl`/`acosl`/`atan2l` generic implementations?) -> microbench per function vs macOS at %.17g = first task for windows-host agent

#### upstream bug: GeoJSON trailing comma on windows

- `DgOutGeoJSONFile.cpp:72-73`: `seekp(tellp() - 2)` to drop trailing `,\n`, but `DgOutputStream::open` uses text mode (`std::ios::out`) -> on windows `\n` = `\r\n` -> comma stays -> `}},]}` = invalid GeoJSON (both windows targets)
- fix upstream: `std::ios::out | std::ios::binary` in `DgOutputStream.cpp:65` -> also LF everywhere = byte-identical outputs across OSes. candidate for first upstream PR (with MSVC fixes)

### 2026-10-02 merged PR #1 -> first edge pre-release

- https://github.com/allixender/DGGRID_portables/releases/tag/edge, "edge: DGGRID 9.0b @ 688940b", 7 archives 0.6-1.2 MB + SHA256SUMS, release notes carry windows known issues
- public download of macos-universal checked: both slices, runs, BUILDINFO ok
- watchdog manual run: pinned == upstream 688940b -> "up to date". PR-creation path untested until sahrk master moves
- build.yml: `paths-ignore` `**.md` + `prototype/**` -> notes-only pushes don't rebuild/republish edge (tags still always build)

## 2026-10-02 windows host session (Win10 x64, zig 0.16.0 x86_64-windows)

host: no gcc/clang/MSYS toolchain, no arm64 execution (Win10 x64, no emulation) -> arm64 only statically + via CI. WSL Ubuntu used to run the linux-x86_64 musl build as exact oracle. checkout gotcha: global `core.autocrlf=true` here -> repo scripts CRLF in the worktree, `bash ci/run_examples.sh` under WSL fails (`syntax error near '}'`), git-bash fine. submodules were not initialised on this clone (`git submodule update --init`)

### windows-x86_64 `ostream << long double`: root cause + workaround (DONE)

- minimal repro (zig c++ -target x86_64-windows-gnu): `cout << 6371007.18L` -> `2.11863e-312`, also `std::fixed`, `ostringstream`, `std::to_string(long double)`. with AND without `-D__USE_MINGW_ANSI_STDIO=1` (that only fixes our own `snprintf("%Lf")`). `istream >> long double` fine
- path: `num_put<char>::do_put(long double)` -> `__do_put_floating_point(..., "L")` -> `__locale::__snprintf` (libcxx/src/support/win32/locale_win32.cpp) -> on MinGW (`_LIBCPP_MSVCRT` only for real MSVC) `std::vsnprintf` -> compiled by zig WITHOUT `__USE_MINGW_ANSI_STDIO` -> UCRT `__stdio_common_vsprintf`, reads 80-bit `%Lg` arg as 64-bit double
- llvm-mingw 20260922 (clang 23.1.2, ucrt-x86_64): same test prints correctly, w/ and w/o the define. its `build-libcxx.sh` adds `-D__USE_MINGW_ANSI_STDIO=1` for i686/x86_64 ("Force using the mingw stdio functions, for correct long double printing"), `nm libc++.a` -> locale_win32.obj imports `__mingw_vsnprintf`, string.obj `__mingw_snprintf`
- -> zig bug: `src/libs/libcxx.zig` (zig master as of today too) adds no such flag. fix for zig = one line in the libcxx cflags loop: `if (target.isMinGW() and target.cpu.arch.isX86()) try cflags.append("-D__USE_MINGW_ANSI_STDIO=1");`. no existing issue found (quick search) -> TODO report on codeberg ziglang/zig with the repro above
- workaround here: `src/mingw_ldouble_numput.cpp`, only linked for windows x86_64 (build.zig). static init installs a `num_put<char>` facet as global locale + imbues cout/cerr/clog; long double overload formats via `__mingw_snprintf`, same conversion selection / fill / width / adjustfield / decimal point as libc++. every stream DGGRID creates afterwards inherits it (DGGRID never touches locales)
- conformance: 13 values (incl. ±0, 1e-312, 1e4000L, LDBL_MAX) x 4 floatfields x 5 flag sets x 4 adjustfields x 5 precisions x 2 widths = 10402 lines, zig+shim vs llvm-mingw byte-identical (first attempt had 175 diffs: libc++ internal-pads after a sign, else after `0x`)
- not covered: `std::to_string(long double)` (libc++ calls snprintf directly, no facet). DGGRID's `dgg::util::to_string` uses ostringstream -> covered
- dggrid.exe (ReleaseFast, native windows-2025-like host): 32/32 examples rc=0, `.prj` `6371007.180918475000` (= x86 sampleOutput), param echo `dggs_vert0_lon 11.25`, no `e-31x` left anywhere
- vs linux-x86_64 musl (same commit, run in WSL): all text outputs identical (modulo CRLF, see GeoJSON below). superfundGrid .shp: 18 doubles differ by exactly 1 ulp (lat only, e.g. `42.6060412921882` vs `42.606041292188195`) -> mingw x87 libm vs musl, harmless, not printing

### windows-arm64 precision: libm provenance (static analysis, run pending)

- probe `ci/precision/ldmath.cpp`: sinl/cosl/tanl/atanl/sqrtl/asinl/acosl/atan2l/powl on ~40 fixed + 300 xorshift inputs each (incl. acos/asin in [1-1e-6, 1], snyderInv territory), inputs exact doubles widened to long double, printed `(double)` at %.17g + %a. `ci/precision/ldmath_compare.py out.txt [other.txt]` -> ulp error vs mpmath correctly rounded double, + ulp diff vs a second platform
- first version used `0.1L`-style literals -> on x87 the input != printed double -> bogus "1.0 rel error" near zeros of sin. fixed: double inputs only
- PE imports of the aarch64-windows-gnu probe (pefile): `api-ms-win-crt-math`: `acos asin atan atan2 pow` -> on arm64 mingw these `*l` are aliases to UCRT double functions (`F_LD64(acosl == acos)` in mingw def-include/crt-aliases.def.in). `sinl cosl tanl sqrtl` NOT imported -> zig compiler_rt (`sinl` -> musl `sin` when long double is 64-bit). strtold = mingw gdtoa `__mingw_strtod` (correct)
- x86_64-windows-gnu probe locally: all functions <= 1 ulp except `acosl` near 1 (2e5 ulp at x=1-1e-10, i.e. ~7e-16 rad absolute) -> mingw x87 `acosl = atanl(sqrtl(1-x^2)/x)` cancellation, harmless. `sscanf %Lf` = 0 without the ANSI define (expected, build.zig sets it)
- release dggrid.exe imports from api-ms-win-crt-math: arm64 `acos asin atan atan2 pow llrintl lround`, x86_64 only `acos asin atan2 lround` (DGGRID's few plain-double calls; the 15 acosl / 11 asinl / 13 atan2l / 9 atanl uses are mingw x87 code there, UCRT on arm64)
- -> suspects for win-arm64: Microsoft's arm64 UCRT `acos/asin/atan2/pow` (the only functions that differ in provenance from linux/mac). 6e-5 deg ~ 1e-6 rad is far beyond any 1-ulp libm noise (mac vs linux differences are ~1e-14), would need float-ish precision in one of them
- `.github/workflows/precision.yml` (manual or push to `probe/**`, never publishes): cross-builds the probe on ubuntu, runs on windows-11-arm (+ MSVC `cl` arm64 build as UCRT cross-check), windows-2025 (with/without ANSI define), macos-15, macos-15-intel, ubuntu x86_64/arm64, compares vs mpmath + win-arm64 vs mac-arm64 in the step summary
- run 1 (37028962223, push probe/ldmath): all 7 runner jobs ok incl MSVC arm64, compare job failed: system `pip install` blocked by PEP 668 on ubuntu-24.04 -> venv, re-pushed (47e1c98). results -> next session
- if UCRT confirmed: workaround = link own acos/asin/atan2/pow for aarch64-windows (e.g. compile musl/compiler_rt versions under the `*l` names or `-Wl,--defsym`), keeps UCRT for the rest

#### 2026-10-02 probe results (run 37030431165, desktop session) -> NOT libm, it's UCRT printf rounding

- compare job failed again (win-arm64 vs mac-arm64 step: a filename ends up in a number field in `ldmath_compare.py load()`), but per-platform `.cmp` vs mpmath complete in artifact `ldmath-compare`
- worst ulp vs correctly rounded double: win-arm64 gnu AND msvc: all <= 1 ulp (sinl/cosl/tanl/atanl/asinl/acosl/atan2l), powl/sqrtl 0. mac-arm64 <= 2 (tanl). linux musl x86_64/arm64 <= 1
- win-arm64 vs mac-arm64 raw: 384/3696 rows differ, max rel 3.4e-16 (1-2 ulp) -> UCRT acos/asin/atan2/pow suspicion refuted, own-libm workaround NOT needed
- x87 outliers harmless: macos-intel `tanl` 2.7e11 ulp at x=1.5707963267948966 (pole) and 1.6e11 at 2pi (fsin/fptan 66-bit pi), win-x86_64 `acosl` 2e5 ulp at 1-1e-10 (abs ~7e-16 rad)
- snyderInv Newton loop tolerance `PRECISION 5e-13` rad (DgEllipsoidRF.h:382) -> can't amplify to 1e-5 deg either
- actual cause, from example outputs (run 37008932160): 1920/1943 differing numbers in isea7hGen differ by exactly 1 in the LAST PRINTED digit (precision 5 there, eg `-2.46119` vs `-2.46120`)
- arbitration vs linux-x86_64 (80-bit, most precise): in ALL 17290 disagreements (isea7hGen, determineRes, igeo7WholeEarth) linux agrees with mac-arm64, never with win-arm64 -> UCRT `%LF` rounding on arm64 is wrong (looks like rounding from 17 sig digits / double rounding)
- -> fix candidate: `__USE_MINGW_ANSI_STDIO=1` + `src/mingw_ldouble_numput.cpp` also for aarch64-windows (check mingw pformat with long double == double), target: win-arm64 byte-identical to mac-arm64
- open: z3CellClip/zCellClip cell count differs on win-arm64 (4140 vs 4108 lines) -> recheck after printf fix, may be a separate cause
- 6fd86dd check (run 37031525334): win-x86_64 vs linux-x86_64 byte-identical 63/66 (binary-mode patch -> no CRLF), 3 superfundGrid .shp differ in 6 bytes (1 ulp doubles, eg 42.6060412921882 vs 42.606041292188195), GeoJSON valid JSON, param echo `11.25`. win-arm64 vs mac-arm64 still 26 files differ (fixes are x86_64-only)

- 2026-10-02 evening: probe compare fixed on probe/ldmath (769b121, `*.txt` pattern; `load()` skips `#` lines), run 37034716985 green end to end -> win-arm64 vs mac-arm64: 384/3696 rows differ, max 2 ulp -> confirms analysis above, libm not the cause
- arm64 printf fix PARKED (decision 2026-10-02). edge release notes keep the win-arm64 known issue
- windows host local main checkout: binary-mode patch still applied in submodule (`m DGGRID` / -dirty), harmless, apply_patches.sh handles it

### upstream fix: binary-mode output streams (DONE locally, patch ready)

- `patches/0001-output-streams-binary-mode.patch` (git format-patch against 688940b, applies clean). no fork branch, the patch file is the deliverable for Kevin
- not only `DgOutputStream.cpp:65`: text-mode writers were also `DgOutShapefile.cpp:110` (.prj), `SubOpOut.cpp:959` (TEXT data output: transform / binvals / binpres), `SubOpBasicMulti.cpp:207` (multi-grid meta file). all 4 -> `std::ios::out | std::ios::binary`. input streams untouched (text mode keeps accepting CRLF .meta on windows)
- before (windows-x86_64): both gridgenGeoJSON files end `}},]}\r\n` -> `json.load` fails, all 83 text outputs CRLF
- after: both GeoJSON parse (49 features each), every DGGRID output LF, 63 of 66 example output files byte-identical to linux-x86_64 (rest = the 3 superfundGrid .shp 1-ulp diffs above)
- side note for the PR, not fixed: `postamble()` with zero features would seek back over `:[` -> also invalid, any platform
- open: PR to sahrk/DGGRID needs a fork push (no gh on this host); bundle with the MSVC fixes or send alone (small, self-contained -> alone is easier to review)

### patches/ applied in our build (decision 2026-10-02)

- no DGGRID fork branches: fixes we need live as `git format-patch` files in `patches/NNNN-*.patch`, for upstream to pick up; until merged we apply them ourselves
- `ci/apply_patches.sh`: in order, per patch `git apply --check` -> apply; `--reverse --check` ok -> skip (upstream merged it / re-run); else `::error::` + fail -> a watchdog bump that conflicts fails the build job = refresh signal. idempotent, run once locally before `zig build` (build.zig header says so)
- build.yml: runs it in build + ubsan jobs, BUILDINFO lists `patch: <file>` lines, release notes list patches; known issues trimmed to arm64 only (x86_64 printing fixed by the facet, GeoJSON by patch 0001)
- `.gitattributes`: `*.patch -text` (with global autocrlf=true the patch got CRLF in the worktree -> `git apply` failed on every hunk), `*.sh text eol=lf` (fixes the WSL `run_examples.sh` CRLF issue too)
- when upstream merges a patch: script reports "already present, skipped" after the bump -> delete the file

## open / next

- windows-x86_64: report libc++ ANSI_STDIO bug to zig; drop `src/mingw_ldouble_numput.cpp` once fixed upstream. edge release notes: x86_64 known issue resolved after next main push
- windows-arm64 (parked): printf rounding (not libm) -> ANSI stdio + num_put facet for aarch64-windows too, target byte-identical vs mac-arm64, then recheck z3CellClip/zCellClip
- decide probe/ldmath: merge (keeps precision.yml + ci/precision/ as reusable probe) or delete
- CI value check: linux-x86_64 output as reference, fail on int/text diffs (rc-only checks missed the win-x86_64 zero-coords bug)
- upstream: hand `patches/0001-output-streams-binary-mode.patch` to Kevin; MSVC template fixes could become `patches/0002`, `0003` the same way
- DONE 2026-10-02: PR #2 windows/x86_64-ldouble merged -> edge rebuilt with x86_64 fixes (branch kept for the windows session)
- CI value regression: compare against linux-x86_64 output per run (x86_64 platforms should be identical), fail on int/text diffs

- regression oracle = native gcc linux output, not sampleOutput (step 4, not in CI yet)
- macos gatekeeper / notarisation (cf. CODESIGNING.md in fork)
- upstream: MSVC fixes (`::DgDiscTopoRF`, DgRF.hpp:308), precision typedef for long double (perf everywhere + aarch64-linux)
- geoarrow: C API / writer on top of libdglib + libgeoarrow
