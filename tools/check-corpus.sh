#!/usr/bin/env bash
#
# Check zgz against gzip -dc over a generated or user-provided corpus.
#
# Usage:
#   ./tools/check-corpus.sh
#   ./tools/check-corpus.sh testdata/corpus
#   ./tools/check-corpus.sh --cmp testdata/corpus
#   ./tools/check-corpus.sh --zgz ./zig-out/bin/zgz testdata/corpus
#
# Options:
#   --cmp             Use byte-for-byte cmp with process substitution instead of
#                     SHA-256 streams. Good for debugging mismatches.
#   --valid-only      Only check valid corpus files.
#   --invalid-only    Only check invalid corpus files.
#   --zgz PATH        Path to zgzcat binary.
#   --no-build        Do not run zig build before checking.
#
# Requires:
#   bash, gzip, sha256sum, cmp

set -euo pipefail

ROOT="testdata/corpus"
ZGZCAT="./zig-out/bin/zgz"
USE_CMP=0
CHECK_VALID=1
CHECK_INVALID=1
DO_BUILD=1

usage() {
  cat >&2 <<'EOF'
usage: check-corpus.sh [options] [CORPUS_DIR]

Options:
  --cmp             Use byte-for-byte cmp instead of SHA-256 comparison.
  --valid-only      Only check valid corpus files.
  --invalid-only    Only check invalid corpus files.
  --zgz PATH        Path to zgz binary.
  --no-build        Do not run zig build before checking.
  -h, --help        Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cmp)
      USE_CMP=1
      shift
      ;;
    --valid-only)
      CHECK_VALID=1
      CHECK_INVALID=0
      shift
      ;;
    --invalid-only)
      CHECK_VALID=0
      CHECK_INVALID=1
      shift
      ;;
    --zgz)
      if [ "$#" -lt 2 ]; then
        echo "error: --zgz requires a path" >&2
        exit 2
      fi
      ZGZCAT="$2"
      shift 2
      ;;
    --no-build)
      DO_BUILD=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      ROOT="$1"
      shift
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 127
  fi
}

require_cmd gzip
require_cmd sha256sum
require_cmd cmp

if [ "$DO_BUILD" -eq 1 ]; then
  require_cmd zig
  zig build -Doptimize=ReleaseFast >/dev/null
fi

if [ ! -x "$ZGZCAT" ]; then
  echo "error: zgz not found or not executable: $ZGZCAT" >&2
  echo "hint: run zig build -Doptimize=ReleaseFast" >&2
  exit 127
fi

VALID_DIR="$ROOT/valid"
INVALID_DIR="$ROOT/invalid"

failures=0
checked=0

check_valid_hash() {
  f="$1"

  gzip_sha="$(gzip -dc "$f" | sha256sum | awk '{print $1}')"
  zgz_sha="$("$ZGZCAT" "$f" | sha256sum | awk '{print $1}')"

  if [ "$gzip_sha" != "$zgz_sha" ]; then
    echo "FAIL valid hash mismatch: $f" >&2
    echo "  gzip: $gzip_sha" >&2
    echo "  zgz:  $zgz_sha" >&2
    return 1
  fi
}

check_valid_cmp() {
  f="$1"

  if ! cmp <(gzip -dc "$f") <("$ZGZCAT" "$f") >/dev/null; then
    echo "FAIL valid byte mismatch: $f" >&2
    return 1
  fi
}

check_invalid() {
  f="$1"

  gzip_ok=0
  zgz_ok=0

  if gzip -dc "$f" >/dev/null 2>/dev/null; then
    gzip_ok=1
  fi

  if "$ZGZCAT" "$f" >/dev/null 2>/dev/null; then
    zgz_ok=1
  fi

  if [ "$gzip_ok" -eq 1 ] && [ "$zgz_ok" -eq 0 ]; then
    echo "WARN testing accepted invalid fixture but zgz rejected it: $f" >&2
    echo "     This can happen for trailing junk depending on gzip behavior." >&2
    return 0
  fi

  if [ "$gzip_ok" -eq 0 ] && [ "$zgz_ok" -eq 1 ]; then
    echo "FAIL gzip rejected invalid fixture but zgz accepted it: $f" >&2
    return 1
  fi

  if [ "$gzip_ok" -eq 1 ] && [ "$zgz_ok" -eq 1 ]; then
    echo "WARN both gzip and zgz accepted invalid fixture: $f" >&2
    echo "     Reconsider whether this fixture belongs in invalid/." >&2
    return 0
  fi

  return 0
}

if [ "$CHECK_VALID" -eq 1 ]; then
  if [ ! -d "$VALID_DIR" ]; then
    echo "error: valid corpus directory not found: $VALID_DIR" >&2
    exit 2
  fi

  while IFS= read -r -d '' f; do
    checked=$((checked + 1))
    echo "valid: $f"

    if [ "$USE_CMP" -eq 1 ]; then
      if ! check_valid_cmp "$f"; then
        failures=$((failures + 1))
      fi
    else
      if ! check_valid_hash "$f"; then
        failures=$((failures + 1))
      fi
    fi
  done < <(find "$VALID_DIR" -type f -name '*.gz' -print0 | sort -z)
fi

if [ "$CHECK_INVALID" -eq 1 ]; then
  if [ ! -d "$INVALID_DIR" ]; then
    echo "warning: invalid corpus directory not found: $INVALID_DIR" >&2
  else
    while IFS= read -r -d '' f; do
      checked=$((checked + 1))
      echo "invalid: $f"

      if ! check_invalid "$f"; then
        failures=$((failures + 1))
      fi
    done < <(find "$INVALID_DIR" -type f -name '*.gz' -print0 | sort -z)
  fi
fi

echo
echo "checked:  $checked"
echo "failures: $failures"

if [ "$failures" -ne 0 ]; then
  exit 1
fi
