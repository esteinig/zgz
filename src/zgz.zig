const std = @import("std");
const c = @import("c.zig");

/// Return the runtime zlib-ng version string.
pub fn zlibVersion() []const u8 {
    return std.mem.span(c.zlibng_version());
}

pub const CompressionFormat = enum {
    gzip,
    zlib,
    raw_deflate,
    gzip_or_zlib,

    fn windowBits(self: CompressionFormat) c.int32_t {
        return switch (self) {
            .gzip => 15 + 16,
            .zlib => 15,
            .raw_deflate => -15,
            .gzip_or_zlib => 15 + 32,
        };
    }
};


pub const DecompressorOptions = struct {
    format: CompressionFormat = .gzip,
};

/// Default reader buffer size for file-backed streaming.
///
/// This is used by the CLI boundary when constructing `std.Io.File.Reader`.
/// Library callers that already have a `std.Io.Reader` control buffering
/// themselves.
pub const default_input_buffer_size: usize = 256 * 1024;

/// Default writer buffer size for file-backed streaming.
///
/// This is used by the CLI boundary when constructing `std.Io.File.Writer`.
/// Library callers that already have a `std.Io.Writer` control buffering
/// themselves.
pub const default_output_buffer_size: usize = 256 * 1024;

/// zlib window size plus gzip wrapper decoding.
///
/// zlib-ng, in zlib-compatible mode, follows zlib's `inflateInit2` convention:
/// `15` selects the maximum deflate window and `16` enables gzip wrapper
/// decoding.
const gzip_window_bits: c_int = 15 + 16;

/// zlib-compatible no-flush mode for inflate.
const z_no_flush: c_int = 0;

