const std = @import("std");

const Allocator = std.mem.Allocator;

/// De-initialize a *DiffList
pub fn deinitDiffList(allocator: Allocator, diffs: anytype) void {
    defer diffs.deinit(allocator);
    for (diffs.items) |*d| {
        d.deinit(allocator);
    }
}
