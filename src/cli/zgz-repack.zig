const std = @import("std");
const zgz = @import("zgz");
const common = @import("utils.zig");

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage:
        \\  zgz-repack [options] IN.fastq.gz OUT.fastq.gz [OUT.igz]
        \\
        \\Options:
        \\  --mode short|long                   short => records target, long => byte target. Default long.
        \\  --records N                         Records per gzip member, accepts k/m/g decimal suffixes.
        \\  --bytes BYTES                       Uncompressed bytes per gzip member, accepts K/M/G binary suffixes.
        \\  --level N                           zlib-ng gzip compression level. Default 6.
        \\  --index auto|sidecar|embedded|none  auto: prepend a full embedded IGZ index when it fits;
        \\                                          otherwise prepend descriptor + write .igz sidecar.
        \\                                      sidecar: full .igz sidecar only, no embedded prelude.
        \\                                      embedded: require full embedded compact index; fail if too large.
        \\                                      none: no index metadata.
        \\  --in-buffer BYTES            Input buffer. Default 1M.
        \\  --inflate-buffer BYTES       Inflate buffer. Default 1M.
        \\  -h, --help                   Show help.
        \\
    );
}

const Options = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    index: ?[]const u8 = null,
    opts: zgz.igz.RepackOptions = .{},
};

fn parseIndexStorage(value: []const u8) !zgz.igz.IndexStorageMode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "sidecar")) return .sidecar;
    if (std.mem.eql(u8, value, "embedded")) return .embedded;
    if (std.mem.eql(u8, value, "none")) return .none;
    return error.InvalidArguments;
}

fn parse(argv: []const []const u8, stderr: *std.Io.Writer) !Options {
    var o: Options = .{};
    var positional: usize = 0;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            try usage(stderr);
            return error.HelpRequested;
        } else if (std.mem.eql(u8, a, "--mode")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            if (std.mem.eql(u8, argv[i], "short")) {
                o.opts.read_length_mode = .short_reads;
                o.opts.target = .{ .records = zgz.igz.default_short_read_records_per_chunk };
            } else if (std.mem.eql(u8, argv[i], "long")) {
                o.opts.read_length_mode = .long_reads;
                o.opts.target = .{ .uncompressed_bytes = zgz.igz.default_long_read_chunk_bytes };
            } else return error.InvalidArguments;
        } else if (std.mem.eql(u8, a, "--records")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            o.opts.target = .{ .records = try common.parseU64(argv[i]) };
        } else if (std.mem.eql(u8, a, "--bytes")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            o.opts.target = .{ .uncompressed_bytes = try common.parseSize(argv[i]) };
        } else if (std.mem.eql(u8, a, "--level")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            o.opts.compression_level = try std.fmt.parseInt(i32, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--index")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            o.opts.index_storage = try parseIndexStorage(argv[i]);
        } else if (std.mem.eql(u8, a, "--in-buffer")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            o.opts.input_buffer_size = try common.parseSize(argv[i]);
        } else if (std.mem.eql(u8, a, "--inflate-buffer")) {
            i += 1;
            if (i >= argv.len) return error.InvalidArguments;
            o.opts.inflate_buffer_size = try common.parseSize(argv[i]);
        } else if (std.mem.startsWith(u8, a, "-")) {
            try stderr.print("zgz-repack: unknown option: {s}\n", .{a});
            return error.InvalidArguments;
        } else {
            switch (positional) {
                0 => o.input = a,
                1 => o.output = a,
                2 => o.index = a,
                else => return error.InvalidArguments,
            }
            positional += 1;
        }
    }
    return o;
}

fn defaultIndexPathAlloc(allocator: std.mem.Allocator, out_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.igz", .{out_path});
}

fn tempDataPathAlloc(allocator: std.mem.Allocator, out_path: []const u8) ![]u8 {
    // Parsimonious and deterministic. The final output is not created until the
    // temporary data-only repack has completed successfully. A future nicety can
    // switch this to a random name, but fixed naming keeps the first production
    // implementation easy to audit.
    return std.fmt.allocPrint(allocator, "{s}.zgz-data.tmp", .{out_path});
}

fn shouldWriteSidecar(mode: zgz.igz.IndexStorageMode) bool {
    return mode == .auto or mode == .sidecar;
}

fn writeSidecar(
    io: std.Io,
    allocator: std.mem.Allocator,
    index_path_opt: ?[]const u8,
    out_path: []const u8,
    index: zgz.igz.Index,
) !void {
    const idx_path = if (index_path_opt) |path| path else try defaultIndexPathAlloc(allocator, out_path);
    defer if (index_path_opt == null) allocator.free(idx_path);

    var idx_file = try std.Io.Dir.cwd().createFile(io, idx_path, .{ .truncate = true });
    defer idx_file.close(io);
    var idx_buf: [64 * 1024]u8 = undefined;
    var idx_writer = idx_file.writer(io, &idx_buf);
    try zgz.igz.writeIndex(&idx_writer.interface, index);
    try idx_writer.interface.flush();
}

fn copyFileToWriter(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    writer: *std.Io.Writer,
) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const buf = try allocator.alloc(u8, zgz.igz.default_io_buffer_size);
    defer allocator.free(buf);
    var reader = file.readerStreaming(io, buf);

    var copy_buf = try allocator.alloc(u8, zgz.igz.default_io_buffer_size);
    defer allocator.free(copy_buf);
    while (true) {
        const n = try reader.interface.readSliceShort(copy_buf);
        if (n == 0) break;
        try writer.writeAll(copy_buf[0..n]);
    }
}

