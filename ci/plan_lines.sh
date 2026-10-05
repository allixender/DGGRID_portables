#!/usr/bin/env bash
# plan_lines.sh: which upstream lines (upstream.json) does this CI run build, and how far?
# Prints `lines=<json array>` for $GITHUB_OUTPUT, the matrix of build.yml -> line.yml.
#
#   pull request        default line (sha null) full, other lines build-only
#   push to main        rolling lines full + publish their rolling pre-release,
#                       fixed lines build-only
#   push tag vX[-rN]    the fixed line with "release": "vX", full + publish as release <tag>
#                       (-rN = rebuild of the same upstream version, e.g. new zig or patch)
#   workflow_dispatch   full, no publish; ONLY=<line> limits it to one line (watchdog)
#
# tests:   full | build-only (patches apply + all targets cross-compile, no native runners)
# publish: none | rolling | fixed
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
event=${GITHUB_EVENT_NAME:?}
ref=${GITHUB_REF:?}
only=${ONLY:-}
tag=""
base=""

bad=$(jq -r 'map(select((.rolling | not) and .sha == null) | .line) | join(", ")' "$root/upstream.json")
[ -z "$bad" ] || { echo "::error::fixed lines need a pinned sha in upstream.json: $bad"; exit 1; }

case "$event:$ref" in
  push:refs/tags/*)
    tag=${ref#refs/tags/}
    base=$tag
    [[ $tag =~ ^(.+)-r[0-9]+$ ]] && base=${BASH_REMATCH[1]}
    filter='map(select((.rolling | not) and .release == $base) | .tests = "full" | .publish = "fixed" | .release = $tag)'
    ;;
  push:refs/heads/main)
    filter='map(if .rolling then .tests = "full" | .publish = "rolling" else .tests = "build-only" | .publish = "none" end)'
    ;;
  pull_request:*)
    filter='map(.tests = (if .sha == null then "full" else "build-only" end) | .publish = "none")'
    ;;
  *)
    filter='map(select($only == "" or .line == $only) | .tests = "full" | .publish = "none")'
    ;;
esac

# workflow_call inputs are strings: null -> "", booleans -> "true"/"false"
lines=$(jq -c --arg base "$base" --arg tag "$tag" --arg only "$only" "$filter"'
  | map({line, sha: (.sha // ""), patches: (.patches // ""), release,
         prerelease: (.prerelease | tostring), tests, publish})' "$root/upstream.json")
[ "$lines" != "[]" ] || { echo "::error::no line in upstream.json for $event $ref${only:+ (line $only)}"; exit 1; }

{
  echo "### upstream lines"
  echo
  echo "| line | commit | patches | tests | publish | release |"
  echo "|---|---|---|---|---|---|"
  jq -r '.[] | "| \(.line) | \(if .sha == "" then "gitlink" else .sha[0:10] end) | \(.patches) | \(.tests) | \(.publish) | \(.release) |"' <<<"$lines"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "lines=$lines"
