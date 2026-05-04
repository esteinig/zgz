//! Unit tests for zgz.
//!
//! These tests focus on library behavior, not CLI behavior. The CLI should be
//! tested with shell-level oracle checks against `zcat`/`gzip -dc`.
//!
//! Coverage goals:
//!
//! - deterministic gzip vectors
//! - low-level chunked decompression
//! - streaming reader-to-writer path
//! - concatenated gzip members
//! - trailing data handling
//! - output caps
//! - invalid/truncated/corrupt input
//! - post-end Decompressor misuse
//! - reset/reuse behavior

const std = @import("std");
const zgz = @import("../zgz.zig");
const vectors = @import("vectors.zig");

const testing = std.testing;

test "Decompressor decodes gzip vector with a single large output buffer" {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var output: [128]u8 = undefined;
    const written = try inflateWholeWithExistingDecompressor(
        &d,
        vectors.hello_gz[0..],
        output[0..],
    );

    try testing.expectEqualStrings(vectors.hello_raw, output[0..written]);
}

test "Decompressor handles one-byte output chunks" {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var in_pos: usize = 0;
    var output: [vectors.hello_raw.len]u8 = undefined;
    var out_pos: usize = 0;

    while (true) {
        var tiny: [1]u8 = undefined;

        const step = try d.decompress(
            vectors.hello_gz[in_pos..],
            tiny[0..],
        );

        in_pos += step.read;

        if (step.written != 0) {
            try testing.expectEqual(@as(usize, 1), step.written);
            try testing.expect(out_pos < output.len);
            output[out_pos] = tiny[0];
            out_pos += 1;
        }

        switch (step.status) {
            .progress, .need_input_or_output => {
                try testing.expect(step.read != 0 or step.written != 0 or step.status == .need_input_or_output);
            },
            .end => break,
        }
    }

    try testing.expectEqualStrings(vectors.hello_raw, output[0..out_pos]);
}

test "Decompressor handles one-byte input chunks" {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var output: [128]u8 = undefined;
    var out_pos: usize = 0;

    var in_pos: usize = 0;
    while (true) {
        const end = @min(in_pos + 1, vectors.hello_gz.len);

        const step = try d.decompress(
            vectors.hello_gz[in_pos..end],
            output[out_pos..],
        );

        in_pos += step.read;
        out_pos += step.written;

        switch (step.status) {
            .progress, .need_input_or_output => {
                if (in_pos == vectors.hello_gz.len and step.written == 0) {
                    // Give zlib-ng one final zero-input call to surface stream end.
                    const final = try d.decompress(&.{}, output[out_pos..]);
                    out_pos += final.written;
                    if (final.status == .end) break;
                }
            },
            .end => break,
        }
    }

    try testing.expectEqualStrings(vectors.hello_raw, output[0..out_pos]);
}

test "Decompressor returns StreamEnded after end without reset" {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var output: [128]u8 = undefined;
    _ = try inflateWholeWithExistingDecompressor(
        &d,
        vectors.hello_gz[0..],
        output[0..],
    );

    try testing.expectError(
        error.StreamEnded,
        d.decompress(&.{}, output[0..]),
    );
}

test "Decompressor reset allows reuse" {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var output: [128]u8 = undefined;

    const first_len = try inflateWholeWithExistingDecompressor(
        &d,
        vectors.hello_gz[0..],
        output[0..],
    );
    try testing.expectEqualStrings(vectors.hello_raw, output[0..first_len]);

    try d.reset();

    const second_len = try inflateWholeWithExistingDecompressor(
        &d,
        vectors.lorem_gz[0..],
        output[0..],
    );
    try testing.expectEqualStrings(vectors.lorem_raw, output[0..second_len]);
}

test "Decompressor reset before init fails" {
    var d: zgz.Decompressor = .{};

    try testing.expectError(
        error.InvalidState,
        d.reset(),
    );
}

