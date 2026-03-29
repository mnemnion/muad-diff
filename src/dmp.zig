//! DiffMatchPatch Library
//!
//! A port of the old-school letter diff library, diff-match-patch.
//!
//! Now with Zig characteristics.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const ArrayList = std.array_list.Managed;

pub const Diff = @import("dmp/Diff.zig").Diff;
pub const DiffContext = @import("diff_context.zig");
pub const Patch = @import("dmp/Patch.zig");

test {
    _ = Diff;
    _ = DiffContext;
    _ = Patch;
}
