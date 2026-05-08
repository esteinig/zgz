const std = @import("std");

pub fn parseSize(text: []const u8) !usize {
    if (text.len == 0) return error.InvalidArguments;
    var multiplier: usize = 1;
    var digits = text;
    switch (text[text.len - 1]) {
        'k', 'K' => { multiplier = 1024; digits = text[0 .. text.len - 1]; },
        'm', 'M' => { multiplier = 1024 * 1024; digits = text[0 .. text.len - 1]; },
        'g', 'G' => { multiplier = 1024 * 1024 * 1024; digits = text[0 .. text.len - 1]; },
        else => {},
    }
    if (digits.len == 0) return error.InvalidArguments;
    const base = try std.fmt.parseInt(usize, digits, 10);
    return std.math.mul(usize, base, multiplier) catch error.InvalidArguments;
}

pub fn parseU64(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidArguments;
    var multiplier: u64 = 1;
    var digits = text;
    switch (text[text.len - 1]) {
        'k', 'K' => { multiplier = 1_000; digits = text[0 .. text.len - 1]; },
        'm', 'M' => { multiplier = 1_000_000; digits = text[0 .. text.len - 1]; },
        'g', 'G' => { multiplier = 1_000_000_000; digits = text[0 .. text.len - 1]; },
        else => {},
    }
    if (digits.len == 0) return error.InvalidArguments;
    const base = try std.fmt.parseInt(u64, digits, 10);
    return std.math.mul(u64, base, multiplier) catch error.InvalidArguments;
}