/// Errors that can occur while driving the zlib-ng inflate state machine.
pub const InflateError = error{
    /// The compressed stream is malformed or not valid for the configured
    /// wrapper format.
    InvalidData,

    /// zlib-ng reported an invalid stream state. This usually means the
    /// decompressor was not initialized, was moved after initialization, or the
    /// native ABI binding is wrong.
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
pub const StreamError = InflateError || error{
    /// The input ended before zlib-ng reached the gzip stream end marker.
    UnexpectedEnd,

    /// Non-gzip trailing data was present after the first gzip member while
    /// concatenated-member decoding was disabled.
    TrailingData,

    /// The decompressed byte cap was reached before the stream ended.
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

    /// The underlying `std.Io.Reader` failed. For concrete file readers, inspect
    /// the concrete reader's `.err` field at the call boundary.
    ReadFailed,

    /// The underlying `std.Io.Writer` failed. For concrete file writers, inspect
    /// the concrete writer's `.err` field at the call boundary.
    WriteFailed,
};

/// Options for bounded-memory gzip streaming.
pub const StreamOptions = struct {
    /// Whether to decode concatenated gzip members.
    ///
    /// GNU `gzip -dc` and `zcat` decode concatenated members. Keep this enabled
    /// for benchmark equivalence unless intentionally testing stricter behavior.
    allow_concatenated_members: bool = true,

    /// Optional cap on decompressed bytes written to the output.
    ///
    /// This is a safety guard for untrusted input. When the cap is reached
    /// before the gzip stream finishes, `error.OutputLimitExceeded` is returned.
    max_output_bytes: ?usize = null,
};

/// Aggregate counters returned by streaming decompression.
pub const StreamStats = struct {
    /// Compressed bytes consumed from the reader.
    compressed_bytes: usize = 0,

    /// Decompressed bytes logically written to the writer.
    decompressed_bytes: usize = 0,

    /// Completed gzip members.
    members: usize = 0,
};

/// Status returned from one low-level inflate call.
pub const InflateStatus = enum {
    /// zlib-ng consumed input and/or produced output but has not reached the
    /// end of the current gzip member.
    progress,

    /// zlib-ng reached the end of the current gzip member.
    end,

    /// zlib-ng could not make progress because it needs more input, more output
    /// space, or both.
    ///
    /// This is not fatal by itself. The high-level streaming loop interprets it
    /// using surrounding EOF/output-cap state.
    need_input_or_output,
};

/// Result from one low-level inflate call.
pub const InflateStep = struct {
    /// Bytes consumed from the `input` slice passed to `decompress`.
    read: usize,

    /// Bytes written into the `output` slice passed to `decompress`.
    written: usize,

    /// zlib-ng state after this call.
    status: InflateStatus,
};


/// Decision returned after zlib-ng reports the end of one gzip member.
///
/// Gzip streams may contain multiple concatenated members. The high-level
/// streaming driver uses this enum to make the post-member transition explicit:
/// either the logical stream is complete, or the decompressor has been reset and
/// the caller should continue feeding the next member.
pub const AfterMember = enum {
    /// No additional input is available; the logical gzip stream is complete.
    done,

    /// Additional input is available and concatenated-member decoding is
    /// enabled. The decompressor has been reset and the caller should continue
    /// the streaming loop.
    continue_next_member,
};


/// Return a zero-initialized zlib-ng native stream.
///
/// zlib-ng initializes internal fields in `zng_inflateInit2`.
pub fn zeroStream() c.z_stream {
    return .{
        .next_in = null,
        .avail_in = 0,
        .total_in = 0,
        .next_out = null,
        .avail_out = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };
}

/// Stateful gzip decompressor backed by zlib-ng's native inflate API.
///
/// Important: this value must not be moved after `initGzip`.
///
/// zlib-ng stores an internal back-pointer to the address of the stream passed
/// to `zng_inflateInit2`. If the `Decompressor` is initialized in a temporary
/// and then returned by value, the internal `state->strm` pointer will point at
/// the old address and the first `zng_inflate` call will return
/// `Z_STREAM_ERROR`.
pub const Decompressor = struct {
    stream: c.z_stream = zeroStream(),
    initialized: bool = false,
    ended: bool = false,
    format: CompressionFormat = .gzip,

    /// Initialize this decompressor in place.
    ///
    /// The value must not be moved after successful initialization because
    /// zlib-ng stores a back-pointer to this stream internally.
    pub fn init(self: *Decompressor, options: DecompressorOptions) InflateError!void {
        self.* = .{
            .stream = zeroStream(),
            .initialized = false,
            .ended = false,
            .format = options.format,
        };

        const rc = c.zng_inflateInit2(
            &self.stream,
            options.format.windowBits(),
        );

        switch (rc) {
            c.Z_OK => { self.initialized = true; },
            c.Z_MEM_ERROR => return error.OutOfMemory,
            c.Z_STREAM_ERROR => return error.InvalidState,
            else => return error.UnknownZlibError,
        }
    }

    pub fn initGzip(self: *Decompressor) InflateError!void {
        return self.init(.{ .format = .gzip });
    }

    pub fn deinit(self: *Decompressor) void {
        if (!self.initialized) return;
        _ = c.zng_inflateEnd(&self.stream);
        self.* = .{};
    }

    pub fn reset(self: *Decompressor) InflateError!void {
        if (!self.initialized) return error.InvalidState;

        const rc = c.zng_inflateReset2(
            &self.stream,
            self.format.windowBits(),
        );

        switch (rc) {
            c.Z_OK => {
                self.ended = false;
            },
            c.Z_MEM_ERROR => return error.OutOfMemory,
            c.Z_STREAM_ERROR => return error.InvalidState,
            else => return error.UnknownZlibError,
        }
    }

    pub fn decompress(
        self: *Decompressor,
        input: []const u8,
        output: []u8,
    ) InflateError!InflateStep {
        if (!self.initialized) return error.InvalidState;
        if (self.ended) return error.StreamEnded;
        if (input.len > std.math.maxInt(c.uInt)) return error.SliceTooLarge;
        if (output.len > std.math.maxInt(c.uInt)) return error.SliceTooLarge;

        const before_total_in = self.stream.total_in;
        const before_total_out = self.stream.total_out;

        self.stream.next_in = if (input.len == 0) null else input.ptr;
        self.stream.avail_in = @intCast(input.len);

        self.stream.next_out = if (output.len == 0) null else output.ptr;
        self.stream.avail_out = @intCast(output.len);

        const rc = c.zng_inflate(&self.stream, c.Z_NO_FLUSH);

        const read = self.stream.total_in - before_total_in;
        const written = self.stream.total_out - before_total_out;

        return switch (rc) {
            c.Z_OK => .{
                .read = read,
                .written = written,
                .status = .progress,
            },
            c.Z_STREAM_END => blk: {
                self.ended = true;
                break :blk .{
                    .read = read,
                    .written = written,
                    .status = .end,
                };
            },
            c.Z_BUF_ERROR => .{
                .read = read,
                .written = written,
                .status = .need_input_or_output,
            },
            c.Z_DATA_ERROR => error.InvalidData,
            c.Z_STREAM_ERROR => error.InvalidState,
            c.Z_MEM_ERROR => error.OutOfMemory,
            else => error.UnknownZlibError,
        };
    }
};


/// Handle the transition after the current gzip member reaches end-of-stream.
///
/// If concatenated members are disabled, this function accepts EOF and rejects
/// any remaining byte as `error.TrailingData`.
///
/// If concatenated members are enabled, this function peeks for another byte:
///
/// - EOF means the logical gzip stream is complete;
/// - an available byte means another member may follow, so the decompressor is
///   reset with the same wrapper settings and the caller should continue;
/// - reader failure is surfaced as `error.ReadFailed`.
///
/// This function deliberately uses `peekGreedy(1)` rather than reading into a
/// temporary buffer. The byte remains owned by the reader and will be consumed by
/// the next inflate step after reset.
pub fn afterMember(
    reader: *std.Io.Reader,
    decompressor: *Decompressor,
    options: StreamOptions,
) StreamError!AfterMember {
    if (!options.allow_concatenated_members) {
        _ = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return .done,
            error.ReadFailed => return error.ReadFailed,
        };

        return error.TrailingData;
    }

    _ = reader.peekGreedy(1) catch |err| switch (err) {
        error.EndOfStream => return .done,
        error.ReadFailed => return error.ReadFailed,
    };

    try decompressor.reset();
    return .continue_next_member;
}

