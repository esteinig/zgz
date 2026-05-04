#!/usr/bin/env bash
#
# Generate a local gzip corpus for broad zgz decompression testing.
#
# Output:
#   testdata/corpus/
#
# The generated files cover:
#   - empty gzip member
#   - small text
#   - FASTQ-like data
#   - FASTA-like data
#   - JSONL/log-style data
#   - CSV data
#   - concatenated gzip members
#   - truncated stream
#   - corrupted trailer/CRC
#   - highly compressible data
#   - incompressible/random data
#
# Notes:
#   - Valid .gz files should pass with gzip -dc and zgz.
#   - Invalid .gz files are placed in testdata/corpus/invalid/.
#   - gzip is invoked with -n to avoid embedding original filename/timestamp.
#
# Usage:
#   ./tools/make-corpus.sh
#   ./tools/make-corpus.sh testdata/my-corpus

set -eu

ROOT="${1:-testdata/corpus}"
VALID_DIR="$ROOT/valid"
INVALID_DIR="$ROOT/invalid"
RAW_DIR="$ROOT/raw"

mkdir -p "$VALID_DIR" "$INVALID_DIR" "$RAW_DIR"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 127
  fi
}

require_cmd gzip
require_cmd python3
require_cmd sha256sum
require_cmd dd
require_cmd truncate

echo "creating corpus under: $ROOT"

rm -f "$VALID_DIR"/*.gz "$INVALID_DIR"/*.gz "$RAW_DIR"/* "$ROOT"/MANIFEST.tsv

###############################################################################
# Raw fixtures
###############################################################################

: > "$RAW_DIR/empty.raw"

cat > "$RAW_DIR/small.txt" <<'EOF'
hello
this is a small text fixture
with multiple lines
and repeated repeated repeated words
EOF

python3 - <<'PY' > "$RAW_DIR/reads.fastq"
for i in range(1, 1001):
    seq = ("ACGTN" * 20)[:100]
    qual = "I" * 100
    print(f"@read_{i}")
    print(seq)
    print("+")
    print(qual)
PY

python3 - <<'PY' > "$RAW_DIR/refs.fasta"
for i in range(1, 101):
    print(f">contig_{i}")
    seq = ("ACGT" * 200)[:800]
    for j in range(0, len(seq), 80):
        print(seq[j:j+80])
PY

python3 - <<'PY' > "$RAW_DIR/logs.jsonl"
import json
for i in range(1, 10001):
    print(json.dumps({
        "ts": f"2026-05-04T00:{i % 60:02d}:00Z",
        "level": "INFO" if i % 7 else "WARN",
        "request_id": f"req-{i:08d}",
        "path": "/api/v1/decompress",
        "status": 200 if i % 11 else 503,
        "bytes": i * 17,
        "message": "synthetic log line for zgz corpus testing",
    }, separators=(",", ":")))
PY

python3 - <<'PY' > "$RAW_DIR/table.csv"
print("id,name,category,value,description")
for i in range(1, 20001):
    print(f"{i},item-{i},cat-{i % 13},{i * 3},synthetic csv row for decompression testing")
PY

python3 - <<'PY' > "$RAW_DIR/zeros-16m.raw"
import sys
sys.stdout.buffer.write(b"\0" * (16 * 1024 * 1024))
PY

python3 - <<'PY' > "$RAW_DIR/repeated-lines.txt"
for i in range(500000):
    print(f"{i}\tabcdefghijklmnopqrstuvwxyz\tabcdefghijklmnopqrstuvwxyz\t{i % 97}")
PY

dd if=/dev/urandom of="$RAW_DIR/random-4m.raw" bs=1M count=4 status=none

###############################################################################
# Valid gzip fixtures
###############################################################################

gzip -n -c "$RAW_DIR/empty.raw"          > "$VALID_DIR/empty.raw.gz"
gzip -n -c "$RAW_DIR/small.txt"          > "$VALID_DIR/small.txt.gz"
gzip -n -c "$RAW_DIR/reads.fastq"        > "$VALID_DIR/reads.fastq.gz"
gzip -n -c "$RAW_DIR/refs.fasta"         > "$VALID_DIR/refs.fasta.gz"
gzip -n -c "$RAW_DIR/logs.jsonl"         > "$VALID_DIR/logs.jsonl.gz"
gzip -n -c "$RAW_DIR/table.csv"          > "$VALID_DIR/table.csv.gz"
gzip -n -c "$RAW_DIR/zeros-16m.raw"      > "$VALID_DIR/zeros-16m.raw.gz"
gzip -n -c "$RAW_DIR/repeated-lines.txt" > "$VALID_DIR/repeated-lines.txt.gz"
gzip -n -c "$RAW_DIR/random-4m.raw"      > "$VALID_DIR/random-4m.raw.gz"

gzip -n -c "$RAW_DIR/small.txt" > "$VALID_DIR/concatenated-small-fastq.gz"
gzip -n -c "$RAW_DIR/reads.fastq" >> "$VALID_DIR/concatenated-small-fastq.gz"

###############################################################################
# Invalid gzip fixtures
###############################################################################

cp "$VALID_DIR/small.txt.gz" "$INVALID_DIR/small.truncated.gz"
size="$(wc -c < "$INVALID_DIR/small.truncated.gz" | tr -d ' ')"
if [ "$size" -gt 8 ]; then
  truncate -s "$((size - 8))" "$INVALID_DIR/small.truncated.gz"
fi

cp "$VALID_DIR/small.txt.gz" "$INVALID_DIR/small.bad-crc.gz"
python3 - "$INVALID_DIR/small.bad-crc.gz" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = bytearray(path.read_bytes())
if len(data) < 12:
    raise SystemExit("fixture unexpectedly too small")
data[-8] ^= 0x01
path.write_bytes(data)
PY

cp "$VALID_DIR/small.txt.gz" "$INVALID_DIR/small.trailing-junk.gz"
printf 'junk' >> "$INVALID_DIR/small.trailing-junk.gz"

printf 'not gzip, sadly\n' > "$INVALID_DIR/not-gzip.gz"

###############################################################################
# Manifest
###############################################################################

{
  printf "kind\tfile\tcompressed_sha256\tdecompressed_sha256\tcompressed_bytes\tdecompressed_bytes\n"

  for f in "$VALID_DIR"/*.gz; do
    compressed_sha="$(sha256sum "$f" | awk '{print $1}')"
    decompressed_sha="$(gzip -dc "$f" | sha256sum | awk '{print $1}')"
    compressed_bytes="$(wc -c < "$f" | tr -d ' ')"
    decompressed_bytes="$(gzip -dc "$f" | wc -c | tr -d ' ')"
    printf "valid\t%s\t%s\t%s\t%s\t%s\n"       "$f" "$compressed_sha" "$decompressed_sha" "$compressed_bytes" "$decompressed_bytes"
  done

  for f in "$INVALID_DIR"/*.gz; do
    compressed_sha="$(sha256sum "$f" | awk '{print $1}')"
    compressed_bytes="$(wc -c < "$f" | tr -d ' ')"
    printf "invalid\t%s\t%s\t-\t%s\t-\n"       "$f" "$compressed_sha" "$compressed_bytes"
  done
} > "$ROOT/MANIFEST.tsv"

echo "created:"
find "$ROOT" -type f | sort
echo
echo "manifest: $ROOT/MANIFEST.tsv"
