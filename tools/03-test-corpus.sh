#!/usr/bin/env sh
set -eu

zig build -Doptimize=ReleaseFast >/dev/null
cargo build --release --manifest-path bench/Cargo.toml > /dev/null

for f in "$@"; do
  expected="$(zcat "$f" | sha256sum | awk '{print $1}')"
  zgz="$(./zig-out/bin/zgz "$f" | sha256sum | awk '{print $1}')"
  zgzfill="$(./zig-out/bin/zgzfill "$f" | sha256sum | awk '{print $1}')"
  rzgz_miniz="$(./bench/target/release/rzgz-miniz "$f" | sha256sum | awk '{print $1}')"
  rzgz_zlib_ng="$(./bench/target/release/rzgz-zlib-ng "$f" | sha256sum | awk '{print $1}')"
  rzgz_zlib_rs="$(./bench/target/release/rzgz-zlib-rs "$f" | sha256sum | awk '{print $1}')"

  if [ "$expected" != "$zgz" ] || [ "$expected" != "$zgzfill" ] || [ "$expected" != "$rzgz_miniz" ] || [ "$expected" != "$rzgz_zlib_ng" ] || [ "$expected" != "$rzgz_zlib_rs" ]; then
    echo "mismatch:     $f" >&2
    echo "expected      $expected" >&2
    echo "zgz           $zgz" >&2
    echo "zgzfill       $zgzfill" >&2
    echo "rzgz-miniz    $zgzfill" >&2
    echo "rzgz-zlib-ng  $zgzfill" >&2
    echo "rzgz-zlib-rs  $zgzfill" >&2
    exit 1
  else
    echo "ok: $f"
  fi
done  