/// Continue driving zlib-ng after the configured output cap has been reached.
///
/// This is used to distinguish two important cases:
///
/// - the stream ends exactly at `max_output_bytes`, which is valid;
/// - the stream needs to produce at least one more decompressed byte, which must
///   fail with `error.OutputLimitExceeded`.
///
/// The function never writes to the caller's writer. Instead, it gives zlib-ng a
/// one-byte scratch output buffer. If zlib-ng writes into that scratch buffer,
/// the decompressed output would exceed the configured cap.
///
/// This helper is also required because native zlib-ng may reject zero-length
/// output probes with `Z_STREAM_ERROR`; do not call inflate with both no input
/// and no output as a state-machine probe.
pub fn finishAtOutputLimit(
    reader: *std.Io.Reader,
    decompressor: *Decompressor,
    stats: *StreamStats,
    options: StreamOptions,
) StreamError!AfterMember {
    while (true) {
        const input = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return error.UnexpectedEnd,
            error.ReadFailed => return error.ReadFailed,
        };

        var scratch: [1]u8 = undefined;

        const step = try decompressor.decompress(input, scratch[0..]);

        if (step.read != 0) {
            reader.toss(step.read);
            stats.compressed_bytes += step.read;
        }

        if (step.written != 0) {
            return error.OutputLimitExceeded;
        }

        if (step.read == 0 and step.written == 0) {
            switch (step.status) {
                .progress, .need_input_or_output => return error.NoProgress,
                .end => {},
            }
        }

        switch (step.status) {
            .progress, .need_input_or_output => continue,

            .end => {
                stats.members += 1;

                switch (try afterMember(reader, decompressor, options)) {
                    .done => return .done,

                    .continue_next_member => {
                        // The cap is still reached, so continue proving that
                        // the next member also emits no bytes.
                        continue;
                    },
                }
            },
        }
    }
}


/// Return writable output capacity respecting `max_output_bytes`.
///
/// This borrows the writer's own buffer; it does not allocate and does not copy.
pub fn writableOutputSlice(
    writer: *std.Io.Writer,
    decompressed_so_far: usize,
    max_output_bytes: ?usize,
) StreamError![]u8 {
    if (max_output_bytes) |cap| {
        if (decompressed_so_far >= cap) {
            return &.{};
        }

        const remaining = cap - decompressed_so_far;
        const slice = try writer.writableSliceGreedy(1);
        return slice[0..@min(slice.len, remaining)];
    }

    return writer.writableSliceGreedy(1);
}

/// True when the configured decompressed-output cap has been reached.
pub fn isAtOutputCap(decompressed_so_far: usize, max_output_bytes: ?usize) bool {
    const cap = max_output_bytes orelse return false;
    return decompressed_so_far >= cap;
}


