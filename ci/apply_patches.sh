#!/usr/bin/env bash
# apply_patches.sh: apply patches/*.patch (in order) to the DGGRID submodule.
#
# Patches are fixes we need for the portable builds that are not (yet) upstream,
# kept as plain `git format-patch` files for upstream to pick up. Idempotent:
#   applies cleanly         -> apply
#   already applied         -> skip (upstream merged it, or local re-run)
#   neither                 -> fail (submodule bump conflicts, patch needs a refresh)
# Prints one line per patch; with GITHUB_STEP_SUMMARY set also a md list.
#
#   apply_patches.sh                          patches/*.patch -> DGGRID submodule
#   apply_patches.sh <src-dir> <patch-dir>... patch dirs in order -> <src-dir>, e.g. another
#                                             upstream line (patches/v91b, see upstream.json)
#                                             or the prototype's plain source copy (no git repo)
set -euo pipefail
shopt -s nullglob

root="$(cd "$(dirname "$0")/.." && pwd)"
sub=$(cd "${1:-$root/DGGRID}" && pwd)
[ $# -gt 0 ] && shift
dirs=("$@")
[ ${#dirs[@]} -eq 0 ] && dirs=("$root/patches")
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
# a plain copy inside this repo must not be mistaken for a subdir of it: git apply would
# then resolve the patch paths against our repo root
export GIT_CEILING_DIRECTORIES="$(dirname "$sub")"

patches=()
for d in "${dirs[@]}"; do
  [ -d "$d" ] || { echo "::error::patch dir $d not found"; exit 1; }
  # absolute, git apply runs with -C "$sub"
  patches+=("$(cd "$d" && pwd)"/*.patch)
done
[ ${#patches[@]} -eq 0 ] && { echo "no patches"; exit 0; }

echo "### DGGRID patches" >> "$summary"
for p in "${patches[@]}"; do
  name=$(basename "$p")
  if git -C "$sub" apply --check "$p" 2>/dev/null; then
    git -C "$sub" apply "$p"
    state="applied"
  elif git -C "$sub" apply --check --reverse "$p" 2>/dev/null; then
    state="already present, skipped"
  else
    echo "::error::$name neither applies nor is already present in $(git -C "$sub" rev-parse --short HEAD 2>/dev/null || echo "$sub")"
    git -C "$sub" apply --check -v "$p" || true
    exit 1
  fi
  echo "$name: $state"
  echo "- \`$name\`: $state" >> "$summary"
done
