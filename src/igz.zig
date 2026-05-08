//! `.igz` chunking, indexing, sharding, repacking, and inspection support for zgz.
//!
//! Terminology used by this module:
//!
//! - **gzip member**: one complete gzip stream with its own header, DEFLATE body,
//!   and trailer. The gzip specification permits concatenating multiple members;
//!   most gzip readers decode the concatenation as one logical byte stream.
//! - **chunk**: one record-aligned FASTQ/FASTA range selected by zgz.
//! - **`.igz` index**: zgz's binary sidecar index for a chunked gzip file.
//!   The data file remains `.gz`; the `.igz` file records the member offsets,
//!   record counts, uncompressed byte counts, and sequencing-mode metadata.
//! - **embedded IGZ prelude**: one or more prepended zero-length gzip members
//!   whose FEXTRA fields contain a compact index. The first control member is
//!   explicitly marked `index_begin`; continuation control members are marked
//!   `index_fragment`. Ordinary gzip readers output zero bytes for those
//!   control members, then continue into the FASTQ data members, so downstream
//!   tools see clean sequence data. Embedded offsets are stored relative to the
//!   start of the `index_begin` member, which means `cat a.fq.gz b.fq.gz >
//!   cohort.fq.gz` preserves each stream-local embedded index.
//!
//! The initial implementation intentionally supports the conservative
//! `gzip_members` chunking strategy first. Future strategies such as BGZF or
//! zran-style checkpoints are modeled by `ChunkingMode` but are not emitted yet.

const std = @import("std");
const c = @import("c.zig");
const zgz = @import("zgz.zig");

/// Magic bytes at the beginning of every binary `.igz` index.
pub const igz_magic = [_]u8{ 'I', 'G', 'Z', 0x1a, '\n', 0, 0, 1 };

/// Binary `.igz` index format version.
pub const igz_version: u16 = 1;

/// Default input buffer used by shard/repack/index/cat tools.
pub const default_io_buffer_size: usize = 1024 * 1024;

/// Default uncompressed chunk size for long-read data.
pub const default_long_read_chunk_bytes: u64 = 1024 * 1024 * 1024;

/// Default record count per chunk for paired-end short-read data.
pub const default_short_read_records_per_chunk: u64 = 5_000_000;

/// FASTx input mode.
pub const ReadMode = enum(u8) {
    /// One FASTQ/FASTA file. This is the common mode for long reads.
    single_end = 0,

    /// R1/R2 files are consumed in lockstep and chunk boundaries are shared.
    paired_end = 1,
};

/// Biological read length / balancing mode.
pub const ReadLengthMode = enum(u8) {
    /// Prefer record-count chunking. This keeps paired-end Illumina shards
    /// balanced by pair count.
    short_reads = 0,

    /// Prefer uncompressed-byte chunking. This balances highly variable ONT or
    /// PacBio records better than record counts.
    long_reads = 1,
};

/// Input record format.
pub const SequenceFormat = enum(u8) {
    /// Strict modern FASTQ: exactly four physical lines per record.
    fastq_strict_4line = 0,

    /// Reserved for future FASTA support. The executable rejects this until the
    /// parser is implemented.
    fasta = 1,
};

/// Chunking strategy used by a repacked data file.
pub const ChunkingMode = enum(u8) {
    /// Concatenated gzip members, one member per zgz chunk. This is the first
    /// implemented strategy because it is simple, robust, and gzip-compatible.
    gzip_members = 0,

    /// Reserved for BGZF-compatible blocked gzip output.
    bgzf = 1,

    /// Reserved for zran-style checkpoints over an existing gzip stream.
    zran_checkpoints = 2,
};


/// Where zgz should store index metadata for a repacked gzip-members file.
///
/// `auto` is the recommended production default: after writing the data gzip
/// members, prepend one or more gzip-compatible zero-length IGZ control members
/// carrying a complete compact index. Ordinary gzip readers still see only
/// FASTQ bytes because every control member decompresses to zero bytes.
pub const IndexStorageMode = enum(u8) {
    /// Let zgz choose the safest complete representation. Current behavior:
    /// prepend a complete fragmented embedded index.
    auto = 0,

    /// Do not write any embedded descriptor. Persist only a sidecar `.igz`.
    sidecar = 1,

    /// Require the complete chunk table to be embedded in the gzip prelude.
    /// Large indexes are split across multiple prepended zero-length gzip
    /// control members.
    embedded = 2,

    /// Write no index metadata. This is useful only for compatibility tests or
    /// plain repacking; `zgz-cat` will use sequential fallback.
    none = 3,
};

/// Strategy advertised by an embedded IGZ prelude.
pub const PreludeIndexLocation = enum(u8) {
    none = 0,
    sidecar = 1,

    /// A complete compact index is stored in a single zero-length gzip
    /// control member. Kept for compatibility with early self-indexed files.
    embedded_compact = 2,

    /// A complete compact index is split over multiple zero-length gzip
    /// control members. This removes the practical 64 KiB FEXTRA limit while
    /// preserving ordinary gzip compatibility: every control member
    /// decompresses to zero bytes before the data members begin.
    embedded_fragments = 3,

    footer_member = 4,
};

/// Role of this zero-length IGZ control member within an embedded index group.
///
/// A concatenated gzip file may contain several independent self-indexed zgz
/// streams. `index_begin` marks the start of one such stream. `index_fragment`
/// members continue the compact index for the same stream. All roles are stored
/// in FEXTRA, so legacy gzip readers simply skip the metadata and emit zero
/// bytes for the control members.
pub const PreludeRole = enum(u8) {
    /// No stream-boundary semantics. Kept for older descriptor-only preludes.
    descriptor = 0,

    /// First zero member of a self-indexed logical stream. This is the anchor
    /// for `igz_stream_relative` compressed offsets.
    index_begin = 1,

    /// Continuation zero member carrying another fragment of the same embedded
    /// index.
    index_fragment = 2,
};

/// Basis used by compressed offsets in an embedded or sidecar index.
///
/// Embedded indexes should use `igz_stream_relative`: offset zero is the first
/// byte of the `index_begin` gzip member, not the physical start of the
/// containing file. That makes plain gzip concatenation safe because each
/// logical stream can be relocated without rewriting its index.
pub const OffsetBasis = enum(u8) {
    /// Offsets are absolute from the beginning of the physical file. This is
    /// appropriate for standalone sidecar `.igz` indexes.
    file_absolute = 0,

    /// Offsets are relative to the start of the IGZ `index_begin` member for
    /// this logical stream. This is the production embedded-index basis.
    igz_stream_relative = 1,

    /// Reserved for future layouts whose chunk table starts at the first data
    /// member instead of at the control-member group.
    first_data_member_relative = 2,
};

/// Parsed descriptor from the IGZ gzip prelude member.
pub const PreludeDescriptor = struct {
    version: u16 = igz_version,
    chunking_mode: ChunkingMode = .gzip_members,
    sequence_format: SequenceFormat = .fastq_strict_4line,
    read_mode: ReadMode = .single_end,
    read_length_mode: ReadLengthMode = .long_reads,
    index_location: PreludeIndexLocation = .sidecar,

    /// Role of the current zero member. The first member of a self-indexed
    /// embedded stream is always `index_begin`; following index fragments use
    /// `index_fragment`.
    role: PreludeRole = .descriptor,

    /// Offset basis used by compressed offsets in the embedded compact index.
    /// Production embedded indexes use `igz_stream_relative` so concatenation
    /// can relocate complete streams without rewriting metadata.
    offset_basis: OffsetBasis = .file_absolute,

    /// Stable per-stream identifier copied into every index fragment. This is
    /// not a cryptographic identity; it is a cheap guard against accidentally
    /// combining fragments from different concatenated streams.
    stream_id_hi: u64 = 0,
    stream_id_lo: u64 = 0,

    first_data_member_offset: u64 = 0,
    chunk_count_hint: u64 = 0,
    total_records_hint: u64 = 0,
    flags: u64 = 0,
};

/// Result of probing the first gzip member for an embedded IGZ descriptor.
pub const PreludeProbe = union(enum) {
    absent,
    present: PreludeDescriptor,
};

/// Policy used to decide when a chunk should be closed.
pub const ChunkTarget = union(enum) {
    /// Close a chunk after at least this many complete records.
    records: u64,

    /// Close a chunk after at least this many uncompressed bytes, but only at a
    /// complete record boundary.
    uncompressed_bytes: u64,

    pub fn shouldClose(self: ChunkTarget, records: u64, bytes: u64) bool {
        return switch (self) {
            .records => |n| records >= n,
            .uncompressed_bytes => |n| bytes >= n,
        };
    }
};

/// One independently decompressible member/chunk described by `.igz`.
pub const ChunkRecord = struct {
    /// Zero-based chunk/member ordinal.
    member_id: u64,

    /// Byte offset of the gzip member in the repacked `.gz` data file.
    compressed_offset: u64,

    /// Byte length of the gzip member in the repacked `.gz` data file.
    compressed_size: u64,

    /// Logical uncompressed byte offset of this chunk in the full decompressed
    /// FASTQ stream.
    uncompressed_offset: u64,

    /// Number of uncompressed bytes represented by this chunk.
    uncompressed_size: u64,

    /// Zero-based first read record in this chunk. For paired-end data this is
    /// the pair ordinal.
    record_start: u64,

    /// Number of FASTQ records in this chunk. For paired-end mode this is the
    /// number of read pairs.
    record_count: u64,
};

/// Header stored in a binary `.igz` index.
pub const IndexHeader = struct {
    version: u16 = igz_version,
    chunking_mode: ChunkingMode = .gzip_members,
    sequence_format: SequenceFormat = .fastq_strict_4line,
    read_mode: ReadMode = .single_end,
    read_length_mode: ReadLengthMode = .long_reads,
    chunk_count: u64 = 0,
    total_records: u64 = 0,
    total_uncompressed_bytes: u64 = 0,
    total_compressed_bytes: u64 = 0,
};

/// In-memory representation of a `.igz` index.
pub const Index = struct {
    header: IndexHeader,
    chunks: []ChunkRecord,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.chunks);
        self.* = undefined;
    }
};

pub const IgzError = error{
    InvalidIndexMagic,
    UnsupportedIndexVersion,
    UnsupportedChunkingMode,
    UnsupportedSequenceFormat,
    UnsupportedReadMode,
    InvalidFastqRecord,
    MismatchedPairedEndRecords,
    EmptyChunkTarget,
    SliceTooLarge,
    CompressionFailed,
    InvalidArguments,
    EmbeddedIndexTooLarge,
    InvalidPrelude,
    MismatchedPreludeFragments,
    MissingSidecarPath,
};