test "Decompressor decompress before init fails" {
    var d: zgz.Decompressor = .{};
    var output: [16]u8 = undefined;

    try testing.expectError(
        error.InvalidState,
        d.decompress(vectors.hello_gz[0..], output[0..]),
    );
}

test "decompress decodes fixed-buffer stream" {
    var reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    const stats = try zgz.decompress(
        &reader,
        &writer,
        .{},
    );

    const actual = fixedWriterWritten(&writer, output_storage[0..]);

    try testing.expectEqualStrings(vectors.hello_raw, actual);
    try testing.expectEqual(vectors.hello_gz.len, stats.compressed_bytes);
    try testing.expectEqual(vectors.hello_raw.len, stats.decompressed_bytes);
    try testing.expectEqual(@as(usize, 1), stats.members);
}

test "decompress decodes valid gzip vectors" {
    inline for (vectors.valid_cases) |case| {
        var reader: std.Io.Reader = .fixed(case.compressed);

        var output_storage: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(output_storage[0..]);

        const stats = try zgz.decompress(
            &reader,
            &writer,
            .{},
        );

        const actual = fixedWriterWritten(&writer, output_storage[0..]);

        try testing.expectEqualStrings(case.expected, actual);
        try testing.expectEqual(case.expected.len, stats.decompressed_bytes);
        try testing.expectEqual(@as(usize, 1), stats.members);
    }
}

test "decompress decodes concatenated gzip members" {
    var reader: std.Io.Reader = .fixed(vectors.concat_hello_world_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    const stats = try zgz.decompress(
        &reader,
        &writer,
        .{},
    );

    const actual = fixedWriterWritten(&writer, output_storage[0..]);

    try testing.expectEqualStrings(vectors.hello_world_raw, actual);
    try testing.expectEqual(vectors.hello_world_raw.len, stats.decompressed_bytes);
    try testing.expectEqual(@as(usize, 2), stats.members);
}

test "decompress rejects concatenated gzip members when disabled" {
    var reader: std.Io.Reader = .fixed(vectors.concat_hello_world_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.TrailingData,
        zgz.decompress(
            &reader,
            &writer,
            .{
                .allow_concatenated_members = false,
            },
        ),
    );
}

test "decompress enforces max output cap" {
    var reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.OutputLimitExceeded,
        zgz.decompress(
            &reader,
            &writer,
            .{
                .max_output_bytes = vectors.hello_raw.len - 1,
            },
        ),
    );
}

test "decompress allows exact max output cap" {
    var reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    const stats = try zgz.decompress(
        &reader,
        &writer,
        .{
            .max_output_bytes = vectors.hello_raw.len,
        },
    );

    const actual = fixedWriterWritten(&writer, output_storage[0..]);

    try testing.expectEqualStrings(vectors.hello_raw, actual);
    try testing.expectEqual(vectors.hello_raw.len, stats.decompressed_bytes);
}

test "decompress rejects invalid gzip bytes" {
    var reader: std.Io.Reader = .fixed(vectors.not_gzip);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.InvalidData,
        zgz.decompress(
            &reader,
            &writer,
            .{},
        ),
    );
}

test "decompress rejects truncated gzip stream" {
    var reader: std.Io.Reader = .fixed(vectors.hello_truncated_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.UnexpectedEnd,
        zgz.decompress(
            &reader,
            &writer,
            .{},
        ),
    );
}

test "decompress rejects bad CRC" {
    var reader: std.Io.Reader = .fixed(vectors.hello_bad_crc_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.InvalidData,
        zgz.decompress(
            &reader,
            &writer,
            .{},
        ),
    );
}

test "decompress rejects trailing junk" {
    var reader: std.Io.Reader = .fixed(vectors.hello_trailing_junk_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.InvalidData,
        zgz.decompress(
            &reader,
            &writer,
            .{},
        ),
    );
}