/// Stream bytes from `reader` to `writer` without intermediate buffers.
///
/// This is the fast path for CLI tools and benchmarks:
///
/// - compressed input is borrowed directly from `reader.peekGreedy`;
/// - consumed input is committed with `reader.toss`;
/// - decompressed output is written directly into `writer.writableSliceGreedy`;
/// - produced output is committed with `writer.advance`.
///
/// The caller controls buffering at the I/O boundary. For files, construct:
///
/// ```zig
/// var file_reader = file.readerStreaming(io, input_buffer);
/// var stdout = std.Io.File.stdout().writer(io, output_buffer);
///
/// _ = try zgz.decompress(
///     &file_reader.interface,
///     &stdout.interface,
///     .{},
/// );
/// try stdout.interface.flush();
/// ```
///
/// Both the reader and writer must have non-empty buffers. 
pub fn decompress(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: StreamOptions,
) StreamError!StreamStats {
    if (reader.buffer.len == 0) return error.ReaderBufferTooSmall;
    if (writer.buffer.len == 0) return error.WriterBufferTooSmall;

    var decompressor: Decompressor = .{};
    try decompressor.initGzip();
    defer decompressor.deinit();

    var stats: StreamStats = .{};

    while (true) {
        const input = reader.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return error.UnexpectedEnd,
            error.ReadFailed => return error.ReadFailed,
        };

        const output = try writableOutputSlice(
            writer,
            stats.decompressed_bytes,
            options.max_output_bytes,
        );

        if (output.len == 0 and isAtOutputCap(stats.decompressed_bytes, options.max_output_bytes)) {
            switch (try finishAtOutputLimit(reader, &decompressor, &stats, options)) {
                .done => return stats,
                .continue_next_member => continue,
            }
        }

        const step = try decompressor.decompress(input, output);

        if (step.read != 0) {
            reader.toss(step.read);
            stats.compressed_bytes += step.read;
        }

        if (step.written != 0) {
            writer.advance(step.written);
            stats.decompressed_bytes += step.written;
        }

        // A successful inflate step must either consume input, produce output, report
        // member completion, or explicitly ask for more input/output. `Z_OK` with no
        // movement is not useful to the driver and would otherwise spin forever.
        if (step.read == 0 and step.written == 0 and step.status == .progress) {
            return error.NoProgress;
        }

        switch (step.status) {
            .progress => {
                if (isAtOutputCap(stats.decompressed_bytes, options.max_output_bytes)) {
                    switch (try finishAtOutputLimit(reader, &decompressor, &stats, options)) {
                        .done => return stats,
                        .continue_next_member => continue,
                    }
                }
            },

            .need_input_or_output => {
                if (isAtOutputCap(stats.decompressed_bytes, options.max_output_bytes)) {
                    return error.OutputLimitExceeded;
                }

                continue;
            },

            .end => {
                stats.members += 1;

                switch (try afterMember(reader, &decompressor, options)) {
                    .done => return stats,
                    .continue_next_member => continue,
                }
            },
        }
    }
}


/// Options for direct gzip input.
///
/// `GzipInput` is a pull-style decompressor: callers provide the destination
/// output slice, and zlib-ng inflates directly into that slice.
pub const GzipInputOptions = struct {
    /// Decode concatenated gzip members as one logical stream.
    ///
    /// This matches `gzip -dc` / `zcat` behavior and should usually remain
    /// enabled for `.fastq.gz` / `.fq.gz` files.
    allow_concatenated_members: bool = true,

    /// Optional cap on total decompressed bytes produced by this input.
    ///
    /// Semantics:
    ///
    /// - `null`: no decompressed-output cap;
    /// - `0`: allow only streams that produce zero decompressed bytes;
    /// - `N`: allow at most `N` decompressed bytes.
    ///
    /// For trusted high-throughput FASTQ parsing, use `null`.
    max_output_bytes: ?usize = null,
};

/// Result from one `GzipInput.readInto` call.
pub const GzipInputRead = struct {
    /// Number of decompressed bytes written into the caller-provided output
    /// slice.
    written: usize,

    /// Whether the logical gzip stream is complete after this call.
    ///
    /// `end` may be `true` even when `written > 0`. In that case, the caller
    /// should process the returned bytes first, then treat the next refill as
    /// EOF.
    end: bool,
};

