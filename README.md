# zgz

`zgz` is a minimal Zig `v0.16.0` gzip decompression library backed by
[zlib-ng](https://github.com/zlib-ng/zlib-ng). It is intended as a 
highly optimized decompressor for high-throughput genome sequencing 
data in production environments and bioinformatics applications.

Performance is on par with `flate2` [implementations in Rust](bench/Cargo.toml)
(`zlib-ng`, `zlib-rs` or `miniz_oxide`) and exceeds `gzip`/`zcat` in 
the tested [benchmark cases](docs/benchmarks.md). 

## Features

- Streaming gzip decompression using native `zlib-ng` bindings via `zig-zlib-ng`
- High-performance, minimal streaming decompression executable for Linux/MacOS
- Concatenated gzip member support and decompressed output limit
- Zig library and APIs for custom implementations
- No other dependencies - standard library only

## Interfaces

The `zgz` executable can be used as a general `zcat`-like decompressor:

```sh
zgz reads.fq.gz > reads.fq
```

It is ~3x faster than system `gzip` in our genomics benchmarks.

Zig library for custom implementations:

  - High-level `std.Io.Reader` to `std.Io.Writer` streaming API ([`zgz.decompress`](#high-level-streaming-api))
  - Direct buffer-filler API that inflates into caller-owned buffers ([`zgz.GzipInput`](#direct-buffer-filler-api))
  - Low-level stateful decompressor API for custom drivers ([`zgz.Decompressor`](#low-level-decompressor-api))

## Dependency model

`zgz` consumes the `zng` static library artifact from [`zig-zlib-ng`](https://github.com/CalebQ42/zig-zlib-ng).

`zgz` binds the native `zlib-ng` API:

```text
zlibng_version
zng_inflateInit2
zng_inflate
zng_inflateReset2
zng_inflateEnd
```

It does not bind the classic zlib-compatible symbols such as `inflate`, `inflateInit2_`, or `zlibVersion`.

## Build

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

`zgzfill` is mainly useful for benchmarking the direct API that downstream
parsers can use to inflate directly into their own buffers.

Examples:

```sh
# Default buffer size: 256K
./zig-out/bin/zgz testdata/biofast.fq.gz > /dev/null

# Larger buffer size may increase performance
./zig-out/bin/zgz --in-buffer 1M --out-buffer 1M sample.gz > /dev/null
```

## Benchmarking and equivalence

Dependencies used for benchmark:

 - `zig=0.16.0`
 - `rust=1.93.2`
 - `python=3.14.3`
 - `gzip=1.10.0`
 - `hyperfine=1.20.0`


Create a valid and invalid gzip compressed file corpus:

```sh
tools/01-make-corpus.sh ./testdata
```

Validate `zgz` valid/invalid test corpus against `zcat`:

```sh
tools/02-check-corpus.sh testdata/corpus
```

Test output equivalence of benchmark executables (C, Rust, Zig) against `gzip`/`zcat`:

```sh
tools/03-test-equivalence.sh testdata/corpus/valid/*.gz
```

Run `hyperfine` benchmarks of decompresson library executables (C, Rust, Zig) against
the `biofast` reference `.fastq` (Illumina short-reads, 150 bp) compressed with `gzip` 
and the `Zymo` nanopore long read mock community (ONT long-reads, ~ 5kbp average read
length):

```sh
tools/04-benchmark-files.sh testdata/biofast/biofast-v1.fastq.gz
tools/04-benchmark-files.sh testdata/zymo/zymo-v1.fastq.gz
```

Run `hyperfine` benchmarks and create a benchmark table in `docs/benchmarks.md`:

```sh
tools/05-benchmark-markdown.sh testdata/biofast/biofast-v1.fastq.gz
```

## `zgz` library and APIs

`Zig v0.16.0`

### High-level streaming API

Use `zgz.decompress` to stream from a `std.Io.Reader` to a `std.Io.Writer`:

```zig
const std = @import("std");
const zgz = @import("zgz");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var input_file = try std.Io.Dir.cwd().openFile(io, "sample.gz", .{});
    defer input_file.close(io);

    var input_buffer: [256 * 1024]u8 = undefined; // on stack
    var input_reader = input_file.readerStreaming(io, &input_buffer);

    var stdout_file = std.Io.File.stdout();

    var output_buffer: [256 * 1024]u8 = undefined; // on stack
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

### Direct buffer-filler API

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

    var input_buffer: [256 * 1024]u8 = undefined; // on stack
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

    var parser_buffer: [800 * 1024]u8 = undefined;  // on stack

    while (true) {
        const result = try gzip.readInto(parser_buffer[0..]);

        // Process parser_buffer[0..result.written]

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

`GzipInput.readInto` does not allocate and does not use an intermediate decompressed buffer.

> [!IMPORTANT]
> Initialize `GzipInput` in its final memory location and do not move it after successful initialization. It 
contains a `Decompressor`, and `zlib-ng` stores an internal back-pointer to the decompressor stream address.

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

### Configuration options

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

#### `allow_concatenated_members`

Enabled by default. This matches `gzip -dc` and `zcat`, which decode
concatenated gzip members as one logical stream.

Set it to `false` to reject trailing members or trailing data:

```zig
_ = try zgz.decompress(reader, writer, .{
    .allow_concatenated_members = false,
});
```

#### `max_output_bytes`

Limits **total decompressed bytes**, not compressed input bytes or output buffer
size.

```zig
_ = try zgz.decompress(reader, writer, .{
    .max_output_bytes = 100 * 1024 * 1024,
});
```

Semantics:

```text
null -> allow all byte - no decompressed-output limit configured
0    -> allow only streams that produce zero decompressed bytes
N    -> allow at most N decompressed bytes
```

The library treats `0` literally as “allow zero output bytes.” The CLI rejects
`--max-output 0` because it is not useful for a cat-like decompression command.

### Low-level Decompressor API

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
what `zlib-ng` did. The caller-owned driver loop decides whether a no-progress
step is recoverable or fatal.


> [!IMPORTANT]
> Initialize `Decompressor` in place and do not move it after successful initialization. `zlib-ng` stores an internal
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

## Error model

```zig
/// Errors that can occur while driving the zlib-ng inflate state machine.
pub const InflateError = error{
    /// The compressed stream is malformed or not valid for the configured
    /// wrapper format.
    InvalidData,

    /// zlib-ng reported an invalid stream state. This usually means the
    /// decompressor was not initialized, was moved after initialization, 
    /// or the native ABI binding is wrong.
    InvalidState,

    /// zlib-ng could not allocate internal inflate state.
    OutOfMemory,

    /// The input or output slice exceeded zlib-ng's `uint32_t` availability
    /// counter limit.
    SliceTooLarge,

    /// `decompress` was called after the current member reached end-of-stream.
    ///
    /// Call `reset` before feeding another gzip member, or create a new
    /// decompressor. This guard catches accidental post-end reuse instead of
    /// forwarding an invalid state transition into zlib-ng.
    StreamEnded,

    /// zlib-ng returned a code this binding does not recognize.
    UnknownZlibError,
};

/// High-level streaming errors.
pub const StreamError = InflateError || error {
    /// The input ended before zlib-ng reached the gzip stream end marker.
    UnexpectedEnd,

    /// Non-gzip trailing data was present after the first gzip member while
    /// concatenated-member decoding was disabled.
    TrailingData,

    /// The decompressed byte limit was reached before the stream ended.
    OutputLimitExceeded,

    /// The supplied `std.Io.Reader` has no usable buffer.
    ReaderBufferTooSmall,

    /// The supplied `std.Io.Writer` has no usable buffer.
    WriterBufferTooSmall,

    /// The streaming driver observed a successful inflate step that consumed no
    /// input, produced no output, and did not finish the current member.
    ///
    /// Without this guard the driver could spin forever. This usually indicates
    /// a bug in the driver loop, an invalid stream transition, or an unexpected
    /// zlib-ng state-machine result.
    NoProgress,

    /// The underlying `std.Io.Reader` failed.
    ReadFailed,

    /// The underlying `std.Io.Writer` failed.
    WriteFailed,
};
```

## Tests and corpus checks

Run unit tests:

```sh
zig build test --summary all
```

## License

`MIT` and `ZLIB-NG`
