#!/usr/bin/env bash
# Update docs/benchmarks.md from tools/04-benchmark-files.sh hyperfine JSON output.
#
# This script intentionally keeps tools/04-benchmark-files.sh as the source of
# truth for what is benchmarked. It wraps that script, ingests the exported
# hyperfine JSON, appends normalized rows to a JSONL history file, and renders a
# compact Markdown report for the current git checkout/version.
#
# Usage:
#   tools/05-benchmark-markdown.sh testdata/biofast/biofast-v1.fastq.gz
#   tools/05-benchmark-markdown.sh testdata/biofast/*.gz testdata/zymo/*.gz
#
# Useful options:
#   --no-run                  Do not execute tools/04-benchmark-files.sh; ingest
#                             the existing --json file for each FILE argument.
#   --output PATH             Markdown output path. Default: docs/benchmarks.md
#   --history PATH            JSONL history path. Default: bench/zgz-benchmarks.jsonl
#   --json PATH               hyperfine JSON path. Default: bench/zgz-hyperfine.json
#   --bench-script PATH       Benchmark runner path. Default: tools/04-benchmark-files.sh
#   --project-root PATH       Project root. Default: parent of this script's dir
#   --all-history             Render all ingested versions, not only current git/version.
#   -h, --help                Show help.
#
# Dependencies: bash, python3, hyperfine/Zig/Rust as required by 04-benchmark-files.sh.
# Optional: git, gzip. If absent, metadata falls back gracefully.

set -Eeuo pipefail
IFS=$'\n\t'