fn repackDataOnly(
    io: std.Io,
    allocator: std.mem.Allocator,
    in_path: []const u8,
    data_path: []const u8,
    opts_in: zgz.igz.RepackOptions,
) !zgz.igz.Index {
    var opts = opts_in;
    opts.index_storage = .none;

    var in_file = try std.Io.Dir.cwd().openFile(io, in_path, .{});
    defer in_file.close(io);
    const in_buf = try allocator.alloc(u8, opts.input_buffer_size);
    defer allocator.free(in_buf);
    var in_reader = in_file.readerStreaming(io, in_buf);

    var out_file = try std.Io.Dir.cwd().createFile(io, data_path, .{ .truncate = true });
    defer out_file.close(io);
    const out_buf = try allocator.alloc(u8, zgz.igz.default_io_buffer_size);
    defer allocator.free(out_buf);
    var out_writer = out_file.writer(io, out_buf);

    var index = try zgz.igz.repackGzipMembersAlloc(allocator, &in_reader.interface, &out_writer.interface, opts);
    errdefer index.deinit(allocator);
    try out_writer.interface.flush();
    return index;
}

fn writeDescriptorPreludeFinal(
    io: std.Io,
    allocator: std.mem.Allocator,
    out_path: []const u8,
    data_path: []const u8,
    data_index: zgz.igz.Index,
) !zgz.igz.Index {
    var descriptor: zgz.igz.PreludeDescriptor = .{
        .chunking_mode = data_index.header.chunking_mode,
        .sequence_format = data_index.header.sequence_format,
        .read_mode = data_index.header.read_mode,
        .read_length_mode = data_index.header.read_length_mode,
        .index_location = .sidecar,
        .chunk_count_hint = data_index.header.chunk_count,
        .total_records_hint = data_index.header.total_records,
    };
    descriptor.first_data_member_offset = try zgz.igz.preludeMemberSizeForDescriptor(allocator, descriptor);

    var adjusted = try zgz.igz.adjustIndexForPrependedPreludeAlloc(allocator, data_index, descriptor.first_data_member_offset);
    errdefer adjusted.deinit(allocator);

    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out_file.close(io);
    const out_buf = try allocator.alloc(u8, zgz.igz.default_io_buffer_size);
    defer allocator.free(out_buf);
    var out_writer = out_file.writer(io, out_buf);

    _ = try zgz.igz.writePreludeMember(allocator, &out_writer.interface, descriptor);
    try copyFileToWriter(io, allocator, data_path, &out_writer.interface);
    try out_writer.interface.flush();
    return adjusted;
}

fn writeEmbeddedPreludeFinal(
    io: std.Io,
    allocator: std.mem.Allocator,
    out_path: []const u8,
    data_path: []const u8,
    data_index: zgz.igz.Index,
) !zgz.igz.Index {
    var built = try zgz.igz.buildAdjustedFragmentedPreludeIndexAlloc(allocator, data_index);
    errdefer built.index.deinit(allocator);

    var out_file = try std.Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out_file.close(io);
    const out_buf = try allocator.alloc(u8, zgz.igz.default_io_buffer_size);
    defer allocator.free(out_buf);
    var out_writer = out_file.writer(io, out_buf);

    const written = try zgz.igz.writePreludeMembersWithFragmentedIndex(allocator, &out_writer.interface, built.descriptor, built.index);
    if (written != built.prelude_size) return error.InvalidPrelude;
    try copyFileToWriter(io, allocator, data_path, &out_writer.interface);
    try out_writer.interface.flush();
    return built.index;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var stderr_file = std.Io.File.stderr();
    var stderr_buf: [16 * 1024]u8 = undefined;
    var stderr = stderr_file.writer(io, &stderr_buf);
    defer stderr.interface.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const o = parse(argv, &stderr.interface) catch |err| switch (err) {
        error.HelpRequested => return,
        else => return err,
    };

    const in_path = o.input orelse {
        try usage(&stderr.interface);
        return error.InvalidArguments;
    };
    const out_path = o.output orelse {
        try usage(&stderr.interface);
        return error.InvalidArguments;
    };

    switch (o.opts.index_storage) {
        .sidecar, .none => {
            var index = try repackDataOnly(io, allocator, in_path, out_path, o.opts);
            defer index.deinit(allocator);
            if (shouldWriteSidecar(o.opts.index_storage)) {
                try writeSidecar(io, allocator, o.index, out_path, index);
            }
        },
        .embedded, .auto => {
            const data_path = try tempDataPathAlloc(allocator, out_path);
            defer allocator.free(data_path);
            defer std.Io.Dir.cwd().deleteFile(io, data_path) catch {};

            var data_index = try repackDataOnly(io, allocator, in_path, data_path, o.opts);
            defer data_index.deinit(allocator);

            var final_index: zgz.igz.Index = undefined;
            var final_index_initialized = false;
            defer {
                if (final_index_initialized) final_index.deinit(allocator);
            }
            final_index = try writeEmbeddedPreludeFinal(io, allocator, out_path, data_path, data_index);
            final_index_initialized = true;

            // `--index embedded` and `--index auto` are self-contained by
            // default. If the caller supplies an explicit sidecar path, honor 
            // it as an additional audit/debug copy of the same final adjusted
            // index.
            if (o.index != null) {
                try writeSidecar(io, allocator, o.index, out_path, final_index);
            }
        },
    }
}