test "decompress rejects trailing junk when concatenation disabled" {
    var reader: std.Io.Reader = .fixed(vectors.hello_trailing_junk_gz[0..]);

    var output_storage: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.TrailingData,
        zgz.decompress(
            &reader,
            &writer,
            .{
                .allow_concatenated_members = false,
            },
        ),
    );
}

test "decompress fails with too-small fixed writer" {
    var reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var output_storage: [vectors.hello_raw.len - 1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    const result = zgz.decompress(
        &reader,
        &writer,
        .{},
    );

    try testing.expectError(error.WriteFailed, result);
}

test "decompress decodes empty gzip stream" {
    var reader: std.Io.Reader = .fixed(vectors.empty_gz[0..]);

    var output_storage: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    const stats = try zgz.decompress(
        &reader,
        &writer,
        .{},
    );

    const actual = fixedWriterWritten(&writer, output_storage[0..]);

    try testing.expectEqualStrings(vectors.empty_raw, actual);
    try testing.expectEqual(@as(usize, 0), stats.decompressed_bytes);
    try testing.expectEqual(@as(usize, 1), stats.members);
}

test "zlibVersion returns non-empty string" {
    const version = zgz.zlibVersion();

    try testing.expect(version.len > 0);
}

/// Helper: inflate a complete gzip member using an already-initialized
/// Decompressor.
///
/// The caller owns `output`. This helper intentionally drives the low-level API
/// directly to test the state machine without `std.Io`.
fn inflateWholeWithExistingDecompressor(
    d: *zgz.Decompressor,
    compressed: []const u8,
    output: []u8,
) !usize {
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
                if (step.read == 0 and step.written == 0 and step.status == .progress) {
                    return error.NoProgress;
                }

                if (out_pos == output.len) {
                    return error.OutputBufferTooSmall;
                }
            },
            .end => return out_pos,
        }
    }
}


test "all valid vectors decode through high-level streaming API" {
    inline for (vectors.valid_cases) |case| {
        try expectStreamingDecode(case.compressed, case.expected);
    }
}

test "all valid vectors decode through low-level Decompressor full-slice API" {
    inline for (vectors.valid_cases) |case| {
        try expectLowLevelDecode(case.compressed, case.expected);
    }
}

test "all valid vectors decode with one-byte output chunks" {
    inline for (vectors.valid_cases) |case| {
        try expectLowLevelDecodeOneByteOutput(case.compressed, case.expected);
    }
}

test "all valid vectors decode with one-byte input chunks" {
    inline for (vectors.valid_cases) |case| {
        try expectLowLevelDecodeOneByteInput(case.compressed, case.expected);
    }
}

test "all valid vectors reject max output cap below expected size" {
    inline for (vectors.valid_cases) |case| {
        if (case.expected.len == 0) continue;

        var reader: std.Io.Reader = .fixed(case.compressed);

        var output_storage: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(output_storage[0..]);

        try testing.expectError(
            error.OutputLimitExceeded,
            zgz.decompress(
                &reader,
                &writer,
                .{
                    .max_output_bytes = case.expected.len - 1,
                },
            ),
        );
    }
}

test "all concatenated vectors decode through high-level streaming API" {
    inline for (vectors.concatenated_cases) |case| {
        try expectStreamingDecode(case.compressed, case.expected);
    }
}

test "all concatenated vectors reject when concatenation disabled" {
    inline for (vectors.concatenated_cases) |case| {
        var reader: std.Io.Reader = .fixed(case.compressed);

        var output_storage: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(output_storage[0..]);

        try testing.expectError(
            error.TrailingData,
            zgz.decompress(
                &reader,
                &writer,
                .{
                    .allow_concatenated_members = false,
                },
            ),
        );
    }
}

test "all invalid vectors fail through high-level streaming API" {
    inline for (vectors.invalid_cases) |case| {
        var reader: std.Io.Reader = .fixed(case.compressed);

        var output_storage: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(output_storage[0..]);

        const result = zgz.decompress(
            &reader,
            &writer,
            .{},
        );

        if (result) |_| {
            std.debug.print("invalid vector unexpectedly decoded: {s}\n", .{case.name});
            return error.InvalidVectorDecoded;
        } else |_| {
            // Any decompression error is acceptable for this broad table test.
            // More specific invalid-case tests can assert exact error values.
        }
    }
}

