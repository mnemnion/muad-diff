//! Main executable of muad-diff.
const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    const code = try cli.main();
    std.process.exit(code);
}
