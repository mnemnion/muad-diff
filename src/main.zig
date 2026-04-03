//! Main executable of muad-diff.
const std = @import("std");
const cli = @import("muad_diff.zig");

pub fn main() !void {
    const code = try cli.main();
    std.process.exit(code);
}