/// Write an unsigned integer in little-endian form.
fn writeInt(comptime T: type, writer: *std.Io.Writer, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try writer.writeAll(&buf);
}

/// Read an unsigned integer in little-endian form.
fn readInt(comptime T: type, reader: *std.Io.Reader) !T {
    var buf: [@sizeOf(T)]u8 = undefined;
    try reader.readSliceAll(&buf);
    return std.mem.readInt(T, &buf, .little);
}

/// Serialize an `.igz` index.
///
/// The format is deliberately boring:
///
/// ```text
/// magic[8]
/// u16 version
/// u8  chunking_mode
/// u8  sequence_format
/// u8  read_mode
/// u8  read_length_mode
/// u32 reserved
/// u64 chunk_count
/// u64 total_records
/// u64 total_uncompressed_bytes
/// u64 total_compressed_bytes
/// repeated chunk_count times:
///   u64 member_id
///   u64 compressed_offset
///   u64 compressed_size
///   u64 uncompressed_offset
///   u64 uncompressed_size
///   u64 record_start
///   u64 record_count
/// ```
pub fn writeIndex(writer: *std.Io.Writer, index: Index) !void {
    try writer.writeAll(&igz_magic);
    try writeInt(u16, writer, index.header.version);
    try writer.writeByte(@intFromEnum(index.header.chunking_mode));
    try writer.writeByte(@intFromEnum(index.header.sequence_format));
    try writer.writeByte(@intFromEnum(index.header.read_mode));
    try writer.writeByte(@intFromEnum(index.header.read_length_mode));
    try writeInt(u32, writer, 0);
    try writeInt(u64, writer, index.header.chunk_count);
    try writeInt(u64, writer, index.header.total_records);
    try writeInt(u64, writer, index.header.total_uncompressed_bytes);
    try writeInt(u64, writer, index.header.total_compressed_bytes);

    for (index.chunks) |chunk| {
        try writeInt(u64, writer, chunk.member_id);
        try writeInt(u64, writer, chunk.compressed_offset);
        try writeInt(u64, writer, chunk.compressed_size);
        try writeInt(u64, writer, chunk.uncompressed_offset);
        try writeInt(u64, writer, chunk.uncompressed_size);
        try writeInt(u64, writer, chunk.record_start);
        try writeInt(u64, writer, chunk.record_count);
    }
}

/// Deserialize a binary `.igz` index.
pub fn readIndexAlloc(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Index {
    var magic: [igz_magic.len]u8 = undefined;
    try reader.readSliceAll(&magic);
    if (!std.mem.eql(u8, &magic, &igz_magic)) return error.InvalidIndexMagic;

    const version = try readInt(u16, reader);
    if (version != igz_version) return error.UnsupportedIndexVersion;

    const chunking_raw = try reader.takeByte();
    const format_raw = try reader.takeByte();
    const read_mode_raw = try reader.takeByte();
    const read_length_raw = try reader.takeByte();
    _ = try readInt(u32, reader);

    const chunking_mode: ChunkingMode = @enumFromInt(chunking_raw);
    const sequence_format: SequenceFormat = @enumFromInt(format_raw);
    const read_mode: ReadMode = @enumFromInt(read_mode_raw);
    const read_length_mode: ReadLengthMode = @enumFromInt(read_length_raw);

    const chunk_count = try readInt(u64, reader);
    const chunks_len: usize = std.math.cast(usize, chunk_count) orelse return error.SliceTooLarge;

    const chunks = try allocator.alloc(ChunkRecord, chunks_len);
    errdefer allocator.free(chunks);

    const header: IndexHeader = .{
        .version = version,
        .chunking_mode = chunking_mode,
        .sequence_format = sequence_format,
        .read_mode = read_mode,
        .read_length_mode = read_length_mode,
        .chunk_count = chunk_count,
        .total_records = try readInt(u64, reader),
        .total_uncompressed_bytes = try readInt(u64, reader),
        .total_compressed_bytes = try readInt(u64, reader),
    };

    for (chunks) |*chunk| {
        chunk.* = .{
            .member_id = try readInt(u64, reader),
            .compressed_offset = try readInt(u64, reader),
            .compressed_size = try readInt(u64, reader),
            .uncompressed_offset = try readInt(u64, reader),
            .uncompressed_size = try readInt(u64, reader),
            .record_start = try readInt(u64, reader),
            .record_count = try readInt(u64, reader),
        };
    }

    return .{ .header = header, .chunks = chunks };
}

/// Append-only chunk accumulator used by shard and repack.
///
/// The accumulator is intentionally a plain byte buffer. It allows us to emit a
/// chunk as either a physical FASTQ shard or a gzip member without reparsing.
const ChunkBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    record_count: u64 = 0,
    uncompressed_size: u64 = 0,

    fn init(allocator: std.mem.Allocator) ChunkBuffer {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ChunkBuffer) void {
        self.bytes.deinit(self.allocator);
    }

    fn clearRetainingCapacity(self: *ChunkBuffer) void {
        self.bytes.clearRetainingCapacity();
        self.record_count = 0;
        self.uncompressed_size = 0;
    }

    fn appendByte(self: *ChunkBuffer, byte: u8) !void {
        try self.bytes.append(self.allocator, byte);
        self.uncompressed_size += 1;
    }
};

/// Streaming strict four-line FASTQ validator/chunker.
///
/// This parser does not allocate per record. It validates the structural pieces
/// that matter for safe sharding:
///
/// - line 0 starts with `@`;
/// - line 2 starts with `+`;
/// - sequence and quality lengths match;
/// - chunk boundaries occur only after complete records.
const FastqStrictChunker = struct {
    line_mod: u2 = 0,
    column: u64 = 0,
    seq_len: u64 = 0,
    qual_len: u64 = 0,
    total_records: u64 = 0,
    total_uncompressed_bytes: u64 = 0,

    fn feedByte(self: *FastqStrictChunker, chunk: *ChunkBuffer, byte: u8) !bool {
        if (self.column == 0) {
            if (self.line_mod == 0 and byte != '@') return error.InvalidFastqRecord;
            if (self.line_mod == 2 and byte != '+') return error.InvalidFastqRecord;
        }

        try chunk.appendByte(byte);
        self.total_uncompressed_bytes += 1;

        if (byte == '\n') {
            if (self.line_mod == 3) {
                if (self.seq_len != self.qual_len) return error.InvalidFastqRecord;
                self.total_records += 1;
                chunk.record_count += 1;
                self.line_mod = 0;
                self.column = 0;
                self.seq_len = 0;
                self.qual_len = 0;
                return true;
            }

            self.line_mod +%= 1;
            self.column = 0;
            return false;
        }

        if (self.line_mod == 1) self.seq_len += 1;
        if (self.line_mod == 3) self.qual_len += 1;
        self.column += 1;
        return false;
    }

    fn finish(self: *const FastqStrictChunker) !void {
        if (self.line_mod != 0 or self.column != 0 or self.seq_len != 0 or self.qual_len != 0) {
            return error.InvalidFastqRecord;
        }
    }
};

/// Options for `zgz repack`.
pub const RepackOptions = struct {
    sequence_format: SequenceFormat = .fastq_strict_4line,
    read_mode: ReadMode = .single_end,
    read_length_mode: ReadLengthMode = .long_reads,
    chunking_mode: ChunkingMode = .gzip_members,
    target: ChunkTarget = .{ .uncompressed_bytes = default_long_read_chunk_bytes },
    compression_level: i32 = 6,
    input_buffer_size: usize = default_io_buffer_size,
    inflate_buffer_size: usize = default_io_buffer_size,
    index_storage: IndexStorageMode = .auto,
};

/// Options for `zgz shard`.
pub const ShardOptions = struct {
    sequence_format: SequenceFormat = .fastq_strict_4line,
    read_mode: ReadMode = .single_end,
    read_length_mode: ReadLengthMode = .short_reads,
    target: ChunkTarget = .{ .records = default_short_read_records_per_chunk },
    gzip_output: bool = true,
    compression_level: i32 = 6,
    input_buffer_size: usize = default_io_buffer_size,
    inflate_buffer_size: usize = default_io_buffer_size,
};


// -----------------------------------------------------------------------------
// Embedded IGZ prelude support
// -----------------------------------------------------------------------------

/// Gzip magic bytes. A gzip-compatible file must begin with these bytes; this is
/// why raw `.igz` bytes cannot be prepended to a `.gz` file.
pub const gzip_magic = [_]u8{ 0x1f, 0x8b };

/// FEXTRA subfield identifier used by zgz. RFC 1952 reserves two bytes for
/// application-specific subfield IDs; ordinary gzip readers skip unknown fields.
pub const igz_extra_id = [_]u8{ 'I', 'G' };

/// Magic used inside the IGZ prelude payload.
pub const igz_prelude_magic = [_]u8{ 'I', 'G', 'Z', 'P' };

/// Marker introducing a complete binary chunk table inside an IGZ prelude
/// payload. It follows the fixed descriptor, allowing older readers to parse
/// the descriptor and ignore the embedded table.
pub const igz_embedded_index_magic = [_]u8{ 'I', 'G', 'Z', 'I' };

/// Marker introducing one fragment of a complete compact index in an IGZ
/// zero-length control member. The full index is reconstructed by concatenating
/// fragment payloads ordered by `fragment_id`.
pub const igz_embedded_fragment_magic = [_]u8{ 'I', 'G', 'Z', 'F' };

/// Maximum payload length for a single gzip FEXTRA subfield. XLEN is 16-bit and
/// includes the four bytes of subfield ID + subfield length, so the application
/// payload can be at most 65531 bytes.
pub const max_igz_extra_payload_len: usize = std.math.maxInt(u16) - 4;

const embedded_fragment_version: u32 = 1;
const embedded_fragment_fixed_len: usize = igz_embedded_fragment_magic.len + @sizeOf(u32) * 3 + @sizeOf(u64) + @sizeOf(u32);


const gzip_cm_deflate: u8 = 8;
const gzip_fextra: u8 = 0x04;
const gzip_os_unknown: u8 = 255;

/// Number of bytes in a gzip member whose DEFLATE payload is the canonical empty
/// final stored block. This excludes the FEXTRA payload itself.
fn preludeOverhead(extra_payload_len: usize) u64 {
    // gzip fixed header: 10 bytes
    // XLEN: 2 bytes
    // subfield id + subfield len: 4 bytes
    // empty final stored DEFLATE block: 5 bytes
    // gzip trailer: 8 bytes
    return 10 + 2 + 4 + @as(u64, @intCast(extra_payload_len)) + 5 + 8;
}