test "all non-empty valid vectors allow exact max output cap" {
    inline for (vectors.valid_cases) |case| {
        if (case.expected.len == 0) continue;

        var reader: std.Io.Reader = .fixed(case.compressed);

        var output_storage: [512]u8 = undefined;
        try testing.expect(case.expected.len <= output_storage.len);

        var writer: std.Io.Writer = .fixed(output_storage[0..]);

        const stats = try zgz.decompress(
            &reader,
            &writer,
            .{
                .max_output_bytes = case.expected.len,
            },
        );

        const actual = fixedWriterWritten(&writer, output_storage[0..]);

        try testing.expectEqualStrings(case.expected, actual);
        try testing.expectEqual(case.expected.len, stats.decompressed_bytes);
    }
}

test "library allows empty gzip with zero max output cap" {
    var reader: std.Io.Reader = .fixed(vectors.empty_gz[0..]);

    var output_storage: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    const stats = try zgz.decompress(
        &reader,
        &writer,
        .{
            .max_output_bytes = 0,
        },
    );

    const actual = fixedWriterWritten(&writer, output_storage[0..]);

    try testing.expectEqualStrings("", actual);
    try testing.expectEqual(@as(usize, 0), stats.decompressed_bytes);
    try testing.expectEqual(@as(usize, 1), stats.members);
}

test "library rejects non-empty gzip with zero max output cap" {
    var reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var output_storage: [1]u8 = undefined;
    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    try testing.expectError(
        error.OutputLimitExceeded,
        zgz.decompress(
            &reader,
            &writer,
            .{
                .max_output_bytes = 0,
            },
        ),
    );
}

test "GzipInput decodes valid vectors directly into caller buffer" {
    inline for (vectors.valid_cases) |case| {
        try expectGzipInputDecode(case.compressed, case.expected);
    }
}

test "GzipInput decodes valid vectors with tiny output chunks" {
    inline for (vectors.valid_cases) |case| {
        try expectGzipInputDecodeWithChunkSize(case.compressed, case.expected, 1);
        try expectGzipInputDecodeWithChunkSize(case.compressed, case.expected, 2);
        try expectGzipInputDecodeWithChunkSize(case.compressed, case.expected, 7);
    }
}

test "GzipInput decodes valid vectors with exact output-sized destination" {
    inline for (vectors.valid_cases) |case| {
        var input_reader: std.Io.Reader = .fixed(case.compressed);

        var gzip: zgz.GzipInput = undefined;
        try gzip.initInPlace(&input_reader, .{});
        defer gzip.deinit();

        const output = try testing.allocator.alloc(u8, @max(case.expected.len, 1));
        defer testing.allocator.free(output);

        var out_pos: usize = 0;
        while (true) {
            const free = output[out_pos..@max(case.expected.len, 1)];
            const r = try gzip.readInto(free);

            out_pos += r.written;

            if (r.end) break;

            if (r.written == 0) {
                return error.TestNoProgress;
            }
        }

        try testing.expectEqual(case.expected.len, out_pos);
        try testing.expectEqualStrings(case.expected, output[0..out_pos]);
        try testing.expectEqual(case.expected.len, gzip.stats.decompressed_bytes);
    }
}

test "GzipInput returns end=true after final bytes are produced" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [vectors.hello_raw.len]u8 = undefined;

    const r = try gzip.readInto(output[0..]);

    try testing.expectEqual(vectors.hello_raw.len, r.written);
    try testing.expect(r.end);
    try testing.expectEqualStrings(vectors.hello_raw, output[0..r.written]);
}

