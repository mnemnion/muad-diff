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
const diff_context_mod = @import("diff_context.zig");

pub const Diff = diff_mod.Diff;
pub const Edit = diff_mod.Edit;
pub const DiffConfig = diff_mod.DiffConfig;
pub const DiffDecorations = diff_mod.DiffDecorations;
pub const ZDeltaVersion = diff_mod.ZDeltaVersion;
pub const ZDeltaError = diff_mod.ZDeltaError;
pub const writeDecoratedEdit = diff_mod.writeDecoratedEdit;
pub const DiffContext = diff_context_mod;
pub const Patch = @import("dmp/Patch.zig");

test {
    _ = Diff;
    _ = DiffContext;
    _ = Patch;
}
