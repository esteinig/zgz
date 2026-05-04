#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 FILE.gz" >&2
  exit 2
fi

file=$1
command -v hyperfine >/dev/null || { echo "hyperfine not found" >&2; exit 127; }

zig build -Doptimize=ReleaseFast >/dev/null
./tools/test-corpus.sh "$file" >/dev/null

hyperfine \
  --warmup 3 \
  --export-json zgz-hyperfine.json \
  './zig-out/bin/zgz '"$file"' > /dev/null' \
  './zig-out/bin/zgz '"$file"' --in-buffer 1048576 --out-buffer 1048576 > /dev/null' \
  './zig-out/bin/zgzfill '"$file"' > /dev/null' \
  './zig-out/bin/zgzfill '"$file"' --in-buffer 1048576 --out-buffer 1048576 > /dev/null' \
  'gzip -dc '"$file"' > /dev/null' \
  'zcat '"$file"' > /dev/null'
