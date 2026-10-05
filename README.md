# DGGRID_portables

Portable, GDAL-free [DGGRID](https://github.com/sahrk/DGGRID) binaries for Linux, macOS and Windows (x86_64 + arm64), cross-compiled with [Zig](https://ziglang.org) 0.16.

This repo wraps upstream `sahrk/DGGRID` as a git submodule and does not modify its sources. It adds a Zig build, CI and release packaging. A daily watchdog opens a PR when one of the followed upstream branches moves.

## Download

Latest build of upstream master (rolling pre-release `edge`), stable URLs:

| platform | asset |
|---|---|
| Linux x86_64 (static, any distro) | [dggrid-linux-x86_64.tar.gz](https://github.com/allixender/DGGRID_portables/releases/download/edge/dggrid-linux-x86_64.tar.gz) |
| Linux arm64 (static) | [dggrid-linux-arm64.tar.gz](https://github.com/allixender/DGGRID_portables/releases/download/edge/dggrid-linux-arm64.tar.gz) |
| macOS universal (11.0+) | [dggrid-macos-universal.tar.gz](https://github.com/allixender/DGGRID_portables/releases/download/edge/dggrid-macos-universal.tar.gz) |
| macOS arm64 / x86_64 | [arm64](https://github.com/allixender/DGGRID_portables/releases/download/edge/dggrid-macos-arm64.tar.gz), [x86_64](https://github.com/allixender/DGGRID_portables/releases/download/edge/dggrid-macos-x86_64.tar.gz) |
| Windows x86_64 / arm64 | [x86_64](https://github.com/allixender/DGGRID_portables/releases/download/edge/dggrid-windows-x86_64.zip), [arm64](https://github.com/allixender/DGGRID_portables/releases/download/edge/dggrid-windows-arm64.zip) |

Tagged versions are under [Releases](https://github.com/allixender/DGGRID_portables/releases). Each archive has a `BUILDINFO.txt` with the upstream commit. macOS binaries are not notarised yet: run `xattr -d com.apple.quarantine dggrid` once after download.

### Other DGGRID versions

The builds follow several upstream lines, which are listed in `upstream.json` (one row per line with the upstream branch or tag, the pinned commit, the patch directory and the release name). The asset names are the same for every line, so only the release name in the download URL changes (`releases/download/<release>/dggrid-<platform>.tar.gz`):

| line | upstream | release |
|---|---|---|
| `master` | branch `master` (9.0b) | `edge`, rolling pre-release |
| `v91b` | development branch `v91b` (9.1b) | `edge-v91b`, rolling pre-release |
| `v8.44` | tag `v8.44` | `v8.44`, fixed release |

Rolling pre-releases are replaced on every push to `main`. A fixed release is published once, when the tag with the release name is pushed to this repo, and a rebuild of the same upstream version gets a suffix (e.g. `v8.44-r2`).

Linux arm64 is much slower than the other platforms, because `long double` is a software 128-bit type on that platform (see `build_notes.md`).

## Build

```bash
git clone --recursive git@github.com:allixender/DGGRID_portables.git
cd DGGRID_portables
zig build -Doptimize=ReleaseFast     # host binary in zig-out/bin
zig build release                    # all platforms in zig-out/release/<platform>/
ci/run_examples.sh zig-out/bin/dggrid /tmp/dggrid-examples
```

To build another upstream line, `ci/use_line.sh --reset v91b` checks out the pinned commit of that line in the submodule and applies the patches of that line (requires `jq`). The submodule then differs from the commit recorded in this repo, which should not be committed; `ci/use_line.sh --reset master` switches back.

Requires Zig 0.16.0. `build_notes.md` has the findings behind the build choices (targets, flags, testing, performance). `prototype/` holds experiments, e.g. linking DGGRID as a library with geoarrow-c.

## License

AGPL-3.0, same as DGGRID. Release binaries contain DGGRID and are distributed under its AGPL-3.0 license.