fn appendInt(comptime T: type, allocator: std.mem.Allocator, list: *std.ArrayList(u8), value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try list.appendSlice(allocator, &buf);
}

fn readIntFromSlice(comptime T: type, bytes: []const u8, cursor: *usize) !T {
    if (bytes.len - cursor.* < @sizeOf(T)) return error.InvalidPrelude;
    var buf: [@sizeOf(T)]u8 = undefined;
    @memcpy(&buf, bytes[cursor.* .. cursor.* + @sizeOf(T)]);
    cursor.* += @sizeOf(T);
    return std.mem.readInt(T, &buf, .little);
}

/// Serialize only the compact embedded prelude payload, not the surrounding gzip
/// header. The payload intentionally carries stable high-level metadata and
/// hints, while the full `.igz` sidecar carries the complete chunk table.
pub fn buildPreludePayloadAlloc(
    allocator: std.mem.Allocator,
    descriptor: PreludeDescriptor,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, &igz_prelude_magic);
    try appendInt(u16, allocator, &list, descriptor.version);
    try list.append(allocator, @intFromEnum(descriptor.chunking_mode));
    try list.append(allocator, @intFromEnum(descriptor.sequence_format));
    try list.append(allocator, @intFromEnum(descriptor.read_mode));
    try list.append(allocator, @intFromEnum(descriptor.read_length_mode));
    try list.append(allocator, @intFromEnum(descriptor.index_location));
    try list.append(allocator, 0); // reserved for alignment / future minor flags
    try appendInt(u64, allocator, &list, descriptor.first_data_member_offset);
    try appendInt(u64, allocator, &list, descriptor.chunk_count_hint);
    try appendInt(u64, allocator, &list, descriptor.total_records_hint);
    try appendInt(u64, allocator, &list, descriptor.flags);

    // Extended descriptor tail. `parsePreludePayload` treats this tail as
    // optional so older prelude descriptors remain readable. New writers always
    // populate it to make self-indexed gzip concatenation unambiguous.
    try list.append(allocator, @intFromEnum(descriptor.role));
    try list.append(allocator, @intFromEnum(descriptor.offset_basis));
    try appendInt(u16, allocator, &list, 0); // reserved for future descriptor-tail flags
    try appendInt(u64, allocator, &list, descriptor.stream_id_hi);
    try appendInt(u64, allocator, &list, descriptor.stream_id_lo);

    return list.toOwnedSlice(allocator);
}

fn appendIndexBytes(allocator: std.mem.Allocator, list: *std.ArrayList(u8), index: Index) !void {
    try list.appendSlice(allocator, &igz_magic);
    try appendInt(u16, allocator, list, index.header.version);
    try list.append(allocator, @intFromEnum(index.header.chunking_mode));
    try list.append(allocator, @intFromEnum(index.header.sequence_format));
    try list.append(allocator, @intFromEnum(index.header.read_mode));
    try list.append(allocator, @intFromEnum(index.header.read_length_mode));
    try appendInt(u32, allocator, list, 0);
    try appendInt(u64, allocator, list, index.header.chunk_count);
    try appendInt(u64, allocator, list, index.header.total_records);
    try appendInt(u64, allocator, list, index.header.total_uncompressed_bytes);
    try appendInt(u64, allocator, list, index.header.total_compressed_bytes);

    for (index.chunks) |chunk| {
        try appendInt(u64, allocator, list, chunk.member_id);
        try appendInt(u64, allocator, list, chunk.compressed_offset);
        try appendInt(u64, allocator, list, chunk.compressed_size);
        try appendInt(u64, allocator, list, chunk.uncompressed_offset);
        try appendInt(u64, allocator, list, chunk.uncompressed_size);
        try appendInt(u64, allocator, list, chunk.record_start);
        try appendInt(u64, allocator, list, chunk.record_count);
    }
}

/// Serialize a prelude descriptor followed by a complete compact `.igz` index.
///
/// This is used by the post-processing prepend path: first build the repacked
/// gzip data and collect exact member offsets, then prepend one zero-length gzip
/// control member whose FEXTRA payload contains the final adjusted index. The
/// payload is still bounded by gzip's 16-bit FEXTRA length, so large files may
/// need the sidecar fallback.
pub fn buildPreludePayloadWithIndexAlloc(
    allocator: std.mem.Allocator,
    descriptor: PreludeDescriptor,
    index: Index,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const descriptor_payload = try buildPreludePayloadAlloc(allocator, descriptor);
    defer allocator.free(descriptor_payload);
    try list.appendSlice(allocator, descriptor_payload);
    try list.appendSlice(allocator, &igz_embedded_index_magic);
    try appendIndexBytes(allocator, &list, index);

    if (list.items.len > max_igz_extra_payload_len) return error.EmbeddedIndexTooLarge;
    return list.toOwnedSlice(allocator);
}

/// Return the number of bytes required by a prelude member carrying the full
/// compact index, or `EmbeddedIndexTooLarge` when gzip FEXTRA cannot hold it.
pub fn preludeMemberSizeForEmbeddedIndex(
    allocator: std.mem.Allocator,
    descriptor: PreludeDescriptor,
    index: Index,
) !u64 {
    const payload = try buildPreludePayloadWithIndexAlloc(allocator, descriptor, index);
    defer allocator.free(payload);
    return preludeOverhead(payload.len);
}


/// Serialize the compact index bytes used by both `.igz` sidecars and embedded
/// prelude fragments. The encoding is deliberately fixed-width so that changing
/// compressed offsets after a prepended prelude does not change the encoded
/// length. This property keeps post-processing deterministic.
pub fn buildCompactIndexBytesAlloc(allocator: std.mem.Allocator, index: Index) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try appendIndexBytes(allocator, &list, index);
    return list.toOwnedSlice(allocator);
}

fn embeddedFragmentPayloadCapacity(descriptor_payload_len: usize) !usize {
    if (descriptor_payload_len + embedded_fragment_fixed_len >= max_igz_extra_payload_len) return error.EmbeddedIndexTooLarge;
    return max_igz_extra_payload_len - descriptor_payload_len - embedded_fragment_fixed_len;
}

fn embeddedFragmentCount(index_bytes_len: usize, per_fragment_capacity: usize) !u32 {
    if (per_fragment_capacity == 0) return error.EmbeddedIndexTooLarge;
    const count = (index_bytes_len + per_fragment_capacity - 1) / per_fragment_capacity;
    if (count == 0) return 1;
    return std.math.cast(u32, count) orelse return error.SliceTooLarge;
}

fn checksumEmbeddedIndex(index_bytes: []const u8) u32 {
    return std.hash.Crc32.hash(index_bytes);
}

const StreamId = struct { hi: u64, lo: u64 };

/// Derive a stable, non-secret stream identifier from compact index bytes.
///
/// This guards against accidentally joining fragments from different embedded
/// streams after plain gzip concatenation. The fragment CRC still validates the
/// reconstructed compact index itself.
fn deriveStreamId(index_bytes: []const u8) StreamId {
    var h1 = std.hash.Wyhash.init(0x49475a5f5354524d); // "IGZ_STRM"
    h1.update(index_bytes);
    var h2 = std.hash.Wyhash.init(0x49475a5f49445821); // "IGZ_IDX!"
    h2.update(index_bytes);
    return .{ .hi = h1.final(), .lo = h2.final() };
}

/// Build the payload for one member of a fragmented embedded IGZ index.
///
/// Every fragment repeats the descriptor, followed by an `IGZF` fragment header
/// and a byte slice of the compact index. Repeating the descriptor is a small
/// overhead that makes the layout robust against partial inspection and keeps
/// each zero member self-describing.
pub fn buildPreludeFragmentPayloadAlloc(
    allocator: std.mem.Allocator,
    descriptor: PreludeDescriptor,
    fragment_id: u32,
    fragment_count: u32,
    full_index_size: u64,
    full_index_crc32: u32,
    fragment_bytes: []const u8,
) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const descriptor_payload = try buildPreludePayloadAlloc(allocator, descriptor);
    defer allocator.free(descriptor_payload);
    try list.appendSlice(allocator, descriptor_payload);
    try list.appendSlice(allocator, &igz_embedded_fragment_magic);
    try appendInt(u32, allocator, &list, embedded_fragment_version);
    try appendInt(u32, allocator, &list, fragment_id);
    try appendInt(u32, allocator, &list, fragment_count);
    try appendInt(u64, allocator, &list, full_index_size);
    try appendInt(u32, allocator, &list, full_index_crc32);
    try list.appendSlice(allocator, fragment_bytes);

    if (list.items.len > max_igz_extra_payload_len) return error.EmbeddedIndexTooLarge;
    return list.toOwnedSlice(allocator);
}

/// Compute the total byte length of all prepended zero-length gzip control
/// members needed to store `index_bytes` as fragments.
pub fn fragmentedPreludeTotalSizeAlloc(
    allocator: std.mem.Allocator,
    descriptor: PreludeDescriptor,
    index_bytes_len: usize,
) !u64 {
    const descriptor_payload = try buildPreludePayloadAlloc(allocator, descriptor);
    defer allocator.free(descriptor_payload);
    const capacity = try embeddedFragmentPayloadCapacity(descriptor_payload.len);
    const count = try embeddedFragmentCount(index_bytes_len, capacity);

    var remaining = index_bytes_len;
    var total: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const take = @min(remaining, capacity);
        remaining -= take;
        total += preludeOverhead(descriptor_payload.len + embedded_fragment_fixed_len + take);
    }
    return total;
}