usage() {
  sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

script_dir() {
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P
}

ROOT="$(cd -- "$(script_dir)/.." && pwd -P)"
OUTPUT="docs/benchmarks.md"
HISTORY="bench/zgz-benchmarks.jsonl"
JSON="bench/zgz-hyperfine.json"
BENCH_SCRIPT="tools/04-benchmark-files.sh"
RUN_BENCH=1
RENDER_CURRENT_ONLY=1
FILES=()

while (($#)); do
  case "$1" in
    --project-root)
      [[ $# -ge 2 ]] || fail "--project-root requires a path"
      ROOT="$2"; shift 2 ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a path"
      OUTPUT="$2"; shift 2 ;;
    --history)
      [[ $# -ge 2 ]] || fail "--history requires a path"
      HISTORY="$2"; shift 2 ;;
    --json)
      [[ $# -ge 2 ]] || fail "--json requires a path"
      JSON="$2"; shift 2 ;;
    --bench-script)
      [[ $# -ge 2 ]] || fail "--bench-script requires a path"
      BENCH_SCRIPT="$2"; shift 2 ;;
    --no-run)
      RUN_BENCH=0; shift ;;
    --all-history)
      RENDER_CURRENT_ONLY=0; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; FILES+=("$@"); break ;;
    -*)
      fail "unknown option: $1" ;;
    *)
      FILES+=("$1"); shift ;;
  esac
done

[[ ${#FILES[@]} -gt 0 ]] || { usage >&2; exit 2; }

cd "$ROOT"
need python3

[[ -x "$BENCH_SCRIPT" ]] || fail "benchmark script is not executable: $BENCH_SCRIPT"
mkdir -p -- "$(dirname -- "$OUTPUT")" "$(dirname -- "$HISTORY")"

# Snapshot build identity before running. This makes repeated local runs
# attributable even when git is unavailable, e.g. from a release tarball.
GIT_COMMIT="unknown"
GIT_DESCRIBE="unknown"
GIT_DIRTY="unknown"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_COMMIT="$(git rev-parse --short=12 HEAD 2>/dev/null || printf unknown)"
  GIT_DESCRIBE="$(git describe --tags --always --dirty 2>/dev/null || printf unknown)"
  if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    GIT_DIRTY="true"
  else
    GIT_DIRTY="false"
  fi
fi

PROJECT_VERSION="unknown"
if [[ -f build.zig.zon ]]; then
  PROJECT_VERSION="$(python3 - <<'PY'
import re
from pathlib import Path
text = Path('build.zig.zon').read_text(encoding='utf-8', errors='replace')
m = re.search(r'\.version\s*=\s*"([^"]+)"', text)
print(m.group(1) if m else 'unknown')
PY
)"
fi

# Ingest a single hyperfine JSON file into the JSONL history. The parser derives
# tool and buffer labels from command lines so 04-benchmark-files.sh remains the
# one benchmark matrix to maintain.
ingest_json() {
  local input_file=$1
  local json_path=$2

  [[ -f "$json_path" ]] || fail "hyperfine JSON not found: $json_path"

  INPUT_FILE="$input_file" \
  JSON_PATH="$json_path" \
  HISTORY_PATH="$HISTORY" \
  GIT_COMMIT="$GIT_COMMIT" \
  GIT_DESCRIBE="$GIT_DESCRIBE" \
  GIT_DIRTY="$GIT_DIRTY" \
  PROJECT_VERSION="$PROJECT_VERSION" \
  python3 - <<'PY'
import json
import os
import shlex
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path

input_file = os.environ['INPUT_FILE']
json_path = Path(os.environ['JSON_PATH'])
history_path = Path(os.environ['HISTORY_PATH'])

try:
    data = json.loads(json_path.read_text(encoding='utf-8'))
except Exception as exc:
    raise SystemExit(f"failed to parse {json_path}: {exc}") from exc

results = data.get('results')
if not isinstance(results, list):
    raise SystemExit(f"{json_path} does not look like hyperfine JSON: missing results[]")

now = datetime.now(timezone.utc).isoformat(timespec='seconds')
path = Path(input_file)
try:
    file_size = path.stat().st_size
except OSError:
    file_size = None

common = {
    'schema': 1,
    'timestamp_utc': now,
    'host': socket.gethostname(),
    'project_version': os.environ.get('PROJECT_VERSION', 'unknown'),
    'git_commit': os.environ.get('GIT_COMMIT', 'unknown'),
    'git_describe': os.environ.get('GIT_DESCRIBE', 'unknown'),
    'git_dirty': os.environ.get('GIT_DIRTY', 'unknown'),
    'file': input_file,
    'file_name': path.name,
    'file_size_bytes': file_size,
}

def command_parts(command: str) -> list[str]:
    try:
        parts = shlex.split(command)
    except ValueError:
        return command.split()
    # Remove shell redirection details from the parse surface.
    cleaned = []
    skip_next = False
    for part in parts:
        if skip_next:
            skip_next = False
            continue
        if part in {'>', '1>', '2>'}:
            skip_next = True
            continue
        if part.startswith('>'):
            continue
        cleaned.append(part)
    return cleaned

def parse_tool_and_buffer(command: str) -> tuple[str, str, str | None, str | None]:
    parts = command_parts(command)
    if not parts:
        return ('unknown', 'unknown', None, None)

    exe = Path(parts[0]).name
    if exe == 'gzip':
        tool = 'gzip -dc'
    elif exe == 'zcat':
        tool = 'zcat'
    else:
        tool = exe

    in_buffer = None
    out_buffer = None
    for i, part in enumerate(parts):
        if part == '--in-buffer' and i + 1 < len(parts):
            in_buffer = parts[i + 1]
        elif part.startswith('--in-buffer='):
            in_buffer = part.split('=', 1)[1]
        elif part == '--out-buffer' and i + 1 < len(parts):
            out_buffer = parts[i + 1]
        elif part.startswith('--out-buffer='):
            out_buffer = part.split('=', 1)[1]

    if tool in {'gzip -dc', 'zcat'}:
        buffer_label = 'system'
    elif in_buffer is None and out_buffer is None:
        buffer_label = 'default'
    elif in_buffer == out_buffer:
        buffer_label = in_buffer or out_buffer or 'custom'
    else:
        buffer_label = f"in={in_buffer or '?'} / out={out_buffer or '?'}"

    return (tool, buffer_label, in_buffer, out_buffer)

rows = []
for result in results:
    command = result.get('command')
    if not isinstance(command, str):
        continue
    tool, buffer_label, in_buffer, out_buffer = parse_tool_and_buffer(command)
    row = dict(common)
    row.update({
        'tool': tool,
        'buffer': buffer_label,
        'in_buffer': in_buffer,
        'out_buffer': out_buffer,
        'command': command,
        'mean_s': result.get('mean'),
        'stddev_s': result.get('stddev'),
        'median_s': result.get('median'),
        'min_s': result.get('min'),
        'max_s': result.get('max'),
        'user_s': result.get('user'),
        'system_s': result.get('system'),
    })
    rows.append(row)

if not rows:
    raise SystemExit(f"no benchmark rows found in {json_path}")

history_path.parent.mkdir(parents=True, exist_ok=True)
with history_path.open('a', encoding='utf-8') as fh:
    for row in rows:
        fh.write(json.dumps(row, sort_keys=True, separators=(',', ':')) + '\n')

print(f"ingested {len(rows)} benchmark rows from {json_path} for {input_file}")
PY
}

render_markdown() {
  local tmp
  tmp="$(mktemp "${OUTPUT}.tmp.XXXXXX")"

  HISTORY_PATH="$HISTORY" \
  OUTPUT_PATH="$tmp" \
  CURRENT_GIT_COMMIT="$GIT_COMMIT" \
  CURRENT_PROJECT_VERSION="$PROJECT_VERSION" \
  RENDER_CURRENT_ONLY="$RENDER_CURRENT_ONLY" \
  python3 - <<'PY'
import json
import os
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

history_path = Path(os.environ['HISTORY_PATH'])
output_path = Path(os.environ['OUTPUT_PATH'])
current_git = os.environ.get('CURRENT_GIT_COMMIT', 'unknown')
current_version = os.environ.get('CURRENT_PROJECT_VERSION', 'unknown')
current_only = os.environ.get('RENDER_CURRENT_ONLY', '1') == '1'

if not history_path.exists():
    raise SystemExit(f"history file does not exist: {history_path}")

rows = []
for line_no, line in enumerate(history_path.read_text(encoding='utf-8').splitlines(), 1):
    if not line.strip():
        continue
    try:
        row = json.loads(line)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"bad JSONL in {history_path}:{line_no}: {exc}") from exc
    if not isinstance(row.get('mean_s'), (int, float)):
        continue
    if current_only:
        same_git = row.get('git_commit', 'unknown') == current_git
        same_version = row.get('project_version', 'unknown') == current_version
        # In tarball/non-git workflows, version is the best available identity.
        if current_git != 'unknown':
            if not same_git:
                continue
        elif not same_version:
            continue
    rows.append(row)

if not rows:
    raise SystemExit('no benchmark rows match the selected render scope')

# Keep only the newest measurement per version/file/tool/buffer. This lets users
# rerun a case after code or environment tweaks without manually editing history.
latest = {}
for row in rows:
    key = (
        row.get('git_commit', 'unknown'),
        row.get('project_version', 'unknown'),
        row.get('file', ''),
        row.get('tool', ''),
        row.get('buffer', ''),
    )
    old = latest.get(key)
    if old is None or row.get('timestamp_utc', '') >= old.get('timestamp_utc', ''):
        latest[key] = row
rows = list(latest.values())

versions = sorted({(r.get('git_describe') or r.get('git_commit') or 'unknown', r.get('project_version') or 'unknown') for r in rows})
files = sorted({r.get('file', '') for r in rows})

def fmt_ms(seconds):
    if not isinstance(seconds, (int, float)):
        return '—'
    return f"{seconds * 1000:.2f}"

def fmt_rate(row):
    size = row.get('file_size_bytes')
    mean = row.get('mean_s')
    if not isinstance(size, int) or not isinstance(mean, (int, float)) or mean <= 0:
        return '—'
    return f"{(size / 1048576) / mean:.1f}"

def fmt_size(size):
    if not isinstance(size, int):
        return 'unknown size'
    units = [('GiB', 1024 ** 3), ('MiB', 1024 ** 2), ('KiB', 1024)]
    for unit, div in units:
        if size >= div:
            return f"{size / div:.2f} {unit}"
    return f"{size} B"

def escape_md(text):
    return str(text).replace('|', '\\|')

lines = []
lines.append('# Benchmarks')
lines.append('')
lines.append('Generated from `hyperfine` JSON produced by `tools/04-benchmark-files.sh`.')
lines.append('')
lines.append(f"_Last rendered: {datetime.now(timezone.utc).isoformat(timespec='seconds')}._")
lines.append('')
lines.append('## Scope')
lines.append('')
if current_only:
    lines.append(f"- Render mode: latest rows for current checkout/version only.")
else:
    lines.append(f"- Render mode: latest rows for all ingested checkouts/versions.")
for describe, version in versions:
    lines.append(f"- Version: `{escape_md(version)}`; git: `{escape_md(describe)}`")
lines.append('')
lines.append('Lower mean time is better. `vs fastest` is the slowdown relative to the fastest command in the same file/buffer group. `Input MiB/s` is compressed-input throughput, not decompressed-output throughput.')
lines.append('')

for file in files:
    file_rows = [r for r in rows if r.get('file') == file]
    if not file_rows:
        continue
    file_name = file_rows[0].get('file_name') or Path(file).name
    file_size = file_rows[0].get('file_size_bytes')
    lines.append(f"## `{escape_md(file_name)}`")
    lines.append('')
    lines.append(f"Path: `{escape_md(file)}`  ")
    lines.append(f"Compressed size: {fmt_size(file_size)}")
    lines.append('')

    explicit_buffers = sorted({r.get('buffer') for r in file_rows if r.get('buffer') not in {None, '', 'system'}})
    system_rows = [r for r in file_rows if r.get('buffer') == 'system']
    if not explicit_buffers:
        explicit_buffers = ['system']

    for buffer in explicit_buffers:
        group = [r for r in file_rows if r.get('buffer') == buffer] + system_rows
        # Deduplicate if buffer == system.
        seen = set()
        deduped = []
        for r in group:
            k = (r.get('tool'), r.get('buffer'))
            if k in seen:
                continue
            seen.add(k)
            deduped.append(r)
        group = sorted(deduped, key=lambda r: (r.get('mean_s', float('inf')), r.get('tool', '')))
        fastest = min((r.get('mean_s') for r in group if isinstance(r.get('mean_s'), (int, float)) and r.get('mean_s') > 0), default=None)

        lines.append(f"### Buffer: `{escape_md(buffer)}`")
        lines.append('')
        lines.append('| Tool | Buffer | Mean ± σ (ms) | Median (ms) | vs fastest | Input MiB/s |')
        lines.append('|---|---:|---:|---:|---:|---:|')
        for r in group:
            mean = r.get('mean_s')
            std = r.get('stddev_s')
            if fastest and isinstance(mean, (int, float)) and mean > 0:
                rel = mean / fastest
                vs = '1.00×' if abs(rel - 1.0) < 0.005 else f"{rel:.2f}×"
            else:
                vs = '—'
            lines.append(
                f"| `{escape_md(r.get('tool', 'unknown'))}` "
                f"| `{escape_md(r.get('buffer', 'unknown'))}` "
                f"| {fmt_ms(mean)} ± {fmt_ms(std)} "
                f"| {fmt_ms(r.get('median_s'))} "
                f"| {vs} "
                f"| {fmt_rate(r)} |"
            )
        lines.append('')

output_path.write_text('\n'.join(lines).rstrip() + '\n', encoding='utf-8')
PY

  mv -- "$tmp" "$OUTPUT"
  printf 'wrote %s\n' "$OUTPUT"
}

for file in "${FILES[@]}"; do
  [[ -f "$file" ]] || fail "input file not found: $file"

  # The current 04-benchmark-files.sh interpolates FILE.gz into hyperfine command
  # strings without shell-quoting. Refuse paths that would be split by the shell;
  # otherwise hyperfine would measure failures or the wrong file. Annoying, but
  # much better than silently publishing nonsense numbers.
  if [[ "$file" =~ [[:space:]] ]]; then
    fail "input paths with whitespace are not safe with the current $BENCH_SCRIPT: $file"
  fi

  if (( RUN_BENCH )); then
    ZGZ_BENCHMARK_DOCS=0 "$BENCH_SCRIPT" "$file"
  fi
  ingest_json "$file" "$JSON"
done

render_markdown
