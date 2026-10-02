#!/usr/bin/env bash
# run_examples.sh <dggrid-exe> <workdir>
#
# Runs upstream's GDAL-free examples (DGGRID/examples/examplesNoGDAL.lst) with the given
# binary in a scratch copy of the examples dir. Fails if any example exits non-zero or
# misses an output file that upstream's sampleOutput has. Output *values* are compared
# separately (compare_outputs.py, informational), see build_notes.md for why.
set -u
shopt -s nullglob

exe_in=$1
work=$2
exe="$(cd "$(dirname "$exe_in")" && pwd)/$(basename "$exe_in")"
src="$(cd "$(dirname "$0")/../DGGRID/examples" && pwd)"

rm -rf "$work" && mkdir -p "$work" && cp -R "$src"/. "$work"/
cd "$work" || exit 2

summary=${GITHUB_STEP_SUMMARY:-/dev/null}
{
  echo "### examples: \`$(basename "$exe")\` on $(uname -sm)"
  echo
  echo "| example | rc | seconds | missing outputs |"
  echo "|---|---|---|---|"
} >> "$summary"

failed=0
for ex in $(tr -d '\r' < examplesNoGDAL.lst); do
  mkdir -p "$ex/outputfiles"
  t0=$(date +%s)
  (cd "$ex" && "$exe" "$ex.meta" > "outputfiles/$ex.txt" 2>&1)
  rc=$?
  secs=$(( $(date +%s) - t0 ))

  missing=""
  for ref in sampleOutput/"$ex"/*; do
    name=$(basename "$ref")
    [ "$name" = "$ex.txt" ] && continue
    [ -e "$ex/outputfiles/$name" ] || missing="$missing $name"
  done

  status=ok
  if [ $rc -ne 0 ] || [ -n "$missing" ]; then
    status=FAIL
    failed=$((failed + 1))
    echo "---- $ex log (tail):"
    tail -20 "$ex/outputfiles/$ex.txt"
  fi
  printf '%-20s %-4s rc=%-3s %4ss %s\n' "$ex" "$status" "$rc" "$secs" "${missing:+missing:$missing}"
  echo "| $ex | $rc | $secs | ${missing:--} |" >> "$summary"
done

total=$(tr -d '\r' < examplesNoGDAL.lst | wc -w | tr -d ' ')
echo "$((total - failed))/$total examples ok"
echo "**$((total - failed))/$total examples ok**" >> "$summary"
[ $failed -eq 0 ]
