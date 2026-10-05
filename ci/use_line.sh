#!/usr/bin/env bash
# use_line.sh [--reset] <line>
#
# Put the DGGRID submodule on one of the upstream lines in upstream.json: check out the
# line's pinned commit ("sha": null = the submodule gitlink) and apply the line's patches.
# CI runs this before every build. Locally it leaves the submodule on another commit than
# the gitlink, so `git status` shows DGGRID as modified. Don't commit that; go back with
# `ci/use_line.sh --reset master`.
#
#   --reset   discard local changes in DGGRID first (applied patches count as changes)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
reset=false
[ "${1:-}" = "--reset" ] && { reset=true; shift; }
line=${1:?usage: use_line.sh [--reset] <line>}

[ "$(jq --arg l "$line" 'map(select(.line == $l)) | length' upstream.json)" = 1 ] ||
  { echo "::error::no line '$line' in upstream.json ($(jq -r 'map(.line) | join(", ")' upstream.json))"; exit 1; }
sha=$(jq -r --arg l "$line" '.[] | select(.line == $l) | .sha // ""' upstream.json)
patches=$(jq -r --arg l "$line" '.[] | select(.line == $l) | .patches // ""' upstream.json)
[ -n "$sha" ] || sha=$(git ls-tree HEAD DGGRID | awk '{print $3}')

[ -e DGGRID/.git ] || git submodule update --init DGGRID
if ! git -C DGGRID diff --quiet; then
  $reset || { echo "DGGRID has local changes (applied patches?), re-run with --reset to discard them"; exit 1; }
  git -C DGGRID reset --quiet --hard
fi
if [ "$(git -C DGGRID rev-parse HEAD)" != "$sha" ]; then
  if ! git -C DGGRID cat-file -e "$sha^{commit}" 2>/dev/null; then
    # CI clones the submodule shallow, keep it that way; never make a full clone shallow
    if [ "$(git -C DGGRID rev-parse --is-shallow-repository)" = true ]; then
      git -C DGGRID fetch --quiet --depth 1 origin "$sha"
    else
      git -C DGGRID fetch --quiet origin "$sha"
    fi
  fi
  git -C DGGRID checkout --quiet --detach "$sha"
fi

ver=$(sed -n 's/^#define DGGRID_VERSION *"\(.*\)"/\1/p' DGGRID/src/lib/dglib/include/dglib/DgBase.h)
echo "DGGRID line $line: sahrk/DGGRID@${sha:0:10} ($ver)"
if [ -n "$patches" ]; then
  ci/apply_patches.sh DGGRID "$patches"
fi
