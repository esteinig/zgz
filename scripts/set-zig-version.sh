#!/usr/bin/env bash
set -euo pipefail

version="${1:?usage: $0 <version>}"
file="build.zig.zon"
tmp="$(mktemp "${TMPDIR:-/tmp}/set-zig-version.XXXXXX")"

cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

if [[ ! -f "$file" ]]; then
  echo "error: $file not found" >&2
  exit 1
fi

awk -v version="$version" '
  BEGIN {
    updated = 0
    inserted = 0
  }

  /^[[:space:]]*\.version[[:space:]]*=/ {
    print "    .version = \"" version "\","
    updated = 1
    next
  }

  {
    print
  }

  !updated && !inserted && /^[[:space:]]*\.{[[:space:]]*$/ {
    print "    .version = \"" version "\","
    inserted = 1
  }

  END {
    if (!updated && !inserted) {
      print "error: could not find opening .{ in build.zig.zon" > "/dev/stderr"
      exit 1
    }
  }
' "$file" > "$tmp"

mv "$tmp" "$file"