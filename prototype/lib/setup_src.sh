#!/usr/bin/env bash
# setup_src.sh: (re)create the prototype's own DGGRID + geoarrow-c source copy in .src/
#
#   .src/DGGRID      git archive of the pinned submodule commit (src/ + examples/),
#                    + patches/*.patch (release patches)
#                    + prototype/lib/patches/*.patch (prototype only, e.g. fatal hook)
#                    + dgreal.py rewrite (long double -> dgreal typedef)
#   .src/geoarrow-c  git archive of the pinned submodule commit (src/), unpatched
#
# The DGGRID submodule itself is never touched, so the release build stays upstream +
# patches/. Plain files, no git: `diff -ru DGGRID/src prototype/lib/.src/DGGRID/src`
# shows what the patches and the rewrite did. Rerun after a submodule bump.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="$here/.src"

rm -rf "$out"
mkdir -p "$out/DGGRID" "$out/geoarrow-c"
git -C "$root/DGGRID" archive HEAD src examples | tar -x -C "$out/DGGRID"
git -C "$root/geoarrow-c" archive HEAD src | tar -x -C "$out/geoarrow-c"
{
  echo "DGGRID     $(git -C "$root/DGGRID" rev-parse HEAD)"
  echo "geoarrow-c $(git -C "$root/geoarrow-c" rev-parse HEAD)"
} > "$out/SOURCES.txt"

"$root/ci/apply_patches.sh" "$out/DGGRID" "$root/patches" "$here/patches"
python3 "$here/patches/dgreal.py" "$out/DGGRID/src"
