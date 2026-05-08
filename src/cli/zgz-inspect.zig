const std = @import("std");
const zgz = @import("zgz");

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage:
        \\  zgz-inspect FILE.igz
        \\  zgz-inspect FILE.fastq.gz
        \\
        \\For .igz inputs this prints the full binary sidecar index. For .gz inputs
        \\it probes the first gzip member for an embedded IGZ prelude descriptor.
        \\
    );
}

fn inspectPrelude(writer: *std.Io.Writer, descriptor: zgz.igz.PreludeDescriptor) !void {
    try writer.print(
        \\format: igz-prelude-v{d}
        \\chunking: {s}
        \\sequence_format: {s}
        \\read_mode: {s}
        \\read_length_mode: {s}
        \\index_location: {s}
        \\role: {s}
        \\offset_basis: {s}
        \\stream_id: {x:0>16}{x:0>16}
        \\first_data_member_offset: {d}
        \\chunk_count_hint: {d}
        \\total_records_hint: {d}
        \\flags: {d}
        \\
,
        .{
            descriptor.version,
            @tagName(descriptor.chunking_mode),
            @tagName(descriptor.sequence_format),
            @tagName(descriptor.read_mode),
            @tagName(descriptor.read_length_mode),
            @tagName(descriptor.index_location),
            @tagName(descriptor.role),
            @tagName(descriptor.offset_basis),
            descriptor.stream_id_hi,
            descriptor.stream_id_lo,
            descriptor.first_data_member_offset,
            descriptor.chunk_count_hint,
            descriptor.total_records_hint,
            descriptor.flags,
        },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var stderr_file = std.Io.File.stderr();
    var stderr_buf: [16 * 1024]u8 = undefined;
    var stderr = stderr_file.writer(io, &stderr_buf);
    defer stderr.interface.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 2 or std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help")) { try usage(&stderr.interface); return; }

    var stdout_file = std.Io.File.stdout();
    var out_buf: [16 * 1024]u8 = undefined;
    var stdout = stdout_file.writer(io, &out_buf);
    defer stdout.interface.flush() catch {};

    const path = argv[1];
    const in_buf = try allocator.alloc(u8, zgz.igz.default_io_buffer_size);
    defer allocator.free(in_buf);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, in_buf);

    if (std.mem.endsWith(u8, path, ".igz")) {
        var index = try zgz.igz.readIndexAlloc(allocator, &reader.interface);
        defer index.deinit(allocator);
        try zgz.igz.inspectIndex(&stdout.interface, index);
        return;
    }

    var payloads = try zgz.igz.readPreludePayloadsAlloc(&reader.interface, allocator, 1_000_000);
    defer payloads.deinit(allocator);
    if (payloads.items.len == 0) {
        try stdout.interface.writeAll("format: gzip\nigz_prelude: absent\n");
        return;
    }

    const descriptor = try zgz.igz.parsePreludePayload(payloads.items[0]);
    try inspectPrelude(&stdout.interface, descriptor);
    try stdout.interface.print("prelude_members: {d}\n", .{payloads.items.len});

    if (descriptor.index_location == .embedded_compact or descriptor.index_location == .embedded_fragments) {
        var embedded = try zgz.igz.parseEmbeddedIndexPayloadsAlloc(allocator, payloads.items);
        defer embedded.deinit(allocator);
        
        try stdout.interface.writeAll("\nembedded_index:\n");
        try zgz.igz.inspectIndex(&stdout.interface, embedded);
    }
}
