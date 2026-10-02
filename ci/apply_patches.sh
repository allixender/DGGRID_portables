#!/usr/bin/env bash
# apply_patches.sh: apply patches/*.patch (in order) to the DGGRID submodule.
#
# Patches are fixes we need for the portable builds that are not (yet) upstream,
# kept as plain `git format-patch` files for upstream to pick up. Idempotent:
#   applies cleanly         -> apply
#   already applied         -> skip (upstream merged it, or local re-run)
#   neither                 -> fail (submodule bump conflicts, patch needs a refresh)
# Prints one line per patch; with GITHUB_STEP_SUMMARY set also a md list.
set -euo pipefail
shopt -s nullglob

root="$(cd "$(dirname "$0")/.." && pwd)"
sub="$root/DGGRID"
summary=${GITHUB_STEP_SUMMARY:-/dev/null}

patches=("$root"/patches/*.patch)
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
    echo "::error::$name neither applies nor is already present in DGGRID@$(git -C "$sub" rev-parse --short HEAD)"
    git -C "$sub" apply --check -v "$p" || true
    exit 1
  fi
  echo "$name: $state"
  echo "- \`$name\`: $state" >> "$summary"
done
