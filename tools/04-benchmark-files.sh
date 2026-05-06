#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 FILE.gz" >&2
  exit 2
fi

file=$1
command -v hyperfine >/dev/null || { echo "hyperfine not found" >&2; exit 127; }

zig build -Doptimize=ReleaseFast >/dev/null
cargo build --release --manifest-path bench/Cargo.toml > /dev/null

LARGE_BUFFER="2M"

hyperfine \
  --warmup 3 \
  --export-json bench/zgz-hyperfine.json \
  './zig-out/bin/zgz '"$file"' > /dev/null' \
  './zig-out/bin/zgz '"$file"' --in-buffer 2M --out-buffer 2M > /dev/null' \
  './zig-out/bin/zgzfill '"$file"' > /dev/null' \
  './zig-out/bin/zgzfill '"$file"' --in-buffer 2M --out-buffer 2M > /dev/null' \
  './bench/target/release/rzgz-miniz '"$file"' > /dev/null' \
  './bench/target/release/rzgz-miniz '"$file"' --in-buffer 2M --out-buffer 2M > /dev/null' \
  './bench/target/release/rzgz-zlib-ng '"$file"' > /dev/null' \
  './bench/target/release/rzgz-zlib-ng '"$file"' --in-buffer 2M --out-buffer 2M > /dev/null' \
  './bench/target/release/rzgz-zlib-rs '"$file"' > /dev/null' \
  './bench/target/release/rzgz-zlib-rs '"$file"' --in-buffer 2M --out-buffer 2M > /dev/null' \
  'gzip -dc '"$file"' > /dev/null' \
  'zcat '"$file"' > /dev/null'
