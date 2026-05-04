//! Deterministic gzip test vectors for zgz.
//!
//! These vectors are intentionally tiny and checked into source so unit tests do
//! not depend on external tools like `gzip`, `zcat`, or Python.
//!
//! The valid gzip streams were generated with:
//!
//! ```sh
//! python3 - <<'PY'
//! import gzip
//! print(gzip.compress(b"hello\n", compresslevel=6, mtime=0))
//! PY
//! ```
//!
//! `mtime=0` makes the gzip header deterministic. Python sets the OS byte to
//! `0xff` in these vectors.
//!
//! Keep this file boring. Boring test fixtures are good test fixtures, despite
//! what the chaos goblins suggest.

/// Raw empty payload.
pub const empty_raw = "";

/// Raw hello payload.
pub const hello_raw = "hello\n";

/// Raw world payload.
pub const world_raw = "world\n";

/// Raw concatenated logical output for `concat_hello_world_gz`.
pub const hello_world_raw = hello_raw ++ world_raw;

/// Raw lorem payload.
pub const lorem_raw = "Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n";

/// Small FASTQ-like payload.
///
/// This is not meant to be biologically meaningful. It exists to exercise a
/// workload shape similar to short-read text data: small records, repeated
/// symbols, quality lines, and newlines.
pub const fastq_raw =
    "@r1\n" ++
    "ACGTNACGTN\n" ++
    "+\n" ++
    "IIIIIIIIII\n" ++
    "@r2\n" ++
    "TGCAATGCAA\n" ++
    "+\n" ++
    "JJJJJJJJJJ\n";

/// Valid gzip stream whose decompressed payload is `empty_raw`.
pub const empty_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x03, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

/// Valid gzip stream whose decompressed payload is `hello_raw`.
pub const hello_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xcb, 0x48,
    0xcd, 0xc9, 0xc9, 0xe7, 0x02, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00,
    0x00, 0x00,
};

/// Valid gzip stream whose decompressed payload is `lorem_raw`.
pub const lorem_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x05, 0xc1,
    0xd1, 0x09, 0xc0, 0x20, 0x0c, 0x05, 0xc0, 0xff, 0x4e, 0xf1, 0x06, 0x28,
    0x9d, 0xc4, 0x25, 0x24, 0x06, 0x79, 0x60, 0x8c, 0x24, 0x71, 0xff, 0xde,
    0x35, 0x0f, 0x35, 0xf0, 0xe4, 0x35, 0x0c, 0x5f, 0x1e, 0x48, 0x16, 0xba,
    0x69, 0xbd, 0x10, 0xdf, 0xa9, 0x52, 0x5a, 0x37, 0xd0, 0x07, 0x0f, 0x53,
    0xb8, 0x27, 0x74, 0xb1, 0xbe, 0xe7, 0x07, 0x3a, 0xed, 0x29, 0xfa, 0x39,
    0x00, 0x00, 0x00,
};

/// Valid gzip stream whose decompressed payload is `fastq_raw`.
pub const fastq_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0x73, 0x28,
    0x32, 0xe4, 0x72, 0x74, 0x76, 0x0f, 0xf1, 0x03, 0x13, 0x5c, 0xda, 0x5c,
    0x9e, 0x70, 0xc0, 0xe5, 0x50, 0x64, 0xc4, 0x15, 0xe2, 0xee, 0xec, 0xe8,
    0x08, 0x26, 0x80, 0x72, 0x5e, 0x70, 0xc0, 0x05, 0x00, 0x8f, 0xfc, 0xd3,
    0x80, 0x38, 0x00, 0x00, 0x00,
};

/// Two valid gzip members concatenated together.
///
/// With `.allow_concatenated_members = true`, this should decode to
/// `hello_world_raw`.
///
/// With `.allow_concatenated_members = false`, decoding should stop after the
/// first member and report trailing input.
pub const concat_hello_world_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xcb, 0x48,
    0xcd, 0xc9, 0xc9, 0xe7, 0x02, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00,
    0x00, 0x00, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff,
    0x2b, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00, 0xa8, 0x61, 0x38, 0xdd,
    0x06, 0x00, 0x00, 0x00,
};

/// A valid `hello_gz` member followed by non-gzip trailing bytes.
///
/// This should be rejected as trailing data. With concatenation enabled, the
/// next-member decode should fail because `junk` is not a gzip header. With
/// concatenation disabled, the trailing bytes should be rejected immediately.
pub const hello_trailing_junk_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xcb, 0x48,
    0xcd, 0xc9, 0xc9, 0xe7, 0x02, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00,
    0x00, 0x00, 0x6a, 0x75, 0x6e, 0x6b,
};

/// A truncated `hello_gz` stream missing the final two bytes of the gzip
/// trailer.
///
/// This should fail as an incomplete stream.
pub const hello_truncated_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xcb, 0x48,
    0xcd, 0xc9, 0xc9, 0xe7, 0x02, 0x00, 0x20, 0x30, 0x3a, 0x36, 0x06, 0x00,
};

/// A `hello_gz` stream with a corrupted CRC-32 byte in the gzip trailer.
///
/// This should fail integrity validation.
pub const hello_bad_crc_gz = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xcb, 0x48,
    0xcd, 0xc9, 0xc9, 0xe7, 0x02, 0x00, 0x21, 0x30, 0x3a, 0x36, 0x06, 0x00,
    0x00, 0x00,
};

/// Bytes that are not gzip data at all.
pub const not_gzip = "not gzip, sadly";

/// Empty non-gzip input.
pub const empty_input = "";

/// Small collection of valid gzip vectors for table-driven tests.
pub const valid_cases = [_]Case{
    .{
        .name = "empty",
        .compressed = empty_gz[0..],
        .expected = empty_raw,
    },
    .{
        .name = "hello",
        .compressed = hello_gz[0..],
        .expected = hello_raw,
    },
    .{
        .name = "lorem",
        .compressed = lorem_gz[0..],
        .expected = lorem_raw,
    },
    .{
        .name = "fastq",
        .compressed = fastq_gz[0..],
        .expected = fastq_raw,
    },
};

/// Valid concatenated-member cases.
pub const concatenated_cases = [_]Case{
    .{
        .name = "hello-world",
        .compressed = concat_hello_world_gz[0..],
        .expected = hello_world_raw,
    },
};

/// Invalid or incomplete gzip streams for negative tests.
pub const invalid_cases = [_]InvalidCase{
    .{
        .name = "not-gzip",
        .compressed = not_gzip,
    },
    .{
        .name = "empty-input",
        .compressed = empty_input,
    },
    .{
        .name = "truncated",
        .compressed = hello_truncated_gz[0..],
    },
    .{
        .name = "bad-crc",
        .compressed = hello_bad_crc_gz[0..],
    },
    .{
        .name = "trailing-junk",
        .compressed = hello_trailing_junk_gz[0..],
    },
};

/// Valid gzip vector case.
pub const Case = struct {
    /// Human-readable case name for failure diagnostics.
    name: []const u8,

    /// Gzip-compressed bytes.
    compressed: []const u8,

    /// Expected decompressed bytes.
    expected: []const u8,
};

/// Invalid gzip vector case.
pub const InvalidCase = struct {
    /// Human-readable case name for failure diagnostics.
    name: []const u8,

    /// Invalid, truncated, or otherwise unacceptable gzip bytes.
    compressed: []const u8,
};