/// Parse a payload previously produced by `buildPreludePayloadAlloc`.
pub fn parsePreludePayload(bytes: []const u8) !PreludeDescriptor {
    var cursor: usize = 0;
    if (bytes.len < igz_prelude_magic.len) return error.InvalidPrelude;
    if (!std.mem.eql(u8, bytes[0..igz_prelude_magic.len], &igz_prelude_magic)) return error.InvalidPrelude;
    cursor += igz_prelude_magic.len;

    const version = try readIntFromSlice(u16, bytes, &cursor);
    if (version != igz_version) return error.UnsupportedIndexVersion;

    if (bytes.len - cursor < 6) return error.InvalidPrelude;
    const chunking_mode: ChunkingMode = @enumFromInt(bytes[cursor]); cursor += 1;
    const sequence_format: SequenceFormat = @enumFromInt(bytes[cursor]); cursor += 1;
    const read_mode: ReadMode = @enumFromInt(bytes[cursor]); cursor += 1;
    const read_length_mode: ReadLengthMode = @enumFromInt(bytes[cursor]); cursor += 1;
    const index_location: PreludeIndexLocation = @enumFromInt(bytes[cursor]); cursor += 1;
    cursor += 1; // reserved

    var descriptor: PreludeDescriptor = .{
        .version = version,
        .chunking_mode = chunking_mode,
        .sequence_format = sequence_format,
        .read_mode = read_mode,
        .read_length_mode = read_length_mode,
        .index_location = index_location,
        .first_data_member_offset = try readIntFromSlice(u64, bytes, &cursor),
        .chunk_count_hint = try readIntFromSlice(u64, bytes, &cursor),
        .total_records_hint = try readIntFromSlice(u64, bytes, &cursor),
        .flags = try readIntFromSlice(u64, bytes, &cursor),
    };

    if (bytes.len >= cursor + 2 + @sizeOf(u16) + @sizeOf(u64) * 2) {
        descriptor.role = @enumFromInt(bytes[cursor]); cursor += 1;
        descriptor.offset_basis = @enumFromInt(bytes[cursor]); cursor += 1;
        _ = try readIntFromSlice(u16, bytes, &cursor);
        descriptor.stream_id_hi = try readIntFromSlice(u64, bytes, &cursor);
        descriptor.stream_id_lo = try readIntFromSlice(u64, bytes, &cursor);
    }

    return descriptor;
}

/// Parse an embedded compact index from an IGZ prelude payload.
///
/// The descriptor is intentionally first in the payload. A reader that only
/// needs routing information can call `parsePreludePayload`; a reader that wants
/// the full table calls this function and receives an allocated `Index`.
pub fn parseEmbeddedIndexPayloadAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !Index {
    _ = try parsePreludePayload(bytes);

    const marker_at = std.mem.indexOf(u8, bytes, &igz_embedded_index_magic) orelse return error.InvalidPrelude;
    var cursor: usize = marker_at + igz_embedded_index_magic.len;

    if (bytes.len - cursor < igz_magic.len) return error.InvalidIndexMagic;
    if (!std.mem.eql(u8, bytes[cursor .. cursor + igz_magic.len], &igz_magic)) return error.InvalidIndexMagic;
    cursor += igz_magic.len;

    const version = try readIntFromSlice(u16, bytes, &cursor);
    if (version != igz_version) return error.UnsupportedIndexVersion;

    if (bytes.len - cursor < 4) return error.InvalidPrelude;
    const chunking_mode: ChunkingMode = @enumFromInt(bytes[cursor]); cursor += 1;
    const sequence_format: SequenceFormat = @enumFromInt(bytes[cursor]); cursor += 1;
    const read_mode: ReadMode = @enumFromInt(bytes[cursor]); cursor += 1;
    const read_length_mode: ReadLengthMode = @enumFromInt(bytes[cursor]); cursor += 1;
    _ = try readIntFromSlice(u32, bytes, &cursor);

    const chunk_count = try readIntFromSlice(u64, bytes, &cursor);
    const total_records = try readIntFromSlice(u64, bytes, &cursor);
    const total_uncompressed_bytes = try readIntFromSlice(u64, bytes, &cursor);
    const total_compressed_bytes = try readIntFromSlice(u64, bytes, &cursor);

    const chunks_len: usize = std.math.cast(usize, chunk_count) orelse return error.SliceTooLarge;
    const chunks = try allocator.alloc(ChunkRecord, chunks_len);
    errdefer allocator.free(chunks);

    for (chunks) |*chunk| {
        chunk.* = .{
            .member_id = try readIntFromSlice(u64, bytes, &cursor),
            .compressed_offset = try readIntFromSlice(u64, bytes, &cursor),
            .compressed_size = try readIntFromSlice(u64, bytes, &cursor),
            .uncompressed_offset = try readIntFromSlice(u64, bytes, &cursor),
            .uncompressed_size = try readIntFromSlice(u64, bytes, &cursor),
            .record_start = try readIntFromSlice(u64, bytes, &cursor),
            .record_count = try readIntFromSlice(u64, bytes, &cursor),
        };
    }


    return .{
        .header = .{
            .version = version,
            .chunking_mode = chunking_mode,
            .sequence_format = sequence_format,
            .read_mode = read_mode,
            .read_length_mode = read_length_mode,
            .chunk_count = chunk_count,
            .total_records = total_records,
            .total_uncompressed_bytes = total_uncompressed_bytes,
            .total_compressed_bytes = total_compressed_bytes,
        },
        .chunks = chunks,
    };
}

const FragmentMeta = struct {
    id: u32,
    count: u32,
    full_size: u64,
    crc32: u32,
    data: []const u8,
};

fn parseFragmentPayload(bytes: []const u8) !FragmentMeta {
    _ = try parsePreludePayload(bytes);
    const marker_at = std.mem.indexOf(u8, bytes, &igz_embedded_fragment_magic) orelse return error.InvalidPrelude;
    var cursor: usize = marker_at + igz_embedded_fragment_magic.len;
    const version = try readIntFromSlice(u32, bytes, &cursor);
    if (version != embedded_fragment_version) return error.UnsupportedIndexVersion;
    const id = try readIntFromSlice(u32, bytes, &cursor);
    const count = try readIntFromSlice(u32, bytes, &cursor);
    const full_size = try readIntFromSlice(u64, bytes, &cursor);
    const crc32 = try readIntFromSlice(u32, bytes, &cursor);
    if (count == 0 or id >= count) return error.InvalidPrelude;
    return .{ .id = id, .count = count, .full_size = full_size, .crc32 = crc32, .data = bytes[cursor..] };
}

fn parseIndexFromCompactBytesAlloc(allocator: std.mem.Allocator, bytes: []const u8) !Index {
    var stream = std.Io.Reader.fixed(bytes);
    return readIndexAlloc(allocator, &stream);
}

/// Reconstruct a complete embedded compact index from one or more IGZ prelude
/// payloads. The function accepts both the historical single-member `IGZI`
/// payload and the production `IGZF` fragmented layout.
pub fn parseEmbeddedIndexPayloadsAlloc(
    allocator: std.mem.Allocator,
    payloads: []const []const u8,
) !Index {
    if (payloads.len == 0) return error.InvalidPrelude;
    const first_descriptor = try parsePreludePayload(payloads[0]);
    if (first_descriptor.index_location == .embedded_compact) {
        if (first_descriptor.role != .descriptor and first_descriptor.role != .index_begin) return error.InvalidPrelude;
        return parseEmbeddedIndexPayloadAlloc(allocator, payloads[0]);
    }
    if (first_descriptor.index_location != .embedded_fragments) return error.InvalidPrelude;
    if (first_descriptor.role != .descriptor and first_descriptor.role != .index_begin) return error.InvalidPrelude;
    if (first_descriptor.role == .index_begin and first_descriptor.offset_basis != .igz_stream_relative) return error.InvalidPrelude;

    const first_meta = try parseFragmentPayload(payloads[0]);
    const count_usize: usize = std.math.cast(usize, first_meta.count) orelse return error.SliceTooLarge;
    if (payloads.len < count_usize) return error.InvalidPrelude;

    const full_size_usize: usize = std.math.cast(usize, first_meta.full_size) orelse return error.SliceTooLarge;
    var full = try allocator.alloc(u8, full_size_usize);
    defer allocator.free(full);
    var filled = try allocator.alloc(bool, count_usize);
    defer allocator.free(filled);
    @memset(filled, false);

    var offset: usize = 0;
    var n: usize = 0;
    while (n < count_usize) : (n += 1) {
        const descriptor = try parsePreludePayload(payloads[n]);
        if (first_descriptor.role == .index_begin) {
            if (descriptor.stream_id_hi != first_descriptor.stream_id_hi or descriptor.stream_id_lo != first_descriptor.stream_id_lo) return error.MismatchedPreludeFragments;
            if (descriptor.offset_basis != .igz_stream_relative) return error.InvalidPrelude;
            if (n == 0) {
                if (descriptor.role != .index_begin) return error.InvalidPrelude;
            } else {
                if (descriptor.role != .index_fragment) return error.InvalidPrelude;
            }
        }
        const meta = try parseFragmentPayload(payloads[n]);
        if (meta.count != first_meta.count or meta.full_size != first_meta.full_size or meta.crc32 != first_meta.crc32) return error.InvalidPrelude;
        if (meta.id != n) return error.InvalidPrelude;
        const id_usize: usize = @intCast(meta.id);
        if (filled[id_usize]) return error.InvalidPrelude;
        if (offset + meta.data.len > full.len) return error.InvalidPrelude;
        @memcpy(full[offset .. offset + meta.data.len], meta.data);
        filled[id_usize] = true;
        offset += meta.data.len;
    }
    if (offset != full.len) return error.InvalidPrelude;
    for (filled) |ok| if (!ok) return error.InvalidPrelude;
    if (checksumEmbeddedIndex(full) != first_meta.crc32) return error.InvalidPrelude;
    return parseIndexFromCompactBytesAlloc(allocator, full);
}

/// Return the exact number of bytes `writePreludeMember` will emit for the given
/// descriptor. This lets `zgz-repack` record absolute compressed offsets for all
/// following data members before it writes the first data member.
pub fn preludeMemberSizeForDescriptor(
    allocator: std.mem.Allocator,
    descriptor: PreludeDescriptor,
) !u64 {
    const payload = try buildPreludePayloadAlloc(allocator, descriptor);
    defer allocator.free(payload);
    if (payload.len > max_igz_extra_payload_len) return error.EmbeddedIndexTooLarge;
    return preludeOverhead(payload.len);
}

fn writePreludePayloadMember(writer: *std.Io.Writer, payload: []const u8) !u64 {
    if (payload.len > max_igz_extra_payload_len) return error.EmbeddedIndexTooLarge;

    const xlen: u16 = @intCast(4 + payload.len);
    var header: [12]u8 = .{
        gzip_magic[0], gzip_magic[1], gzip_cm_deflate, gzip_fextra,
        0, 0, 0, 0, // MTIME
        0, gzip_os_unknown,
        0, 0, // XLEN, patched below
    };
    std.mem.writeInt(u16, header[10..12], xlen, .little);
    try writer.writeAll(&header);

    try writer.writeAll(&igz_extra_id);
    var sub_len_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &sub_len_buf, @as(u16, @intCast(payload.len)), .little);
    try writer.writeAll(&sub_len_buf);
    try writer.writeAll(payload);

    // Empty final stored DEFLATE block: BFINAL=1, BTYPE=00, LEN=0, NLEN=0xffff.
    try writer.writeAll(&[_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff });
    // Gzip trailer for an empty uncompressed payload: CRC32=0, ISIZE=0.
    try writer.writeAll(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });

    return preludeOverhead(payload.len);
}

