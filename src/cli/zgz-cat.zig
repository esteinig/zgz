const std = @import("std");
const zgz = @import("zgz");
const common = @import("utils.zig");

fn usage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\Usage:
        \\  zgz-cat [options] FILE.gz
        \\
        \\Options:
        \\  --in-buffer BYTES       Input buffer, default 1M.
        \\  --out-buffer BYTES      Output buffer, default 1M.
        \\  --index FILE.igz        Accepted for forward compatibility (current implementation processes sequentially).
        \\  --verbose               Report whether an embedded IGZ prelude was detected.
        \\  -h, --help              Show help.
        \\
    );
}

const Options = struct {
    input: ?[]const u8 = null,
    index: ?[]const u8 = null,
    in_buffer: usize = zgz.igz.default_io_buffer_size,
    out_buffer: usize = zgz.igz.default_io_buffer_size,
    verbose: bool = false,
};

fn parse(argv: []const []const u8, stderr: *std.Io.Writer) !Options {
    var o: Options = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) { try usage(stderr); return error.HelpRequested; }
        else if (std.mem.eql(u8, a, "--verbose")) { o.verbose = true; }
        else if (std.mem.eql(u8, a, "--in-buffer")) { i += 1; if (i >= argv.len) return error.InvalidArguments; o.in_buffer = try common.parseSize(argv[i]); }
        else if (std.mem.eql(u8, a, "--out-buffer")) { i += 1; if (i >= argv.len) return error.InvalidArguments; o.out_buffer = try common.parseSize(argv[i]); }
        else if (std.mem.eql(u8, a, "--index")) { i += 1; if (i >= argv.len) return error.InvalidArguments; o.index = argv[i]; }
        else if (std.mem.startsWith(u8, a, "-")) { try stderr.print("zgz-cat: unknown option: {s}\n", .{a}); return error.InvalidArguments; }
        else { if (o.input != null) return error.InvalidArguments; o.input = a; }
    }
    return o;
}

fn reportPrelude(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    stderr: *std.Io.Writer,
    in_buffer: usize,
) !void {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const buf = try allocator.alloc(u8, in_buffer);
    defer allocator.free(buf);
    var reader = file.readerStreaming(io, buf);
    var payloads = zgz.igz.readPreludePayloadsAlloc(&reader.interface, allocator, 1_000_000) catch |err| {
        try stderr.print("zgz-cat: could not probe IGZ prelude: {s}; using sequential gzip fallback\n", .{@errorName(err)});
        return;
    };
    defer payloads.deinit(allocator);
    if (payloads.items.len == 0) {
        try stderr.writeAll("zgz-cat: no embedded IGZ prelude found; using sequential gzip fallback\n");
        return;
    }

    const p = try zgz.igz.parsePreludePayload(payloads.items[0]);
    if (p.index_location == .embedded_compact or p.index_location == .embedded_fragments) {
        var embedded = try zgz.igz.parseEmbeddedIndexPayloadsAlloc(allocator, payloads.items);
        defer embedded.deinit(allocator);
        try stderr.print(
            "zgz-cat: embedded IGZ index detected: layout={s} role={s} basis={s} stream_id={x:0>16}{x:0>16} prelude_members={d} chunks={d} first_data_member_offset={d}; current cat path is sequential fallback\n",
            .{ @tagName(p.index_location), @tagName(p.role), @tagName(p.offset_basis), p.stream_id_hi, p.stream_id_lo, payloads.items.len, embedded.header.chunk_count, p.first_data_member_offset },
        );
    } else {
        try stderr.print(
            "zgz-cat: embedded IGZ prelude detected: chunking={s} index_location={s} role={s} basis={s} stream_id={x:0>16}{x:0>16} first_data_member_offset={d}; current cat path is sequential fallback\n",
            .{ @tagName(p.chunking_mode), @tagName(p.index_location), @tagName(p.role), @tagName(p.offset_basis), p.stream_id_hi, p.stream_id_lo, p.first_data_member_offset },
        );
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var stderr_file = std.Io.File.stderr();
    var stderr_buf: [16 * 1024]u8 = undefined;
    var stderr = stderr_file.writer(io, &stderr_buf);
    defer stderr.interface.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const o = parse(argv, &stderr.interface) catch |err| switch (err) { error.HelpRequested => return, else => return err };
    const input = o.input orelse { try usage(&stderr.interface); return error.InvalidArguments; };

    if (o.index != null) try stderr.interface.writeAll("zgz-cat: --index is parsed but indexed parallel cat is not enabled in this MVP; falling back to sequential gzip-member decoding\n");
    if (o.verbose) try reportPrelude(io, allocator, input, &stderr.interface, o.in_buffer);

    var file = try std.Io.Dir.cwd().openFile(io, input, .{});
    defer file.close(io);

    const in_buf = try allocator.alloc(u8, o.in_buffer);
    defer allocator.free(in_buf);

    var reader = file.readerStreaming(io, in_buf);
    var stdout_file = std.Io.File.stdout();
    const out_buf = try allocator.alloc(u8, o.out_buffer);
    defer allocator.free(out_buf);
    var writer = stdout_file.writer(io, out_buf);

    _ = try zgz.igz.cat(&reader.interface, &writer.interface);
    try writer.interface.flush();
}
