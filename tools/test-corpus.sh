#!/usr/bin/env sh
set -eu

zig build -Doptimize=ReleaseFast >/dev/null

for f in "$@"; do
  expected="$(zcat "$f" | sha256sum | awk '{print $1}')"
  zgz="$(./zig-out/bin/zgz "$f" | sha256sum | awk '{print $1}')"
  zgzfill="$(./zig-out/bin/zgzfill "$f" | sha256sum | awk '{print $1}')"

  if [ "$expected" != "$zgz" ] || [ "$expected" != "$zgzfill" ]; then
    echo "mismatch: $f" >&2
    echo "expected  $expected" >&2
    echo "zgz       $zgz" >&2
    echo "zgzfill   $zgzfill" >&2
    exit 1
  else
    echo "ok: $f"
  fi
done