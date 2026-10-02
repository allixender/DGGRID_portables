#!/bin/bash
# usage: runex.sh <label> <runner-prefix...> -- runs examplesNoGDAL with $EXE, diffs vs sampleOutput
# env: EXE (path to dggrid as seen by runner), WORK (copy dir), RUN (optional command prefix)
label=$1
SRC=${SRC:-$(cd "$(dirname "$0")/../../DGGRID/examples" && pwd)}
W=$WORK/$label; rm -rf $W; mkdir -p $W; cp -R $SRC/. $W/
cd $W
pass=0; fail=0; failed=""
for f in $(cat examplesNoGDAL.lst); do
  ( cd $f && mkdir -p outputfiles && $RUN $EXE ${f}.meta > outputfiles/${f}.txt 2>&1; echo "rc=$?" >> outputfiles/${f}.txt )
  # compare all output files except the log txt
  nd=$(diff -rq -x "${f}.txt" $f/outputfiles sampleOutput/$f 2>&1 | wc -l | tr -d ' ')
  if [ "$nd" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); failed="$failed $f($nd)"; fi
done
echo "[$label] pass=$pass fail=$fail :$failed"