/// Pull-style gzip decompressor.
///
/// This is the fastest integration point for parsers that already own an
/// optimized scanning buffer. It inflates directly into the caller-provided
/// output slice:
///
/// ```text
/// compressed reader buffer -> zlib-ng -> caller output buffer
/// ```
///
/// For a FASTQ parser, the caller output slice should be the parser's free
/// buffer region, for example:
///
/// ```zig
/// const free = parser.buffer[parser.end..parser.capacity];
/// const r = try gzip.readInto(free);
/// parser.end += r.written;
/// if (r.end) parser.eof = true;
/// ```
///
/// Lifetime and movement rules:
///
/// - `input` must outlive this `GzipInput`;
/// - this value must not be moved after `init`;
/// - call `deinit` when finished.
///
/// The no-move rule matters because zlib-ng stores an internal back-pointer to
/// the stream address inside `Decompressor`.
pub const GzipInput = struct {
    /// Compressed upstream input.
    input: *std.Io.Reader,

    /// Native zlib-ng gzip decompressor.
    decompressor: Decompressor,

    /// Behavior options.
    options: GzipInputOptions,

    /// Detailed error retained for diagnostics.
    ///
    /// Most callers can simply use the returned error. This field is useful when
    /// `GzipInput` is embedded behind another abstraction and the outer layer
    /// maps errors.
    err: ?StreamError,

    /// True after the logical gzip stream has completed.
    ended: bool,

    /// Aggregate counters.
    stats: StreamStats,

    /// Initialize this gzip input in place.
    ///
    /// Prefer this API over a by-value constructor. `Decompressor` must have a
    /// stable address after initialization.
    pub fn init(
        self: *GzipInput,
        input: *std.Io.Reader,
        options: GzipInputOptions,
    ) InflateError!void {
        self.* = .{
            .input = input,
            .decompressor = .{},
            .options = options,
            .err = null,
            .ended = false,
            .stats = .{},
        };

        try self.decompressor.initGzip();
    }

    /// Release zlib-ng state.
    ///
    /// This does not own or close the upstream reader.
    pub fn deinit(self: *GzipInput) void {
        self.decompressor.deinit();

        self.input = undefined;
        self.err = null;
        self.ended = true;
        self.stats = .{};
    }

    /// Reset this gzip input for a new logical gzip stream from the current
    /// upstream reader position.
    ///
    /// This does not rewind or reset the upstream reader.
    pub fn reset(self: *GzipInput) InflateError!void {
        try self.decompressor.reset();

        self.err = null;
        self.ended = false;
        self.stats = .{};
    }

    /// Inflate decompressed bytes directly into `output`.
    ///
    /// This function does not allocate and does not use an intermediate
    /// decompressed buffer. It writes straight into the caller-provided slice.
    ///
    /// Contract:
    ///
    /// - `output.len` must be non-zero unless the stream has already ended;
    /// - returns `written > 0` when bytes were produced;
    /// - returns `end = true` when the logical gzip stream is complete;
    /// - may return `written > 0, end = true` on the final call;
    /// - after `end = true`, later calls return `{ .written = 0, .end = true }`.
    ///
    /// For parser refills, call this with the parser's free buffer region.
    pub fn readInto(
        self: *GzipInput,
        output: []u8,
    ) StreamError!GzipInputRead {
        if (self.ended) {
            return .{
                .written = 0,
                .end = true,
            };
        }

        if (output.len == 0) {
            return error.WriterBufferTooSmall;
        }

        var out_pos: usize = 0;

        while (out_pos < output.len) {
            const input = self.input.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => {
                    self.err = error.UnexpectedEnd;
                    return error.UnexpectedEnd;
                },
                error.ReadFailed => {
                    self.err = error.ReadFailed;
                    return error.ReadFailed;
                },
            };

            const dst = self.writableOutputSlice(output[out_pos..]);

            if (dst.len == 0 and isAtOutputCap(
                self.stats.decompressed_bytes,
                self.options.max_output_bytes,
            )) {
                const decision = self.finishAtOutputLimit() catch |err| {
                    self.err = err;
                    return err;
                };

                switch (decision) {
                    .done => {
                        self.ended = true;
                        return .{
                            .written = out_pos,
                            .end = true,
                        };
                    },
                    .continue_next_member => continue,
                }
            }

            const step = self.decompressor.decompress(input, dst) catch |err| {
                self.err = err;
                return err;
            };

            if (step.read != 0) {
                self.input.toss(step.read);
                self.stats.compressed_bytes += step.read;
            }

            if (step.written != 0) {
                out_pos += step.written;
                self.stats.decompressed_bytes += step.written;
            }

            if (step.read == 0 and step.written == 0 and step.status == .progress) {
                self.err = error.NoProgress;
                return error.NoProgress;
            }

            switch (step.status) {
                .progress => {
                    if (isAtOutputCap(
                        self.stats.decompressed_bytes,
                        self.options.max_output_bytes,
                    )) {
                        const decision = self.finishAtOutputLimit() catch |err| {
                            self.err = err;
                            return err;
                        };

                        switch (decision) {
                            .done => {
                                self.ended = true;
                                return .{
                                    .written = out_pos,
                                    .end = true,
                                };
                            },
                            .continue_next_member => continue,
                        }
                    }

                    if (out_pos == output.len) {
                        return .{
                            .written = out_pos,
                            .end = false,
                        };
                    }

                    continue;
                },

                .need_input_or_output => {
                    if (out_pos != 0) {
                        return .{
                            .written = out_pos,
                            .end = false,
                        };
                    }

                    // At this point we supplied at least one byte of input and
                    // non-zero output capacity. A no-progress buffer signal
                    // would otherwise spin forever in this direct driver.
                    self.err = error.NoProgress;
                    return error.NoProgress;
                },

                .end => {
                    self.stats.members += 1;

                    const decision = self.afterMember() catch |err| {
                        self.err = err;
                        return err;
                    };

                    switch (decision) {
                        .done => {
                            self.ended = true;
                            return .{
                                .written = out_pos,
                                .end = true,
                            };
                        },

                        .continue_next_member => {
                            if (out_pos == output.len) {
                                return .{
                                    .written = out_pos,
                                    .end = false,
                                };
                            }

                            continue;
                        },
                    }
                },
            }
        }

        return .{
            .written = out_pos,
            .end = false,
        };
    }

    /// Return an output slice capped by `max_output_bytes`.
    ///
    /// This borrows from the caller-provided destination. It does not allocate.
    fn writableOutputSlice(
        self: *const GzipInput,
        available_output: []u8,
    ) []u8 {
        if (self.options.max_output_bytes) |cap| {
            if (self.stats.decompressed_bytes >= cap) {
                return &.{};
            }

            const remaining = cap - self.stats.decompressed_bytes;
            return available_output[0..@min(available_output.len, remaining)];
        }

        return available_output;
    }

    /// Handle transition after one gzip member reaches end-of-stream.
    fn afterMember(self: *GzipInput) StreamError!AfterMember {
        if (!self.options.allow_concatenated_members) {
            _ = self.input.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return .done,
                error.ReadFailed => return error.ReadFailed,
            };

            return error.TrailingData;
        }

        _ = self.input.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => return .done,
            error.ReadFailed => return error.ReadFailed,
        };

        try self.decompressor.reset();
        return .continue_next_member;
    }

    /// Continue driving zlib-ng after the configured output cap has been reached.
    ///
    /// This proves whether the gzip stream ends exactly at the cap or needs to
    /// emit at least one additional byte.
    ///
    /// It uses a one-byte scratch output buffer. If zlib-ng writes into scratch,
    /// the cap would be exceeded.
    fn finishAtOutputLimit(self: *GzipInput) StreamError!AfterMember {
        while (true) {
            const input = self.input.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => return error.UnexpectedEnd,
                error.ReadFailed => return error.ReadFailed,
            };

            var scratch: [1]u8 = undefined;

            const step = try self.decompressor.decompress(input, scratch[0..]);

            if (step.read != 0) {
                self.input.toss(step.read);
                self.stats.compressed_bytes += step.read;
            }

            if (step.written != 0) {
                return error.OutputLimitExceeded;
            }

            if (step.read == 0 and step.written == 0) {
                switch (step.status) {
                    .progress, .need_input_or_output => return error.NoProgress,
                    .end => {},
                }
            }

            switch (step.status) {
                .progress, .need_input_or_output => continue,

                .end => {
                    self.stats.members += 1;

                    switch (try self.afterMember()) {
                        .done => return .done,

                        .continue_next_member => {
                            // The cap is still reached. Continue proving that
                            // the next concatenated member also emits zero
                            // additional bytes.
                            continue;
                        },
                    }
                },
            }
        }
    }
};

test {
    _ = @import("tests/zgz_tests.zig");
}