#!/bin/sh
# copy the built library artifacts into the demo folders (gitignored, nothing here is built)
#   ./copy_libs.sh [zig-out dir of ../lib, default ../lib/zig-out] [dggrid.wasm, default <that>/wasm/bin/dggrid.wasm]
# needs a native build (cd ../lib && zig build -Ddgreal=double -Doptimize=ReleaseFast)
# and the wasm build (zig build -Dtarget=wasm32-wasi -Ddgreal=double -Doptimize=ReleaseFast -p zig-out/wasm)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/../lib/zig-out}

mkdir -p "$here/python/igeo7/_lib" "$here/web"
n=0
for f in "$out"/lib/libdggrid.dylib "$out"/lib/libdggrid.so "$out"/bin/dggrid.dll; do
  [ -f "$f" ] && cp "$f" "$here/python/igeo7/_lib/" && echo "python: $(basename "$f")" && n=1
done
[ "$n" = 1 ] || { echo "no libdggrid.{dylib,so,dll} under $out" >&2; exit 1; }

wasm=${2:-$out/wasm/bin/dggrid.wasm}
if [ -f "$wasm" ]; then
  cp "$wasm" "$here/web/"
  cp "$here/../wasm/dggrid.mjs" "$here/web/"
  echo "web: dggrid.wasm dggrid.mjs"
else
  echo "web: no $wasm, skipped"
fi