test "GzipInput subsequent read after end returns zero end" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    const first = try gzip.readInto(output[0..]);
    try testing.expect(first.end);

    const second = try gzip.readInto(output[0..]);

    try testing.expectEqual(@as(usize, 0), second.written);
    try testing.expect(second.end);
}

test "GzipInput decodes concatenated gzip members" {
    var input_reader: std.Io.Reader = .fixed(vectors.concat_hello_world_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [128]u8 = undefined;
    const actual_len = try readAllGzipInput(&gzip, output[0..]);

    try testing.expectEqualStrings(vectors.hello_world_raw, output[0..actual_len]);
    try testing.expectEqual(@as(usize, 2), gzip.stats.members);
    try testing.expectEqual(vectors.hello_world_raw.len, gzip.stats.decompressed_bytes);
}

test "GzipInput rejects concatenated gzip members when disabled" {
    var input_reader: std.Io.Reader = .fixed(vectors.concat_hello_world_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{
        .allow_concatenated_members = false,
    });
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    try testing.expectError(
        error.TrailingData,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput rejects trailing junk" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_trailing_junk_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    try testing.expectError(
        error.InvalidData,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput rejects trailing junk when concatenation disabled" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_trailing_junk_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{
        .allow_concatenated_members = false,
    });
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    try testing.expectError(
        error.TrailingData,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput rejects invalid gzip bytes" {
    var input_reader: std.Io.Reader = .fixed(vectors.not_gzip);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    try testing.expectError(
        error.InvalidData,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput rejects truncated gzip stream" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_truncated_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    try testing.expectError(
        error.UnexpectedEnd,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput rejects bad CRC" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_bad_crc_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    try testing.expectError(
        error.InvalidData,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput enforces output cap below expected size" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{
        .max_output_bytes = vectors.hello_raw.len - 1,
    });
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    try testing.expectError(
        error.OutputLimitExceeded,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput allows exact output cap for valid vectors" {
    inline for (vectors.valid_cases) |case| {
        var input_reader: std.Io.Reader = .fixed(case.compressed);

        var gzip: zgz.GzipInput = undefined;
        try gzip.initInPlace(&input_reader, .{
            .max_output_bytes = case.expected.len,
        });
        defer gzip.deinit();

        var output: [512]u8 = undefined;
        try testing.expect(case.expected.len <= output.len);

        const actual_len = try readAllGzipInput(&gzip, output[0..]);

        try testing.expectEqualStrings(case.expected, output[0..actual_len]);
        try testing.expectEqual(case.expected.len, gzip.stats.decompressed_bytes);
    }
}

test "GzipInput allows empty gzip with zero output cap" {
    var input_reader: std.Io.Reader = .fixed(vectors.empty_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{
        .max_output_bytes = 0,
    });
    defer gzip.deinit();

    var output: [1]u8 = undefined;

    const r = try gzip.readInto(output[0..]);

    try testing.expectEqual(@as(usize, 0), r.written);
    try testing.expect(r.end);
    try testing.expectEqual(@as(usize, 0), gzip.stats.decompressed_bytes);
    try testing.expectEqual(@as(usize, 1), gzip.stats.members);
}

test "GzipInput rejects non-empty gzip with zero output cap" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{
        .max_output_bytes = 0,
    });
    defer gzip.deinit();

    var output: [1]u8 = undefined;

    try testing.expectError(
        error.OutputLimitExceeded,
        gzip.readInto(output[0..]),
    );
}

test "GzipInput reset clears state for same upstream reader position only" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [128]u8 = undefined;

    const first_len = try readAllGzipInput(&gzip, output[0..]);
    try testing.expectEqualStrings(vectors.hello_raw, output[0..first_len]);
    try testing.expect(gzip.ended);

    try gzip.reset();

    // The upstream reader is already at EOF. reset() resets zlib-ng state, but
    // it does not rewind the input reader.
    try testing.expectError(
        error.UnexpectedEnd,
        readAllGzipInput(&gzip, output[0..]),
    );
}