/// Write a zero-length gzip control member carrying an IGZ descriptor in FEXTRA.
///
/// The member decompresses to zero bytes, so ordinary `gzip -dc` and ordinary
/// bioinformatics tools see a clean FASTQ/FASTA stream from subsequent data
/// members. zgz-aware readers inspect the first member's FEXTRA field before
/// choosing indexed or sequential behavior.
pub fn writePreludeMember(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    descriptor: PreludeDescriptor,
) !u64 {
    const payload = try buildPreludePayloadAlloc(allocator, descriptor);
    defer allocator.free(payload);
    return writePreludePayloadMember(writer, payload);
}

/// Write a zero-length gzip control member carrying a complete compact index.
///
/// The supplied index must already contain final offsets, including this
/// prelude member's byte length. Callers normally compute this with
/// `adjustIndexForPrependedPreludeAlloc`, then pass the adjusted index here.
pub fn writePreludeMemberWithIndex(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    descriptor: PreludeDescriptor,
    index: Index,
) !u64 {
    const payload = try buildPreludePayloadWithIndexAlloc(allocator, descriptor, index);
    defer allocator.free(payload);
    return writePreludePayloadMember(writer, payload);
}

/// Write one or more zero-length gzip control members carrying a complete
/// compact IGZ index split across FEXTRA fragments.
///
/// This is the preferred self-contained layout for production repacks. It keeps
/// the output gzip-compatible, avoids sidecar loss, and avoids the single-member
/// 64 KiB FEXTRA ceiling. `descriptor.first_data_member_offset` must already be
/// the total byte length returned by `fragmentedPreludeTotalSizeAlloc` for the
/// adjusted index.
pub fn writePreludeMembersWithFragmentedIndex(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    descriptor: PreludeDescriptor,
    index: Index,
) !u64 {
    const index_bytes = try buildCompactIndexBytesAlloc(allocator, index);
    defer allocator.free(index_bytes);
    const crc = checksumEmbeddedIndex(index_bytes);

    const descriptor_payload = try buildPreludePayloadAlloc(allocator, descriptor);
    defer allocator.free(descriptor_payload);
    const capacity = try embeddedFragmentPayloadCapacity(descriptor_payload.len);
    const count = try embeddedFragmentCount(index_bytes.len, capacity);

    var written_total: u64 = 0;
    var cursor: usize = 0;
    var fragment_id: u32 = 0;
    while (fragment_id < count) : (fragment_id += 1) {
        const remaining = index_bytes[cursor..];
        const take = @min(remaining.len, capacity);
        var fragment_descriptor = descriptor;
        fragment_descriptor.role = if (fragment_id == 0) .index_begin else .index_fragment;
        fragment_descriptor.offset_basis = .igz_stream_relative;
        const payload = try buildPreludeFragmentPayloadAlloc(
            allocator,
            fragment_descriptor,
            fragment_id,
            count,
            index_bytes.len,
            crc,
            remaining[0..take],
        );
        defer allocator.free(payload);
        written_total += try writePreludePayloadMember(writer, payload);
        cursor += take;
    }
    return written_total;
}

/// Read and return the IGZ FEXTRA payload from the first gzip member.
///
/// The returned slice is owned by `allocator`. A null return means the first
/// member is gzip but does not contain an IGZ subfield. This is the shared
/// primitive used by `zgz-cat`, `zgz-inspect`, and future indexed readers.
pub fn readPreludePayloadAlloc(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) !?[]u8 {
    var fixed: [10]u8 = undefined;
    try reader.readSliceAll(&fixed);
    if (fixed[0] != gzip_magic[0] or fixed[1] != gzip_magic[1]) return error.InvalidPrelude;
    if (fixed[2] != gzip_cm_deflate) return error.InvalidPrelude;

    const flg = fixed[3];
    if ((flg & gzip_fextra) == 0) return null;

    const xlen = try readInt(u16, reader);
    const extra = try allocator.alloc(u8, xlen);
    defer allocator.free(extra);
    try reader.readSliceAll(extra);

    var cursor: usize = 0;
    while (cursor + 4 <= extra.len) {
        const si1 = extra[cursor];
        const si2 = extra[cursor + 1];
        var sub_len_buf: [2]u8 = undefined;
        @memcpy(&sub_len_buf, extra[cursor + 2 .. cursor + 4]);
        const sub_len = std.mem.readInt(u16, &sub_len_buf, .little);
        cursor += 4;
        if (extra.len - cursor < sub_len) return error.InvalidPrelude;
        const payload = extra[cursor .. cursor + sub_len];
        if (si1 == igz_extra_id[0] and si2 == igz_extra_id[1]) {
            return try allocator.dupe(u8, payload);
        }
        cursor += sub_len;
    }

    return null;
}

/// Owned collection of IGZ prelude payloads read from consecutive zero-length
/// gzip control members at the beginning of a file.
pub const PreludePayloads = struct {
    items: [][]u8,

    pub fn deinit(self: *PreludePayloads, allocator: std.mem.Allocator) void {
        for (self.items) |payload| allocator.free(payload);
        allocator.free(self.items);
        self.* = undefined;
    }
};

fn skipEmptyPreludeBody(reader: *std.Io.Reader) !void {
    var body: [13]u8 = undefined;
    try reader.readSliceAll(&body);
    const expected = [_]u8{ 0x01, 0x00, 0x00, 0xff, 0xff, 0, 0, 0, 0, 0, 0, 0, 0 };
    if (!std.mem.eql(u8, &body, &expected)) return error.InvalidPrelude;
}

/// Read IGZ payloads from the leading zero-length control members.
///
/// The scanner is intentionally conservative: it accepts only the exact empty
/// DEFLATE body written by `writePreludePayloadMember`. It stops when it reaches
/// the first non-IGZ gzip member, which is expected to be the first data member.
/// This function consumes from the reader and is intended for inspection or for
/// callers that can reopen the file before streaming data.
pub fn readPreludePayloadsAlloc(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    max_members: usize,
) !PreludePayloads {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |payload| allocator.free(payload);
        list.deinit(allocator);
    }

    while (list.items.len < max_members) {
        var fixed: [10]u8 = undefined;
        reader.readSliceAll(&fixed) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (fixed[0] != gzip_magic[0] or fixed[1] != gzip_magic[1]) break;
        if (fixed[2] != gzip_cm_deflate) return error.InvalidPrelude;
        const flg = fixed[3];
        if ((flg & gzip_fextra) == 0) break;

        const xlen = try readInt(u16, reader);
        const extra = try allocator.alloc(u8, xlen);
        defer allocator.free(extra);
        try reader.readSliceAll(extra);

        var found: ?[]u8 = null;
        var cursor: usize = 0;
        while (cursor + 4 <= extra.len) {
            const si1 = extra[cursor];
            const si2 = extra[cursor + 1];
            var sub_len_buf: [2]u8 = undefined;
            @memcpy(&sub_len_buf, extra[cursor + 2 .. cursor + 4]);
            const sub_len = std.mem.readInt(u16, &sub_len_buf, .little);
            cursor += 4;
            if (extra.len - cursor < sub_len) return error.InvalidPrelude;
            const payload = extra[cursor .. cursor + sub_len];
            if (si1 == igz_extra_id[0] and si2 == igz_extra_id[1]) {
                found = try allocator.dupe(u8, payload);
                break;
            }
            cursor += sub_len;
        }

        const payload = found orelse break;
        errdefer allocator.free(payload);
        try skipEmptyPreludeBody(reader);
        try list.append(allocator, payload);

        const descriptor = try parsePreludePayload(payload);
        if (descriptor.index_location == .embedded_compact or descriptor.index_location == .sidecar or descriptor.index_location == .none) break;
        if (descriptor.index_location == .embedded_fragments) {
            const meta = try parseFragmentPayload(payload);
            if (list.items.len >= meta.count) break;
        }
    }

    return .{ .items = try list.toOwnedSlice(allocator) };
}

/// Probe the first gzip member for an IGZ FEXTRA descriptor.
///
/// This function consumes bytes from `reader`. It is intended for inspectors and
/// callers that can reopen/seek the file before falling back to full ordinary
/// decompression. Do not call this on a streaming stdin and then expect to pass
/// the same reader to the sequential inflater from the beginning.
pub fn probePrelude(reader: *std.Io.Reader, allocator: std.mem.Allocator) !PreludeProbe {
    const payload = try readPreludePayloadAlloc(reader, allocator) orelse return .absent;
    defer allocator.free(payload);
    return .{ .present = try parsePreludePayload(payload) };
}

/// Low-level gzip-member compressor backed by zlib-ng deflate.
///
/// Each call to `compressGzipMember` writes a complete independent gzip member.
/// The returned byte count is the compressed member length written to `writer`.
pub fn compressGzipMember(
    writer: *std.Io.Writer,
    level: i32,
    input: []const u8,
) !u64 {
    if (input.len > std.math.maxInt(c.uInt)) return error.SliceTooLarge;

    var stream = zgz.zeroStream();
    const rc_init = c.zng_deflateInit2(
        &stream,
        level,
        c.Z_DEFLATED,
        15 + 16, // maximum window plus gzip wrapper
        8,
        c.Z_DEFAULT_STRATEGY,
    );
    if (rc_init != c.Z_OK) return error.CompressionFailed;
    defer _ = c.zng_deflateEnd(&stream);

    var out_buf: [256 * 1024]u8 = undefined;
    var written_total: u64 = 0;
    var input_pos: usize = 0;

    while (true) {
        const remaining = input[input_pos..];
        const take = @min(remaining.len, std.math.maxInt(c.uInt));
        stream.next_in = if (take == 0) null else remaining.ptr;
        stream.avail_in = @intCast(take);

        const flush: c.int32_t = if (input_pos + take == input.len) c.Z_FINISH else c.Z_NO_FLUSH;

        while (true) {
            stream.next_out = &out_buf;
            stream.avail_out = @intCast(out_buf.len);
            const before_out = stream.total_out;
            const rc = c.zng_deflate(&stream, flush);
            const produced = stream.total_out - before_out;
            if (produced != 0) {
                try writer.writeAll(out_buf[0..produced]);
                written_total += produced;
            }

            if (rc == c.Z_STREAM_END) return written_total;
            if (rc != c.Z_OK and rc != c.Z_BUF_ERROR) return error.CompressionFailed;
            if (stream.avail_out != 0) break;
        }

        input_pos += take;
        if (input_pos == input.len and flush == c.Z_FINISH) continue;
    }
}

