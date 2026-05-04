const std = @import("std");
const zgz = @import("zgz");

const CliOptions = struct {
    input_path: ?[]const u8 = null,
    input_buffer_size: usize = zgz.default_input_buffer_size,
    output_buffer_size: usize = zgz.default_output_buffer_size,
    max_output_bytes: ?usize = null,
    allow_concatenated_members: bool = true,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

    var stderr_buf: [16 * 1024]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr = stderr_file.writer(io, &stderr_buf);
    defer stderr.interface.flush() catch {};

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    const options = parseArgs(argv, &stderr.interface) catch |err| {
        switch (err) {
            error.HelpRequested => return,
            else => return err,
        }
    };

    const input_path = options.input_path orelse {
        try usage(&stderr.interface);
        return error.InvalidArguments;
    };
    

    if (options.input_buffer_size == 0) {
        try stderr.interface.writeAll("zgz: --in-buffer must be greater than zero\n");
        return error.InvalidArguments;
    }

    if (options.output_buffer_size == 0) {
        try stderr.interface.writeAll("zgz: --out-buffer must be greater than zero\n");
        return error.InvalidArguments;
    }

    // CLI policy: zero is not useful for a cat-like command. The library may
    // still support `.max_output_bytes = 0` as "allow zero output bytes only".
    if (options.max_output_bytes) |max_output_bytes| {
        if (max_output_bytes == 0) {
            try stderr.interface.writeAll(
                "zgz: --max-output must be greater than zero\n",
            );
            return error.InvalidArguments;
        }
    }

    var input_file = std.Io.Dir.cwd().openFile(io, input_path, .{}) catch |err| {
        try stderr.interface.print("zgz: failed to open '{s}': {s}\n", .{
            input_path,
            @errorName(err),
        });
        return err;
    };
    defer input_file.close(io);

    const input_buffer = try allocator.alloc(u8, options.input_buffer_size);
    defer allocator.free(input_buffer);

    var input_reader = input_file.readerStreaming(io, input_buffer);

    var stdout_file = std.Io.File.stdout();

    const output_buffer = try allocator.alloc(u8, options.output_buffer_size);
    defer allocator.free(output_buffer);

    var stdout_writer = stdout_file.writer(io, output_buffer);

    _ = zgz.decompress(
        &input_reader.interface,
        &stdout_writer.interface,
        .{
            .allow_concatenated_members = options.allow_concatenated_members,
            .max_output_bytes = options.max_output_bytes,
        },
    ) catch |err| switch (err) {
        error.ReadFailed => return input_reader.err orelse err,
        error.WriteFailed => return stdout_writer.err orelse err,
        else => {
            try stderr.interface.print("zgz: failed to decompress '{s}': {s}\n", .{
                input_path,
                @errorName(err),
            });
            return err;
        },
    };

    stdout_writer.interface.flush() catch |err| switch (err) {
        error.WriteFailed => return stdout_writer.err orelse err,
    };
}

/// Parse command-line arguments.
///
/// `argv[0]` is the executable name. This parser intentionally stays tiny:
/// benchmark tools should have boring argument handling, not a command-line
/// framework hiding in the bushes.
fn parseArgs(argv: []const []const u8, stderr: *std.Io.Writer) !CliOptions {
    var options: CliOptions = .{};

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try usage(stderr);
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--no-concat")) {
            options.allow_concatenated_members = false;
        } else if (std.mem.eql(u8, arg, "--in-buffer")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.writeAll("zgz: --in-buffer requires a byte count\n");
                return error.InvalidArguments;
            }
            options.input_buffer_size = try parseSize(argv[i]);
        } else if (std.mem.eql(u8, arg, "--out-buffer")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.writeAll("zgz: --out-buffer requires a byte count\n");
                return error.InvalidArguments;
            }
            options.output_buffer_size = try parseSize(argv[i]);
        } else if (std.mem.eql(u8, arg, "--max-output")) {
            i += 1;
            if (i >= argv.len) {
                try stderr.writeAll("zgz: --max-output requires a byte count\n");
                return error.InvalidArguments;
            }
            options.max_output_bytes = try parseSize(argv[i]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("zgz: unknown option: {s}\n", .{arg});
            return error.InvalidArguments;
        } else {
            if (options.input_path != null) {
                try stderr.writeAll("zgz: expected exactly one input file\n");
                return error.InvalidArguments;
            }

            options.input_path = arg;
        }
    }

    return options;
}

fn parseSize(text: []const u8) !usize {
    if (text.len == 0) return error.InvalidArguments;

    var multiplier: usize = 1;
    var digits = text;

    const suffix = text[text.len - 1];
    switch (suffix) {
        'k', 'K' => {
            multiplier = 1024;
            digits = text[0 .. text.len - 1];
        },
        'm', 'M' => {
            multiplier = 1024 * 1024;
            digits = text[0 .. text.len - 1];
        },
        'g', 'G' => {
            multiplier = 1024 * 1024 * 1024;
            digits = text[0 .. text.len - 1];
        },
        else => {},
    }

    if (digits.len == 0) return error.InvalidArguments;

    const base = try std.fmt.parseInt(usize, digits, 10);
    return std.math.mul(usize, base, multiplier) catch error.InvalidArguments;
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zgz [options] FILE.gz
        \\
        \\Options:
        \\  --in-buffer BYTES     File reader buffer. Supports K/M/G suffixes.
        \\                        Default: 256K.
        \\  --out-buffer BYTES    File writer buffer. Supports K/M/G suffixes.
        \\                        Default: 256K.
        \\  --max-output BYTES    Abort if decompressed output exceeds this cap.
        \\  --no-concat           Reject trailing gzip members or trailing data.
        \\  -h, --help            Show this help.
        \\
        \\Examples:
        \\  zgz sample.gz > /dev/null
        \\  zgz --in-buffer 1M --out-buffer 1M sample.gz > /dev/null
        \\
    );
}