# zgz

`zgz` is a minimal Zig `v0.16.0` gzip decompression library backed by [zlib-ng](https://github.com/zlib-ng/zlib-ng).

It is intended as an optimized decompressor for library bindings and high-throughput genome sequencing data in production environments.

## Features

- Streaming gzip decompression using native zlib-ng bindings via `zig-zlib-ng`
- Concatenated gzip member support and bounded decompressed-output caps
- High-level `std.Io.Reader` to `std.Io.Writer` streaming API
- Direct pull API that inflates into caller-owned buffers
- Low-level stateful decompressor API

## Dependency model

`zgz` consumes the `zng` static library artifact from
[`zig-zlib-ng`](https://github.com/CalebQ42/zig-zlib-ng).

`zgz` binds the native zlib-ng API:

```text
zlibng_version
zng_inflateInit2
zng_inflate
zng_inflateReset2
zng_inflateEnd
```

It does not bind the classic zlib-compatible symbols such as `inflate`,
`inflateInit2_`, or `zlibVersion`.

## Build

Fetch the zlib-ng dependency:

```sh
zig fetch --save git+https://github.com/CalebQ42/zig-zlib-ng.git
```

Build:

```sh
zig build -Doptimize=ReleaseFast
```

Run tests:

```sh
zig build test
```

## CLI tools

### `zgz`

`zgz` streams gzip input to stdout through the high-level `zgz.decompress`
reader-to-writer API:

```sh
./zig-out/bin/zgz [options] FILE.gz
```

### `zgzfill`

`zgzfill` streams gzip input to stdout through the direct `zgz.GzipInput`
buffer-filler API:

```sh
./zig-out/bin/zgzfill [options] FILE.gz
```

`zgzfill` is mainly useful for benchmarking the direct API that downstream
parsers can use to inflate directly into their own buffers.

Both CLIs accept:

```text
--in-buffer BYTES    Input file reader buffer. Supports K/M/G suffixes.
                     Default: 256K.

--out-buffer BYTES   Output/decompression buffer. Supports K/M/G suffixes.
                     Default: 256K.

--max-output BYTES   Abort if output exceeds this limit. Supports K/M/G suffixes.
                     Must be greater than zero in the CLI.

--no-concat          Reject concatenated gzip members and trailing data.

-h, --help           Show help.
```

Examples:

```sh
./zig-out/bin/zgz testdata/biofast.fq.gz > /dev/null
./zig-out/bin/zgzfill testdata/biofast.fq.gz > /dev/null

./zig-out/bin/zgz --in-buffer 1M --out-buffer 1M sample.gz > /dev/null
./zig-out/bin/zgzfill --in-buffer 1M --out-buffer 1M sample.gz > /dev/null
```

## Benchmarking and equivalence

Verify output equivalence before benchmarking:

```sh
cmp <(zcat sample.gz) <(./zig-out/bin/zgz sample.gz)
cmp <(zcat sample.gz) <(./zig-out/bin/zgzfill sample.gz)
cmp <(./zig-out/bin/zgz sample.gz) <(./zig-out/bin/zgzfill sample.gz)
```

Hash-check multiple files:

```sh
for f in "$@"; do
  expected="$(zcat "$f" | sha256sum | awk '{print $1}')"
  zgz_hash="$(./zig-out/bin/zgz "$f" | sha256sum | awk '{print $1}')"
  zgzfill_hash="$(./zig-out/bin/zgzfill "$f" | sha256sum | awk '{print $1}')"

  if [ "$expected" != "$zgz_hash" ] || [ "$expected" != "$zgzfill_hash" ]; then
    echo "mismatch: $f" >&2
    echo "expected  $expected" >&2
    echo "zgz       $zgz_hash" >&2
    echo "zgzfill   $zgzfill_hash" >&2
    exit 1
  fi

  echo "ok: $f"
done
```

Compare against external tools:

```sh
hyperfine \
  './zig-out/bin/zgz sample.gz > /dev/null' \
  './zig-out/bin/zgzfill sample.gz > /dev/null' \
  'gzip -dc sample.gz > /dev/null' \
  'zcat sample.gz > /dev/null'
```

Try larger buffers:

```sh
hyperfine \
  './zig-out/bin/zgz --in-buffer 1M --out-buffer 1M sample.gz > /dev/null' \
  './zig-out/bin/zgzfill --in-buffer 1M --out-buffer 1M sample.gz > /dev/null' \
  'gzip -dc sample.gz > /dev/null' \
  'zcat sample.gz > /dev/null'
```

## High-level streaming API

Use `zgz.decompress` to stream from a `std.Io.Reader` to a `std.Io.Writer`:

```zig
const std = @import("std");
const zgz = @import("zgz");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var input_file = try std.Io.Dir.cwd().openFile(io, "sample.gz", .{});
    defer input_file.close(io);

    var input_buffer: [256 * 1024]u8 = undefined;
    var input_reader = input_file.readerStreaming(io, &input_buffer);

    var stdout_file = std.Io.File.stdout();

    var output_buffer: [256 * 1024]u8 = undefined;
    var output_writer = stdout_file.writer(io, &output_buffer);

    _ = try zgz.decompress(
        &input_reader.interface,
        &output_writer.interface,
        .{
            .allow_concatenated_members = true,
            .max_output_bytes = null,
        },
    );

    try output_writer.interface.flush();
}
```

`zgz.decompress` borrows input directly from the reader and writes decompressed
bytes directly into the writer buffer.

## Direct buffer-filler API

Use `GzipInput` when the caller already owns an optimized output buffer, such as
a parser refill buffer:

```text
file -> std.Io.File.Reader buffer -> zlib-ng -> caller output buffer
```

Example:

```zig
const std = @import("std");
const zgz = @import("zgz");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var input_file = try std.Io.Dir.cwd().openFile(io, "reads.fastq.gz", .{});
    defer input_file.close(io);

    var input_buffer: [256 * 1024]u8 = undefined;
    var input_reader = input_file.readerStreaming(io, &input_buffer);

    var gzip: zgz.GzipInput = undefined;
    try gzip.init(
        &input_reader.interface,
        .{
            .allow_concatenated_members = true,
            .max_output_bytes = null,
        },
    );
    defer gzip.deinit();

    var parser_buffer: [800 * 1024]u8 = undefined;

    while (true) {
        const result = try gzip.readInto(parser_buffer[0..]);

        // Process parser_buffer[0..result.written] here.

        if (result.end) break;

        if (result.written == 0) {
            return error.DriverMadeNoProgress;
        }
    }
}
```

For parser integration, pass the parser's free buffer region:

```zig
const free = parser.buffer[parser.end..parser.capacity];
const result = try gzip.readInto(free);
parser.end += result.written;
parser.eof = result.end;
```

`GzipInput.readInto` does not allocate and does not use an intermediate
decompressed buffer.

> [!IMPORTANT]
> Initialize `GzipInput` in its final memory location and do not move it after successful initialization. It 
contains a `Decompressor`, and zlib-ng stores an internal back-pointer to the decompressor stream address.

Correct:

```zig
var gzip: zgz.GzipInput = undefined;
try gzip.init(&input_reader.interface, .{});
defer gzip.deinit();
```

Incorrect:

```zig
var tmp: zgz.GzipInput = undefined;
try tmp.init(&input_reader.interface, .{});

var gzip = tmp;
```

If `GzipInput` lives inside another struct, initialize the struct storage first, then call `init` on the field:

```zig
var wrapper: Wrapper = undefined;

try wrapper.gzip.init(&input_reader.interface, .{});
defer wrapper.gzip.deinit();
```

## Stream options

The high-level streaming API uses:

```zig
pub const StreamOptions = struct {
    allow_concatenated_members: bool = true,
    max_output_bytes: ?usize = null,
};
```

The direct API uses the equivalent:

```zig
pub const GzipInputOptions = struct {
    allow_concatenated_members: bool = true,
    max_output_bytes: ?usize = null,
};
```

### `allow_concatenated_members`

Enabled by default. This matches `gzip -dc` and `zcat`, which decode
concatenated gzip members as one logical stream.

Set it to `false` to reject trailing members or trailing data:

```zig
_ = try zgz.decompress(reader, writer, .{
    .allow_concatenated_members = false,
});
```

### `max_output_bytes`

Limits **total decompressed bytes**, not compressed input bytes or output buffer
size.

```zig
_ = try zgz.decompress(reader, writer, .{
    .max_output_bytes = 100 * 1024 * 1024,
});
```

Semantics:

```text
null -> no decompressed-output cap
0    -> allow only streams that produce zero decompressed bytes
N    -> allow at most N decompressed bytes
```

The library treats `0` literally as “allow zero output bytes.” The CLI rejects
`--max-output 0` because it is not useful for a cat-like decompression command.

## Low-level Decompressor API

For custom drivers, use `Decompressor` directly:

```zig
var d: zgz.Decompressor = .{};
try d.initGzip();
defer d.deinit();

var in_pos: usize = 0;
var out_pos: usize = 0;

while (true) {
    const step = try d.decompress(
        compressed[in_pos..],
        output[out_pos..],
    );

    in_pos += step.read;
    out_pos += step.written;

    switch (step.status) {
        .progress, .need_input_or_output => {
            if (step.read == 0 and step.written == 0) {
                return error.DriverMadeNoProgress;
            }
        },
        .end => break,
    }
}
```

`Decompressor.decompress` does not itself return `error.NoProgress`; it reports
what zlib-ng did. The caller-owned driver loop decides whether a no-progress
step is recoverable or fatal.


> [!IMPORTANT]
> Initialize `Decompressor` in place and do not move it after successful initialization. zlib-ng stores an internal
back-pointer to the stream address. Do not use a constructor that returns an initialized `Decompressor` by value.

Correct:

```zig
var d: zgz.Decompressor = .{};
try d.initGzip();
defer d.deinit();
```

Incorrect:

```zig
var tmp: zgz.Decompressor = .{};
try tmp.initGzip();

var d = tmp;
defer d.deinit();
```

If `Decompressor` lives inside another struct, initialize the struct storage first, then call `initGzip` on the field:

```zig
var wrapper: Wrapper = undefined;

try wrapper.decompressor.initGzip();
defer wrapper.decompressor.deinit();
```

## Error notes

Common errors:

```text
InvalidData            malformed gzip data or CRC/trailer failure
UnexpectedEnd          input ended before gzip stream completion
TrailingData           trailing data found when concatenation is disabled
OutputLimitExceeded    decompressed output would exceed max_output_bytes
NoProgress             high-level driver observed no input/output progress
ReadFailed             underlying reader failed
WriteFailed            underlying writer failed
WriterBufferTooSmall   caller provided no writable output space
StreamEnded            Decompressor reused after end without reset
InvalidState           invalid zlib-ng state or incorrect API usage
```

For concrete file readers/writers, map `ReadFailed` and `WriteFailed` through
the concrete `.err` field at the call boundary.

## Tests and corpus checks

Run unit tests:

```sh
zig build test --summary all
```

## License

TBD