/// Emit a human-readable inspection report for an `.igz` index.
pub fn inspectIndex(writer: *std.Io.Writer, index: Index) !void {
    try writer.print(
        \\format: igz-v{d}
        \\chunking: {s}
        \\sequence_format: {s}
        \\read_mode: {s}
        \\read_length_mode: {s}
        \\chunks: {d}
        \\records: {d}
        \\compressed_bytes: {d}
        \\uncompressed_bytes: {d}
        \\
,
        .{
            index.header.version,
            @tagName(index.header.chunking_mode),
            @tagName(index.header.sequence_format),
            @tagName(index.header.read_mode),
            @tagName(index.header.read_length_mode),
            index.header.chunk_count,
            index.header.total_records,
            index.header.total_compressed_bytes,
            index.header.total_uncompressed_bytes,
        },
    );
}

/// Callback interface for chunk emission.
const EmitFn = *const fn (ctx: *anyopaque, chunk: []const u8, record_count: u64, uncompressed_offset: u64, record_start: u64) anyerror!void;

/// Stream one gzip-compressed FASTQ through the strict chunker and call `emit`
/// for each completed chunk.
fn streamFastqChunks(
    allocator: std.mem.Allocator,
    input_reader: *std.Io.Reader,
    options: RepackOptions,
    emit_ctx: *anyopaque,
    emit: EmitFn,
) !void {
    if (options.sequence_format != .fastq_strict_4line) return error.UnsupportedSequenceFormat;
    if (options.chunking_mode != .gzip_members) return error.UnsupportedChunkingMode;
    switch (options.target) {
        .records => |n| if (n == 0) return error.EmptyChunkTarget,
        .uncompressed_bytes => |n| if (n == 0) return error.EmptyChunkTarget,
    }

    var gzip: zgz.GzipInput = undefined;
    try gzip.init(input_reader, .{ .allow_concatenated_members = true });
    defer gzip.deinit();

    var inflate_buffer = try allocator.alloc(u8, options.inflate_buffer_size);
    defer allocator.free(inflate_buffer);

    var chunk = ChunkBuffer.init(allocator);
    defer chunk.deinit();

    var parser: FastqStrictChunker = .{};
    var next_uncompressed_offset: u64 = 0;
    var next_record_start: u64 = 0;

    while (true) {
        const result = try gzip.readInto(inflate_buffer);
        for (inflate_buffer[0..result.written]) |byte| {
            const ended_record = try parser.feedByte(&chunk, byte);
            if (ended_record and options.target.shouldClose(chunk.record_count, chunk.uncompressed_size)) {
                try emit(emit_ctx, chunk.bytes.items, chunk.record_count, next_uncompressed_offset, next_record_start);
                next_uncompressed_offset += chunk.uncompressed_size;
                next_record_start += chunk.record_count;
                chunk.clearRetainingCapacity();
            }
        }

        if (result.end) break;
        if (result.written == 0) return error.InvalidFastqRecord;
    }

    try parser.finish();
    if (chunk.uncompressed_size != 0) {
        try emit(emit_ctx, chunk.bytes.items, chunk.record_count, next_uncompressed_offset, next_record_start);
    }
}

/// Return a deep copy of `index` with all compressed offsets shifted by the
/// given prelude byte length. This is the key post-processing primitive: the
/// repack engine writes data members starting at offset zero, then the final
/// self-indexed file prepends a gzip control member and every data-member
/// offset moves forward by exactly that control member size.
pub fn adjustIndexForPrependedPreludeAlloc(
    allocator: std.mem.Allocator,
    index: Index,
    prelude_size: u64,
) !Index {
    const chunks = try allocator.alloc(ChunkRecord, index.chunks.len);
    errdefer allocator.free(chunks);

    for (index.chunks, chunks) |src, *dst| {
        dst.* = src;
        dst.compressed_offset += prelude_size;
    }

    var header = index.header;
    header.total_compressed_bytes += prelude_size;
    return .{ .header = header, .chunks = chunks };
}

/// Return a copy of `index` whose compressed offsets are relocated from an
/// embedded stream-local basis to physical file-absolute offsets.
///
/// Embedded indexes written by `zgz-repack --index embedded` use
/// `OffsetBasis.igz_stream_relative`: `compressed_offset == 0` means the start
/// of that stream's `index_begin` zero member. When a user concatenates several
/// self-indexed gzip files with ordinary `cat`, each embedded stream keeps the
/// same local offsets. A scanner that discovers stream N at physical byte offset
/// `stream_base_offset` can call this helper to schedule seeks against the
/// combined file.
pub fn indexWithAbsoluteCompressedOffsetsAlloc(
    allocator: std.mem.Allocator,
    index: Index,
    stream_base_offset: u64,
) !Index {
    const chunks = try allocator.alloc(ChunkRecord, index.chunks.len);
    errdefer allocator.free(chunks);

    for (index.chunks, chunks) |src, *dst| {
        dst.* = src;
        dst.compressed_offset += stream_base_offset;
    }

    return .{ .header = index.header, .chunks = chunks };
}

/// Return the physical byte offset where the next concatenated self-indexed
/// stream would begin.
///
/// For embedded stream-relative indexes, `index.header.total_compressed_bytes`
/// is the complete length of the logical stream, including all prepended zero
/// IGZ control members and all following data members. A concatenation-aware
/// scanner can parse stream A at `stream_base_offset`, jump to this returned
/// offset, and then look for another `index_begin` zero member for stream B.
pub fn nextConcatenatedStreamOffset(stream_base_offset: u64, index: Index) u64 {
    return stream_base_offset + index.header.total_compressed_bytes;
}

/// Determine the smallest prelude mode for a fully adjusted embedded compact
/// index. Because the compact index has fixed-width entries, its byte length is
/// independent of the numeric offset values. We can therefore compute the
/// prelude size, adjust offsets by that size, and then write the final prelude
/// in one post-processing pass.
pub fn buildAdjustedEmbeddedPreludeIndexAlloc(
    allocator: std.mem.Allocator,
    data_only_index: Index,
) !struct { descriptor: PreludeDescriptor, index: Index, prelude_size: u64 } {
    var descriptor: PreludeDescriptor = .{
        .chunking_mode = data_only_index.header.chunking_mode,
        .sequence_format = data_only_index.header.sequence_format,
        .read_mode = data_only_index.header.read_mode,
        .read_length_mode = data_only_index.header.read_length_mode,
        .index_location = .embedded_compact,
        .role = .index_begin,
        .offset_basis = .igz_stream_relative,
        .chunk_count_hint = data_only_index.header.chunk_count,
        .total_records_hint = data_only_index.header.total_records,
    };

    const data_index_bytes_for_id = try buildCompactIndexBytesAlloc(allocator, data_only_index);
    defer allocator.free(data_index_bytes_for_id);
    const compact_id = deriveStreamId(data_index_bytes_for_id);
    descriptor.stream_id_hi = compact_id.hi;
    descriptor.stream_id_lo = compact_id.lo;

    // Historical single-member compact path. This is still useful for tiny
    // indexes and for tests, but production `--index embedded` now uses the
    // fragmented function below so large indexes remain self-contained.
    const prelude_size = try preludeMemberSizeForEmbeddedIndex(allocator, descriptor, data_only_index);
    descriptor.first_data_member_offset = prelude_size;

    var adjusted = try adjustIndexForPrependedPreludeAlloc(allocator, data_only_index, prelude_size);
    errdefer adjusted.deinit(allocator);

    const verified_size = try preludeMemberSizeForEmbeddedIndex(allocator, descriptor, adjusted);
    if (verified_size != prelude_size) return error.InvalidPrelude;

    return .{ .descriptor = descriptor, .index = adjusted, .prelude_size = prelude_size };
}

/// Build final descriptor/index metadata for the production fragmented embedded
/// index layout.
///
/// The function first computes how many zero-length gzip control members are
/// needed for the compact index bytes, then shifts every data-member compressed
/// offset by the total size of those control members. Because the compact index
/// encoding is fixed-width, the shifted offsets do not change the number of
/// fragments, so one deterministic post-processing pass is sufficient.
pub fn buildAdjustedFragmentedPreludeIndexAlloc(
    allocator: std.mem.Allocator,
    data_only_index: Index,
) !struct { descriptor: PreludeDescriptor, index: Index, prelude_size: u64 } {
    var descriptor: PreludeDescriptor = .{
        .chunking_mode = data_only_index.header.chunking_mode,
        .sequence_format = data_only_index.header.sequence_format,
        .read_mode = data_only_index.header.read_mode,
        .read_length_mode = data_only_index.header.read_length_mode,
        .index_location = .embedded_fragments,
        .role = .index_begin,
        .offset_basis = .igz_stream_relative,
        .chunk_count_hint = data_only_index.header.chunk_count,
        .total_records_hint = data_only_index.header.total_records,
    };

    const data_index_bytes = try buildCompactIndexBytesAlloc(allocator, data_only_index);
    defer allocator.free(data_index_bytes);
    const id = deriveStreamId(data_index_bytes);
    descriptor.stream_id_hi = id.hi;
    descriptor.stream_id_lo = id.lo;
    const prelude_size = try fragmentedPreludeTotalSizeAlloc(allocator, descriptor, data_index_bytes.len);
    descriptor.first_data_member_offset = prelude_size;

    var adjusted = try adjustIndexForPrependedPreludeAlloc(allocator, data_only_index, prelude_size);
    errdefer adjusted.deinit(allocator);

    const adjusted_index_bytes = try buildCompactIndexBytesAlloc(allocator, adjusted);
    defer allocator.free(adjusted_index_bytes);
    const verified_size = try fragmentedPreludeTotalSizeAlloc(allocator, descriptor, adjusted_index_bytes.len);
    if (verified_size != prelude_size) return error.InvalidPrelude;

    return .{ .descriptor = descriptor, .index = adjusted, .prelude_size = prelude_size };
}

const RepackEmitCtx = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    chunks: std.ArrayList(ChunkRecord),
    compression_level: i32,
    compressed_offset: u64 = 0,
    total_records: u64 = 0,
    total_uncompressed: u64 = 0,
};

fn repackEmit(ctx_opaque: *anyopaque, chunk: []const u8, record_count: u64, uncompressed_offset: u64, record_start: u64) !void {
    const ctx: *RepackEmitCtx = @ptrCast(@alignCast(ctx_opaque));
    const compressed_size = try compressGzipMember(ctx.writer, ctx.compression_level, chunk);
    try ctx.chunks.append(ctx.allocator, .{
        .member_id = ctx.chunks.items.len,
        .compressed_offset = ctx.compressed_offset,
        .compressed_size = compressed_size,
        .uncompressed_offset = uncompressed_offset,
        .uncompressed_size = chunk.len,
        .record_start = record_start,
        .record_count = record_count,
    });
    ctx.compressed_offset += compressed_size;
    ctx.total_records += record_count;
    ctx.total_uncompressed += chunk.len;
}

