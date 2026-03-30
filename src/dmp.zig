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

const diff_mod = @import("dmp/diff.zig");
const diff_fn_mod = @import("diff_fn.zig");
const diff_context_mod = @import("diff_context.zig");
const zdelta_mod = @import("zdelta.zig");

pub const Diff = diff_mod.Diff;
pub const DiffFn = diff_fn_mod.DiffFn;
pub const Edit = diff_mod.Edit;
pub const DiffConfig = diff_mod.DiffConfig;
pub const DiffDecorations = diff_mod.DiffDecorations;
pub const ZDeltaVersion = zdelta_mod.ZDeltaVersion;
pub const ZDeltaError = zdelta_mod.ZDeltaError;
pub const writeDecoratedEdit = diff_mod.writeDecoratedEdit;
pub const DiffContext = diff_context_mod;
pub const Patch = @import("dmp/Patch.zig");

test {
    _ = Diff;
    _ = DiffFn(.{});
    _ = DiffContext;
    _ = Patch;
}
