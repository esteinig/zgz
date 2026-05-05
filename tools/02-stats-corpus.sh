#!/usr/bin/env sh
set -eu

for f in "$@"; do
  compressed="$(wc -c < "$f" | tr -d ' ')"
  decompressed="$(zcat "$f" | wc -c | tr -d ' ')"
  ratio="$(awk "BEGIN { printf \"%.2f\", $decompressed / $compressed }")"

  printf "%s\tcompressed=%s\tdecompressed=%s\tratio=%sx\n" \
    "$f" "$compressed" "$decompressed" "$ratio"
done