/// Repack a gzip FASTQ stream into concatenated, record-aligned gzip members.
///
/// The caller owns file opening/closing. This function writes the new data file
/// to `output_writer` and returns an allocated `.igz` index for the caller to
/// serialize with `writeIndex`.
pub fn repackGzipMembersAlloc(
    allocator: std.mem.Allocator,
    input_reader: *std.Io.Reader,
    output_writer: *std.Io.Writer,
    options: RepackOptions,
) !Index {
    var chunks: std.ArrayList(ChunkRecord) = .empty;
    errdefer chunks.deinit(allocator);

    // The repack engine deliberately writes data members only. Embedded IGZ
    // preludes are prepended by the CLI as a post-processing step after the
    // complete chunk table is known. This keeps the compression path streaming
    // and prevents half-known prelude descriptors from advertising wrong
    // offsets.
    var ctx: RepackEmitCtx = .{
        .allocator = allocator,
        .writer = output_writer,
        .chunks = chunks,
        .compression_level = options.compression_level,
        .compressed_offset = 0,
    };

    try streamFastqChunks(allocator, input_reader, options, &ctx, repackEmit);
    chunks = ctx.chunks;

    return .{
        .header = .{
            .version = igz_version,
            .chunking_mode = .gzip_members,
            .sequence_format = options.sequence_format,
            .read_mode = options.read_mode,
            .read_length_mode = options.read_length_mode,
            .chunk_count = chunks.items.len,
            .total_records = ctx.total_records,
            .total_uncompressed_bytes = ctx.total_uncompressed,
            .total_compressed_bytes = ctx.compressed_offset,
        },
        .chunks = try chunks.toOwnedSlice(allocator),
    };
}

/// Build an `.igz` index for an already repacked gzip-member file.
///
/// This first implementation intentionally treats indexing of arbitrary gzip as
/// unsupported. Indexing requires member offsets; for a file produced by
/// `zgz-repack`, persist the returned `.igz` index instead. A later version can
/// scan member boundaries and validate CRC/ISIZE without full decode.
pub fn indexExistingGzipMembersAlloc(
    allocator: std.mem.Allocator,
    data_reader: *std.Io.Reader,
    options: RepackOptions,
) !Index {
    _ = allocator;
    _ = data_reader;
    _ = options;
    return error.UnsupportedChunkingMode;
}

/// Sequential `cat` implementation for arbitrary gzip streams.
///
/// `zgz-cat` uses this when no `.igz` index is supplied. Indexed parallel cat is
/// architecturally separate because it needs seekable file handles and ordered
/// chunk emission.
pub fn cat(reader: *std.Io.Reader, writer: *std.Io.Writer) !zgz.StreamStats {
    return zgz.decompress(reader, writer, .{ .allow_concatenated_members = true });
}

/// Validate paired-end FASTQ chunk compatibility at the metadata level.
pub fn validatePairedEndIndexes(r1: Index, r2: Index) !void {
    if (r1.header.chunk_count != r2.header.chunk_count) return error.MismatchedPairedEndRecords;
    if (r1.header.total_records != r2.header.total_records) return error.MismatchedPairedEndRecords;
    for (r1.chunks, r2.chunks) |a, b| {
        if (a.record_start != b.record_start) return error.MismatchedPairedEndRecords;
        if (a.record_count != b.record_count) return error.MismatchedPairedEndRecords;
    }
}

// -----------------------------------------------------------------------------
// Unit tests: these are intentionally focused on logic that does not require
// zlib-ng at test time. End-to-end gzip/repack tests should live in the existing
// corpus/equivalence shell tests because they exercise the native dependency.
// -----------------------------------------------------------------------------

test "ChunkTarget closes at record or byte thresholds" {
    try std.testing.expect((ChunkTarget{ .records = 10 }).shouldClose(10, 1));
    try std.testing.expect(!(ChunkTarget{ .records = 10 }).shouldClose(9, 1_000_000));
    try std.testing.expect((ChunkTarget{ .uncompressed_bytes = 100 }).shouldClose(1, 100));
    try std.testing.expect(!(ChunkTarget{ .uncompressed_bytes = 100 }).shouldClose(10, 99));
}

test "strict four-line FASTQ chunker counts complete records" {
    var chunk = ChunkBuffer.init(std.testing.allocator);
    defer chunk.deinit();
    var parser: FastqStrictChunker = .{};
    const fastq = "@r1\nACGT\n+\n!!!!\n@r2\nAA\n+\n##\n";
    var ended: u64 = 0;
    for (fastq) |b| {
        if (try parser.feedByte(&chunk, b)) ended += 1;
    }
    try parser.finish();
    try std.testing.expectEqual(@as(u64, 2), ended);
    try std.testing.expectEqual(@as(u64, 2), chunk.record_count);
    try std.testing.expectEqual(@as(u64, fastq.len), chunk.uncompressed_size);
}

test "strict four-line FASTQ chunker rejects sequence/quality length mismatch" {
    var chunk = ChunkBuffer.init(std.testing.allocator);
    defer chunk.deinit();
    var parser: FastqStrictChunker = .{};
    const bad = "@r1\nACGT\n+\n!!!\n";
    var got_error = false;
    for (bad) |b| {
        _ = parser.feedByte(&chunk, b) catch |err| {
            try std.testing.expectEqual(error.InvalidFastqRecord, err);
            got_error = true;
            break;
        };
    }
    try std.testing.expect(got_error);
}

test "paired-end index validation checks chunk and record alignment" {
    const chunks_a = [_]ChunkRecord{.{
        .member_id = 0,
        .compressed_offset = 0,
        .compressed_size = 10,
        .uncompressed_offset = 0,
        .uncompressed_size = 100,
        .record_start = 0,
        .record_count = 2,
    }};
    const chunks_b = chunks_a;
    const a: Index = .{ .header = .{ .chunk_count = 1, .total_records = 2 }, .chunks = @constCast(&chunks_a) };
    const b: Index = .{ .header = .{ .chunk_count = 1, .total_records = 2 }, .chunks = @constCast(&chunks_b) };
    try validatePairedEndIndexes(a, b);
}

test "IGZ prelude payload round-trips" {
    const descriptor: PreludeDescriptor = .{
        .chunking_mode = .gzip_members,
        .sequence_format = .fastq_strict_4line,
        .read_mode = .paired_end,
        .read_length_mode = .short_reads,
        .index_location = .sidecar,
        .role = .index_begin,
        .offset_basis = .igz_stream_relative,
        .stream_id_hi = 0x0123456789abcdef,
        .stream_id_lo = 0xfedcba9876543210,
        .first_data_member_offset = 123,
        .chunk_count_hint = 7,
        .total_records_hint = 42,
        .flags = 99,
    };
    const payload = try buildPreludePayloadAlloc(std.testing.allocator, descriptor);
    defer std.testing.allocator.free(payload);
    const parsed = try parsePreludePayload(payload);
    try std.testing.expectEqual(descriptor.version, parsed.version);
    try std.testing.expectEqual(descriptor.chunking_mode, parsed.chunking_mode);
    try std.testing.expectEqual(descriptor.sequence_format, parsed.sequence_format);
    try std.testing.expectEqual(descriptor.read_mode, parsed.read_mode);
    try std.testing.expectEqual(descriptor.read_length_mode, parsed.read_length_mode);
    try std.testing.expectEqual(descriptor.index_location, parsed.index_location);
    try std.testing.expectEqual(descriptor.role, parsed.role);
    try std.testing.expectEqual(descriptor.offset_basis, parsed.offset_basis);
    try std.testing.expectEqual(descriptor.stream_id_hi, parsed.stream_id_hi);
    try std.testing.expectEqual(descriptor.stream_id_lo, parsed.stream_id_lo);
    try std.testing.expectEqual(descriptor.first_data_member_offset, parsed.first_data_member_offset);
    try std.testing.expectEqual(descriptor.chunk_count_hint, parsed.chunk_count_hint);
    try std.testing.expectEqual(descriptor.total_records_hint, parsed.total_records_hint);
    try std.testing.expectEqual(descriptor.flags, parsed.flags);
}

test "embedded compact index adjusts offsets after prepended prelude" {
    const chunks = [_]ChunkRecord{
        .{
            .member_id = 0,
            .compressed_offset = 0,
            .compressed_size = 10,
            .uncompressed_offset = 0,
            .uncompressed_size = 100,
            .record_start = 0,
            .record_count = 2,
        },
        .{
            .member_id = 1,
            .compressed_offset = 10,
            .compressed_size = 11,
            .uncompressed_offset = 100,
            .uncompressed_size = 120,
            .record_start = 2,
            .record_count = 3,
        },
    };
    const data_index: Index = .{
        .header = .{
            .chunking_mode = .gzip_members,
            .sequence_format = .fastq_strict_4line,
            .read_mode = .single_end,
            .read_length_mode = .long_reads,
            .chunk_count = chunks.len,
            .total_records = 5,
            .total_uncompressed_bytes = 220,
            .total_compressed_bytes = 21,
        },
        .chunks = @constCast(&chunks),
    };

    var built = try buildAdjustedEmbeddedPreludeIndexAlloc(std.testing.allocator, data_index);
    defer built.index.deinit(std.testing.allocator);

    try std.testing.expect(built.prelude_size > 0);
    try std.testing.expectEqual(built.prelude_size, built.index.chunks[0].compressed_offset);
    try std.testing.expectEqual(built.prelude_size + 10, built.index.chunks[1].compressed_offset);
    try std.testing.expectEqual(@as(u64, 21) + built.prelude_size, built.index.header.total_compressed_bytes);

    const payload = try buildPreludePayloadWithIndexAlloc(std.testing.allocator, built.descriptor, built.index);
    defer std.testing.allocator.free(payload);
    var parsed = try parseEmbeddedIndexPayloadAlloc(std.testing.allocator, payload);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(built.index.header.chunk_count, parsed.header.chunk_count);
    try std.testing.expectEqual(built.index.chunks[1].compressed_offset, parsed.chunks[1].compressed_offset);
}