test "GzipInput readInto rejects zero-length output before EOF" {
    var input_reader: std.Io.Reader = .fixed(vectors.hello_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    try testing.expectError(
        error.WriterBufferTooSmall,
        gzip.readInto(&.{}),
    );
}

test "GzipInput readInto zero-length output after EOF returns end" {
    var input_reader: std.Io.Reader = .fixed(vectors.empty_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [1]u8 = undefined;
    const first = try gzip.readInto(output[0..]);
    try testing.expect(first.end);

    const second = try gzip.readInto(&.{});
    try testing.expectEqual(@as(usize, 0), second.written);
    try testing.expect(second.end);
}

test "GzipInput exposes useful stats after successful decode" {
    var input_reader: std.Io.Reader = .fixed(vectors.fastq_gz[0..]);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [512]u8 = undefined;
    const actual_len = try readAllGzipInput(&gzip, output[0..]);

    try testing.expectEqualStrings(vectors.fastq_raw, output[0..actual_len]);
    try testing.expectEqual(vectors.fastq_gz.len, gzip.stats.compressed_bytes);
    try testing.expectEqual(vectors.fastq_raw.len, gzip.stats.decompressed_bytes);
    try testing.expectEqual(@as(usize, 1), gzip.stats.members);
}

/// Helper: return bytes written into a fixed `std.Io.Writer`.
///
/// Zig 0.16's fixed writer tracks progress internally. In current 0.16 builds,
/// `end` is the logical write position. If the local stdlib exposes a renamed
/// field, change this helper rather than every test.
fn fixedWriterWritten(
    writer: *const std.Io.Writer,
    backing: []const u8,
) []const u8 {
    return backing[0..writer.end];
}

fn expectStreamingDecode(
    compressed: []const u8,
    expected: []const u8,
) !void {
    var reader: std.Io.Reader = .fixed(compressed);

    var output_storage: [512]u8 = undefined;
    try testing.expect(expected.len <= output_storage.len);

    var writer: std.Io.Writer = .fixed(output_storage[0..]);

    const stats = try zgz.decompress(
        &reader,
        &writer,
        .{},
    );

    const actual = fixedWriterWritten(&writer, output_storage[0..]);

    try testing.expectEqualStrings(expected, actual);
    try testing.expectEqual(expected.len, stats.decompressed_bytes);
}

fn expectLowLevelDecode(
    compressed: []const u8,
    expected: []const u8,
) !void {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var output: [512]u8 = undefined;
    try testing.expect(expected.len <= output.len);

    const written = try inflateWholeWithExistingDecompressor(
        &d,
        compressed,
        output[0..],
    );

    try testing.expectEqualStrings(expected, output[0..written]);
}

fn expectLowLevelDecodeOneByteOutput(
    compressed: []const u8,
    expected: []const u8,
) !void {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var in_pos: usize = 0;

    var output: [512]u8 = undefined;
    try testing.expect(expected.len <= output.len);

    var out_pos: usize = 0;

    while (true) {
        var tiny: [1]u8 = undefined;

        const step = try d.decompress(
            compressed[in_pos..],
            tiny[0..],
        );

        in_pos += step.read;

        if (step.written != 0) {
            try testing.expectEqual(@as(usize, 1), step.written);
            try testing.expect(out_pos < output.len);

            output[out_pos] = tiny[0];
            out_pos += 1;
        }

        switch (step.status) {
            .progress, .need_input_or_output => {
                if (step.read == 0 and step.written == 0 and step.status == .progress) {
                    return error.NoProgress;
                }
            },
            .end => break,
        }
    }

    try testing.expectEqualStrings(expected, output[0..out_pos]);
}

fn expectLowLevelDecodeOneByteInput(
    compressed: []const u8,
    expected: []const u8,
) !void {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var output: [512]u8 = undefined;
    try testing.expect(expected.len <= output.len);

    var out_pos: usize = 0;
    var in_pos: usize = 0;

    while (true) {
        const end = @min(in_pos + 1, compressed.len);

        const step = try d.decompress(
            compressed[in_pos..end],
            output[out_pos..],
        );

        in_pos += step.read;
        out_pos += step.written;

        switch (step.status) {
            .progress, .need_input_or_output => {
                if (in_pos == compressed.len and step.written == 0) {
                    const final = try d.decompress(&.{}, output[out_pos..]);
                    out_pos += final.written;

                    if (final.status == .end) break;

                    if (final.read == 0 and final.written == 0 and final.status == .progress) {
                        return error.NoProgress;
                    }
                }
            },
            .end => break,
        }
    }

    try testing.expectEqualStrings(expected, output[0..out_pos]);
}

fn lowLevelDecodeAlloc(compressed: []const u8) ![]u8 {
    var d: zgz.Decompressor = .{};
    try d.initGzip();
    defer d.deinit();

    var output = std.ArrayList(u8).empty;
    defer output.deinit(testing.allocator);

    var in_pos: usize = 0;

    while (true) {
        var chunk: [128]u8 = undefined;

        const step = try d.decompress(
            compressed[in_pos..],
            chunk[0..],
        );

        in_pos += step.read;

        if (step.written != 0) {
            try output.appendSlice(testing.allocator, chunk[0..step.written]);
        }

        switch (step.status) {
            .progress => {
                if (step.read == 0 and step.written == 0) {
                    return error.NoProgress;
                }
            },

            .need_input_or_output => {
                if (step.read == 0 and step.written == 0) {
                    if (in_pos >= compressed.len) {
                        return error.UnexpectedEnd;
                    }

                    return error.NoProgress;
                }
            },

            .end => {
                if (in_pos != compressed.len) {
                    return error.TrailingData;
                }

                return try output.toOwnedSlice(testing.allocator);
            },
        }
    }
}

fn expectGzipInputDecode(
    compressed: []const u8,
    expected: []const u8,
) !void {
    var input_reader: std.Io.Reader = .fixed(compressed);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [512]u8 = undefined;
    try testing.expect(expected.len <= output.len);

    const actual_len = try readAllGzipInput(&gzip, output[0..]);

    try testing.expectEqualStrings(expected, output[0..actual_len]);
    try testing.expectEqual(expected.len, gzip.stats.decompressed_bytes);
}

fn expectGzipInputDecodeWithChunkSize(
    compressed: []const u8,
    expected: []const u8,
    comptime chunk_size: usize,
) !void {
    std.debug.assert(chunk_size != 0);

    var input_reader: std.Io.Reader = .fixed(compressed);

    var gzip: zgz.GzipInput = undefined;
    try gzip.initInPlace(&input_reader, .{});
    defer gzip.deinit();

    var output: [512]u8 = undefined;
    try testing.expect(expected.len <= output.len);

    var out_pos: usize = 0;

    while (true) {
        var chunk: [chunk_size]u8 = undefined;

        const r = try gzip.readInto(chunk[0..]);

        if (r.written != 0) {
            try testing.expect(out_pos + r.written <= output.len);
            @memcpy(output[out_pos..][0..r.written], chunk[0..r.written]);
            out_pos += r.written;
        }

        if (r.end) break;

        if (r.written == 0) {
            return error.TestNoProgress;
        }
    }

    try testing.expectEqualStrings(expected, output[0..out_pos]);
    try testing.expectEqual(expected.len, gzip.stats.decompressed_bytes);
}

fn readAllGzipInput(
    gzip: *zgz.GzipInput,
    output: []u8,
) !usize {
    var out_pos: usize = 0;

    while (true) {
        if (out_pos == output.len and !gzip.ended) {
            return error.OutputBufferTooSmall;
        }

        const r = try gzip.readInto(output[out_pos..]);

        out_pos += r.written;

        if (r.end) {
            return out_pos;
        }

        if (r.written == 0) {
            return error.TestNoProgress;
        }
    }
}