test "IGZ prelude member is gzip compatible and parses from FEXTRA" {
    var storage: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(storage[0..]);
    const descriptor: PreludeDescriptor = .{
        .chunking_mode = .gzip_members,
        .index_location = .sidecar,
        .first_data_member_offset = 77,
    };
    const written = try writePreludeMember(std.testing.allocator, &writer, descriptor);
    const bytes = fixedWriterWritten(&writer, storage[0..]);
    try std.testing.expectEqual(written, bytes.len);
    try std.testing.expectEqual(@as(u8, 0x1f), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), bytes[1]);
    try std.testing.expect((bytes[3] & gzip_fextra) != 0);

    var reader: std.Io.Reader = .fixed(bytes);
    const probe = try probePrelude(&reader, std.testing.allocator);
    switch (probe) {
        .absent => return error.InvalidPrelude,
        .present => |parsed| {
            try std.testing.expectEqual(descriptor.chunking_mode, parsed.chunking_mode);
            try std.testing.expectEqual(descriptor.index_location, parsed.index_location);
            try std.testing.expectEqual(descriptor.first_data_member_offset, parsed.first_data_member_offset);
        },
    }
}

fn fixedWriterWritten(writer: *const std.Io.Writer, backing: []const u8) []const u8 {
    return backing[0..writer.end];
}

test "fragmented embedded index spans multiple zero prelude members" {
    const chunk_count: usize = 2_000;
    const chunks = try std.testing.allocator.alloc(ChunkRecord, chunk_count);
    defer std.testing.allocator.free(chunks);
    for (chunks, 0..) |*chunk, i| {
        chunk.* = .{
            .member_id = @as(u64, @intCast(i)),
            .compressed_offset = @as(u64, @intCast(i)) * 100,
            .compressed_size = 100,
            .uncompressed_offset = @as(u64, @intCast(i)) * 1_000,
            .uncompressed_size = 1_000,
            .record_start = @as(u64, @intCast(i)) * 10,
            .record_count = 10,
        };
    }
    const data_index: Index = .{
        .header = .{
            .chunking_mode = .gzip_members,
            .sequence_format = .fastq_strict_4line,
            .read_mode = .single_end,
            .read_length_mode = .long_reads,
            .chunk_count = @as(u64, @intCast(chunk_count)),
            .total_records = @as(u64, @intCast(chunk_count)) * 10,
            .total_uncompressed_bytes = @as(u64, @intCast(chunk_count)) * 1_000,
            .total_compressed_bytes = @as(u64, @intCast(chunk_count)) * 100,
        },
        .chunks = chunks,
    };

    var built = try buildAdjustedFragmentedPreludeIndexAlloc(std.testing.allocator, data_index);
    defer built.index.deinit(std.testing.allocator);
    try std.testing.expectEqual(PreludeIndexLocation.embedded_fragments, built.descriptor.index_location);
    try std.testing.expectEqual(built.prelude_size, built.index.chunks[0].compressed_offset);

    const index_bytes = try buildCompactIndexBytesAlloc(std.testing.allocator, built.index);
    defer std.testing.allocator.free(index_bytes);
    const descriptor_payload = try buildPreludePayloadAlloc(std.testing.allocator, built.descriptor);
    defer std.testing.allocator.free(descriptor_payload);
    const capacity = try embeddedFragmentPayloadCapacity(descriptor_payload.len);
    const fragment_count = try embeddedFragmentCount(index_bytes.len, capacity);
    try std.testing.expect(fragment_count > 1);

    var payloads = try std.testing.allocator.alloc([]u8, fragment_count);
    defer {
        for (payloads) |payload| std.testing.allocator.free(payload);
        std.testing.allocator.free(payloads);
    }

    const crc = checksumEmbeddedIndex(index_bytes);
    var cursor: usize = 0;
    var fragment_id: u32 = 0;
    while (fragment_id < fragment_count) : (fragment_id += 1) {
        const take = @min(index_bytes.len - cursor, capacity);
        var fragment_descriptor = built.descriptor;
        fragment_descriptor.role = if (fragment_id == 0) .index_begin else .index_fragment;
        payloads[@as(usize, @intCast(fragment_id))] = try buildPreludeFragmentPayloadAlloc(
            std.testing.allocator,
            fragment_descriptor,
            fragment_id,
            fragment_count,
            index_bytes.len,
            crc,
            index_bytes[cursor .. cursor + take],
        );
        cursor += take;
    }

    var parsed = try parseEmbeddedIndexPayloadsAlloc(std.testing.allocator, payloads);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(built.index.header.chunk_count, parsed.header.chunk_count);
    try std.testing.expectEqual(built.index.header.total_compressed_bytes, parsed.header.total_compressed_bytes);
    try std.testing.expectEqual(built.index.chunks[chunk_count - 1].compressed_offset, parsed.chunks[chunk_count - 1].compressed_offset);
}

test "fragmented IGZ prelude members are readable as consecutive zero gzip members" {
    const chunks = [_]ChunkRecord{
        .{ .member_id = 0, .compressed_offset = 0, .compressed_size = 10, .uncompressed_offset = 0, .uncompressed_size = 100, .record_start = 0, .record_count = 2 },
        .{ .member_id = 1, .compressed_offset = 10, .compressed_size = 11, .uncompressed_offset = 100, .uncompressed_size = 120, .record_start = 2, .record_count = 3 },
    };
    const data_index: Index = .{
        .header = .{
            .chunking_mode = .gzip_members,
            .sequence_format = .fastq_strict_4line,
            .read_mode = .single_end,
            .read_length_mode = .long_reads,
            .chunk_count = chunks.len,
            .total_records = 5,
            .total_uncompressed_bytes = 220,
            .total_compressed_bytes = 21,
        },
        .chunks = @constCast(&chunks),
    };

    var built = try buildAdjustedFragmentedPreludeIndexAlloc(std.testing.allocator, data_index);
    defer built.index.deinit(std.testing.allocator);

    var storage: [32 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(storage[0..]);
    const written = try writePreludeMembersWithFragmentedIndex(std.testing.allocator, &writer, built.descriptor, built.index);
    try std.testing.expectEqual(built.prelude_size, written);

    const bytes = fixedWriterWritten(&writer, storage[0..]);
    var reader: std.Io.Reader = .fixed(bytes);
    var payloads = try readPreludePayloadsAlloc(&reader, std.testing.allocator, 16);
    defer payloads.deinit(std.testing.allocator);
    try std.testing.expect(payloads.items.len >= 1);
    const first_descriptor = try parsePreludePayload(payloads.items[0]);
    try std.testing.expectEqual(PreludeRole.index_begin, first_descriptor.role);
    try std.testing.expectEqual(OffsetBasis.igz_stream_relative, first_descriptor.offset_basis);
    if (payloads.items.len > 1) {
        const second_descriptor = try parsePreludePayload(payloads.items[1]);
        try std.testing.expectEqual(PreludeRole.index_fragment, second_descriptor.role);
        try std.testing.expectEqual(first_descriptor.stream_id_hi, second_descriptor.stream_id_hi);
        try std.testing.expectEqual(first_descriptor.stream_id_lo, second_descriptor.stream_id_lo);
    }

    var parsed = try parseEmbeddedIndexPayloadsAlloc(std.testing.allocator, payloads.items);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expectEqual(built.index.header.chunk_count, parsed.header.chunk_count);
    try std.testing.expectEqual(built.index.chunks[1].compressed_offset, parsed.chunks[1].compressed_offset);
}


test "fragmented embedded index rejects fragments from different concatenated streams" {
    const chunks = [_]ChunkRecord{
        .{ .member_id = 0, .compressed_offset = 0, .compressed_size = 10, .uncompressed_offset = 0, .uncompressed_size = 100, .record_start = 0, .record_count = 2 },
    };
    const data_index: Index = .{
        .header = .{
            .chunking_mode = .gzip_members,
            .sequence_format = .fastq_strict_4line,
            .read_mode = .single_end,
            .read_length_mode = .long_reads,
            .chunk_count = chunks.len,
            .total_records = 2,
            .total_uncompressed_bytes = 100,
            .total_compressed_bytes = 10,
        },
        .chunks = @constCast(&chunks),
    };

    const index_bytes = try buildCompactIndexBytesAlloc(std.testing.allocator, data_index);
    defer std.testing.allocator.free(index_bytes);

    var descriptor: PreludeDescriptor = .{
        .chunking_mode = .gzip_members,
        .sequence_format = .fastq_strict_4line,
        .read_mode = .single_end,
        .read_length_mode = .long_reads,
        .index_location = .embedded_fragments,
        .role = .index_begin,
        .offset_basis = .igz_stream_relative,
        .stream_id_hi = 1,
        .stream_id_lo = 2,
        .first_data_member_offset = 0,
        .chunk_count_hint = 1,
        .total_records_hint = 2,
    };

    const crc = checksumEmbeddedIndex(index_bytes);
    const half = index_bytes.len / 2;
    const first = try buildPreludeFragmentPayloadAlloc(std.testing.allocator, descriptor, 0, 2, index_bytes.len, crc, index_bytes[0..half]);
    defer std.testing.allocator.free(first);

    descriptor.role = .index_fragment;
    descriptor.stream_id_lo = 3; // simulate fragment from another concatenated stream
    const second = try buildPreludeFragmentPayloadAlloc(std.testing.allocator, descriptor, 1, 2, index_bytes.len, crc, index_bytes[half..]);
    defer std.testing.allocator.free(second);

    const payloads = [_][]const u8{ first, second };
    try std.testing.expectError(error.MismatchedPreludeFragments, parseEmbeddedIndexPayloadsAlloc(std.testing.allocator, payloads[0..]));
}

test "stream-relative embedded index can be relocated after gzip concatenation" {
    const chunks = [_]ChunkRecord{
        .{ .member_id = 0, .compressed_offset = 100, .compressed_size = 10, .uncompressed_offset = 0, .uncompressed_size = 100, .record_start = 0, .record_count = 2 },
        .{ .member_id = 1, .compressed_offset = 110, .compressed_size = 11, .uncompressed_offset = 100, .uncompressed_size = 120, .record_start = 2, .record_count = 3 },
    };
    const local: Index = .{
        .header = .{
            .chunking_mode = .gzip_members,
            .sequence_format = .fastq_strict_4line,
            .read_mode = .single_end,
            .read_length_mode = .long_reads,
            .chunk_count = chunks.len,
            .total_records = 5,
            .total_uncompressed_bytes = 220,
            .total_compressed_bytes = 121,
        },
        .chunks = @constCast(&chunks),
    };

    var absolute = try indexWithAbsoluteCompressedOffsetsAlloc(std.testing.allocator, local, 1_000_000);
    defer absolute.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1_000_100), absolute.chunks[0].compressed_offset);
    try std.testing.expectEqual(@as(u64, 1_000_110), absolute.chunks[1].compressed_offset);
    try std.testing.expectEqual(local.header.total_compressed_bytes, absolute.header.total_compressed_bytes);
    try std.testing.expectEqual(@as(u64, 1_000_121), nextConcatenatedStreamOffset(1_000_000, local));
}
