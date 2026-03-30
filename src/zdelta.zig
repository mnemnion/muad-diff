//! ZDelta: MuadDiff native delta format.
//!
//! A "delta" in this context is a set of operations, which can be
//! performed on one file to transform it into another.  Unlike a
//! patch, it is inflexible and exact: applied to anything which is
//! not the intended file, it will reliably produce an incorrect result.

const Operation = Edit.Operation;

/// Version of zDelta format to use.
pub const ZDeltaVersion = enum {
    a,
    b,
};

/// Error set of zDelta operations.
pub const ZDeltaError = Allocator.Error || error{
    BadZDeltaHeader,
    UnknownZDeltaVersion,
    BadZDeltaEscape,
    BadZDeltaOperation,
    BadZDeltaNumber,
    ZDeltaLengthMismatch,
    InvalidZDeltaText,
};

pub const DeltaSpan = struct {
    offset: u32,
    len: u32,
};

pub const DeltaOp = union(enum) {
    insert: DeltaSpan,
    delete: u32,
    equal: u32,
};

pub const ZDelta = struct {
    version: ZDeltaVersion,
    insert_text: []u8,
    ops: []DeltaOp,

    pub fn deinit(delta: *ZDelta, allocator: Allocator) void {
        allocator.free(delta.insert_text);
        allocator.free(delta.ops);
        delta.* = undefined;
    }
};

/// Write a Diff in a zdelta format.  Currently supported are
/// formats `.a` and `.b`, see documentation for more details.
pub fn encode(
    allocator: Allocator,
    diffs: anytype,
    version: ZDeltaVersion,
) ZDeltaError![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    writeHeader(writer, version) catch return error.OutOfMemory;
    switch (version) {
        .a => writer.writeByte(sep_a) catch return error.OutOfMemory,
        .b => writer.writeByte(sep_b) catch return error.OutOfMemory,
    }
    for (diffs.items) |edit| {
        switch (edit.operation) {
            .insert => writeInsert(writer, edit.text, version) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                error.InvalidZDeltaText => return error.InvalidZDeltaText,
            },
            .delete => writeCount(writer, edit.text.len, version, .delete) catch return error.OutOfMemory,
            .equal => writeCount(writer, edit.text.len, version, .equal) catch return error.OutOfMemory,
        }
    }
    return out.toOwnedSlice();
}

pub fn decode(
    allocator: Allocator,
    zdelta: []const u8,
) ZDeltaError!ZDelta {
    const parsed = try parseHeader(zdelta);
    return switch (parsed.version) {
        .a => try decodeA(allocator, zdelta[parsed.body_start..]),
        .b => try decodeB(allocator, zdelta[parsed.body_start..]),
    };
}

/// Populate a Diff from a zdelta string and the before text.
pub fn toDiffList(
    comptime EditType: type,
    comptime DiffListType: type,
    allocator: Allocator,
    before: []const u8,
    zdelta: []const u8,
) ZDeltaError!DiffListType {
    const parsed = try parseHeader(zdelta);
    return switch (parsed.version) {
        .a => try diffListFromA(EditType, DiffListType, allocator, before, zdelta[parsed.body_start..]),
        .b => try diffListFromB(EditType, DiffListType, allocator, before, zdelta[parsed.body_start..]),
    };
}

/// Magic lead string identifying a zDelta patch.
const zdelta_magic = "zΔ⚡";

// Paranoia earned from mighty blows:
comptime {
    if (!std.mem.eql(u8, zdelta_magic, "\x7a\xce\x94\xe2\x9a\xa1")) {
        @compileError("Something has tampered with the zdelta header string...");
    }
}

// These are pollutants which we do our best to avoid:
const UTF8_BOM = "\xef\xbb\xbf";
const U_FEOE = "\xef\xb8\x8e";
const U_FEOF = "\xef\xb8\x8f";
// The variation selectors are why we check that zdelta_magic doesn't have them...

const sep_b: u8 = '|';
const sep_a: u8 = 0xff;
const delete_a: u8 = 0xfc;
const insert_a: u8 = 0xfd;
const equal_a: u8 = 0xfe;

const ParsedHeader = struct {
    version: ZDeltaVersion,
    body_start: usize,
};

fn writeHeader(writer: anytype, version: ZDeltaVersion) !void {
    try writer.writeAll(zdelta_magic);
    try writer.writeByte(@tagName(version)[0]);
}

/// loc is a location in text1, compute and return the equivalent location in
/// text2.
/// e.g. "The cat" vs "The big cat", 1->1, 5->8
/// @param diffs List of Diff objects.
/// @param loc Location within text1.
/// @return Location within text2.
fn writeInsert(writer: anytype, text: []const u8, version: ZDeltaVersion) !void {
    switch (version) {
        .a => {
            if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidZDeltaText;
            try writer.writeByte(insert_a);
            try writer.writeAll(text);
            try writer.writeByte(sep_a);
        },
        .b => {
            if (!std.unicode.wtf8ValidateSlice(text)) return error.InvalidZDeltaText;
            try writer.writeByte('+');
            _ = try writeBText(writer, text);
            try writer.writeByte(sep_b);
        },
    }
}

fn writeCount(
    writer: anytype,
    len: usize,
    version: ZDeltaVersion,
    operation: anytype,
) !void {
    switch (version) {
        .a => try writer.writeByte(switch (operation) {
            .delete => delete_a,
            .equal => equal_a,
            else => unreachable,
        }),
        .b => try writer.writeByte(switch (operation) {
            .delete => '-',
            .equal => '=',
            else => unreachable,
        }),
    }
    try writer.print("{x}", .{len});
    switch (version) {
        .a => try writer.writeByte(sep_a),
        .b => try writer.writeByte(sep_b),
    }
}

fn writeBText(writer: anytype, text: []const u8) !usize {
    var written: usize = 0;
    for (text) |byte| {
        const must_escape = switch (byte) {
            0x00...0x1f, '+', '-', '=', '|', '%' => true,
            else => false,
        };
        if (!must_escape) {
            try writer.writeByte(byte);
            written += 1;
            continue;
        }
        try writer.writeByte('%');
        const hex = std.fmt.bytesToHex(&[_]u8{byte}, .upper);
        try writer.writeAll(&hex);
        written += 3;
    }
    return written;
}

fn parseHeader(zdelta: []const u8) ZDeltaError!ParsedHeader {
    var cursor: usize = 0;
    if (std.mem.startsWith(u8, zdelta, UTF8_BOM)) cursor += UTF8_BOM.len;
    if (!std.mem.startsWith(u8, zdelta[cursor..], zdelta_magic)) return error.BadZDeltaHeader;
    cursor += zdelta_magic.len;
    if (std.mem.startsWith(u8, zdelta[cursor..], U_FEOE)) {
        cursor += U_FEOE.len;
    } else if (std.mem.startsWith(u8, zdelta[cursor..], U_FEOF)) {
        cursor += U_FEOF.len;
    }
    if (cursor >= zdelta.len) return error.BadZDeltaHeader;
    const version = switch (zdelta[cursor]) {
        'a' => ZDeltaVersion.a,
        'b' => ZDeltaVersion.b,
        else => return error.UnknownZDeltaVersion,
    };
    cursor += 1;
    if (cursor >= zdelta.len) return error.BadZDeltaHeader;
    const sep = switch (version) {
        .a => sep_a,
        .b => sep_b,
    };
    if (zdelta[cursor] != sep) return error.BadZDeltaHeader;
    return .{ .version = version, .body_start = cursor + 1 };
}

fn diffListFromA(
    comptime EditType: type,
    comptime DiffListType: type,
    allocator: Allocator,
    before: []const u8,
    body: []const u8,
) ZDeltaError!DiffListType {
    var edits: DiffListType = .empty;
    errdefer deinitList(allocator, &edits);
    if (body.len == 0) {
        if (before.len != 0) return error.ZDeltaLengthMismatch;
        return edits;
    }
    if (body[body.len - 1] != sep_a) return error.BadZDeltaOperation;

    var pointer: usize = 0;
    var field_start: usize = 0;
    while (field_start < body.len) {
        const field_end = std.mem.indexOfScalarPos(u8, body, field_start, sep_a) orelse unreachable;
        const field = body[field_start..field_end];
        if (field.len == 0) return error.BadZDeltaOperation;
        try appendField(EditType, DiffListType, allocator, &edits, before, &pointer, field, .a);
        field_start = field_end + 1;
    }
    if (pointer != before.len) return error.ZDeltaLengthMismatch;
    return edits;
}

fn diffListFromB(
    comptime EditType: type,
    comptime DiffListType: type,
    allocator: Allocator,
    before: []const u8,
    body: []const u8,
) ZDeltaError!DiffListType {
    var compact_storage: ?[]u8 = null;
    defer if (compact_storage) |compact| allocator.free(compact);
    const compact = compact: {
        const first_whitespace = std.mem.indexOfAny(u8, body, "\r\n") orelse break :compact body;
        var compact = ArrayList(u8).init(allocator);
        defer compact.deinit();
        try compact.ensureUnusedCapacity(body.len);
        try compact.appendSlice(body[0..first_whitespace]);
        var cursor = first_whitespace + 1;
        while (std.mem.indexOfAnyPos(u8, body, cursor, "\r\n")) |next_whitespace| {
            try compact.appendSlice(body[cursor..next_whitespace]);
            cursor = next_whitespace + 1;
        }
        try compact.appendSlice(body[cursor..]);
        compact_storage = try compact.toOwnedSlice();
        break :compact compact_storage.?;
    };

    var edits: DiffListType = .empty;
    errdefer deinitList(allocator, &edits);
    if (compact.len == 0) {
        if (before.len != 0) return error.ZDeltaLengthMismatch;
        return edits;
    }
    if (compact[compact.len - 1] != sep_b) return error.BadZDeltaOperation;

    var pointer: usize = 0;
    var field_start: usize = 0;
    while (field_start < compact.len) {
        const field_end = std.mem.indexOfScalarPos(u8, compact, field_start, sep_b) orelse unreachable;
        const field = compact[field_start..field_end];
        if (field.len == 0) return error.BadZDeltaOperation;
        try appendField(EditType, DiffListType, allocator, &edits, before, &pointer, field, .b);
        field_start = field_end + 1;
    }
    if (pointer != before.len) return error.ZDeltaLengthMismatch;
    return edits;
}

fn decodeA(
    allocator: Allocator,
    body: []const u8,
) ZDeltaError!ZDelta {
    var insert_text = ArrayList(u8).init(allocator);
    defer insert_text.deinit();
    var ops = ArrayList(DeltaOp).init(allocator);
    defer ops.deinit();

    if (body.len != 0) {
        if (body[body.len - 1] != sep_a) return error.BadZDeltaOperation;
        var field_start: usize = 0;
        while (field_start < body.len) {
            const field_end = std.mem.indexOfScalarPos(u8, body, field_start, sep_a) orelse unreachable;
            const field = body[field_start..field_end];
            if (field.len == 0) return error.BadZDeltaOperation;
            try decodeField(allocator, &insert_text, &ops, field, .a);
            field_start = field_end + 1;
        }
    }

    const owned_insert_text = try insert_text.toOwnedSlice();
    errdefer allocator.free(owned_insert_text);
    const owned_ops = try ops.toOwnedSlice();
    return .{
        .version = .a,
        .insert_text = owned_insert_text,
        .ops = owned_ops,
    };
}

fn decodeB(
    allocator: Allocator,
    body: []const u8,
) ZDeltaError!ZDelta {
    var compact_storage: ?[]u8 = null;
    defer if (compact_storage) |compact| allocator.free(compact);
    const compact = compact: {
        const first_whitespace = std.mem.indexOfAny(u8, body, "\r\n") orelse break :compact body;
        var compact = ArrayList(u8).init(allocator);
        defer compact.deinit();
        try compact.ensureUnusedCapacity(body.len);
        try compact.appendSlice(body[0..first_whitespace]);
        var cursor = first_whitespace + 1;
        while (std.mem.indexOfAnyPos(u8, body, cursor, "\r\n")) |next_whitespace| {
            try compact.appendSlice(body[cursor..next_whitespace]);
            cursor = next_whitespace + 1;
        }
        try compact.appendSlice(body[cursor..]);
        compact_storage = try compact.toOwnedSlice();
        break :compact compact_storage.?;
    };

    var insert_text = ArrayList(u8).init(allocator);
    defer insert_text.deinit();
    var ops = ArrayList(DeltaOp).init(allocator);
    defer ops.deinit();

    if (compact.len != 0) {
        if (compact[compact.len - 1] != sep_b) return error.BadZDeltaOperation;
        var field_start: usize = 0;
        while (field_start < compact.len) {
            const field_end = std.mem.indexOfScalarPos(u8, compact, field_start, sep_b) orelse unreachable;
            const field = compact[field_start..field_end];
            if (field.len == 0) return error.BadZDeltaOperation;
            try decodeField(allocator, &insert_text, &ops, field, .b);
            field_start = field_end + 1;
        }
    }

    const owned_insert_text = try insert_text.toOwnedSlice();
    errdefer allocator.free(owned_insert_text);
    const owned_ops = try ops.toOwnedSlice();
    return .{
        .version = .b,
        .insert_text = owned_insert_text,
        .ops = owned_ops,
    };
}

fn appendField(
    comptime EditType: type,
    comptime DiffListType: type,
    allocator: Allocator,
    edits: *DiffListType,
    before: []const u8,
    pointer: *usize,
    field: []const u8,
    version: ZDeltaVersion,
) ZDeltaError!void {
    const action = field[0];
    const payload = field[1..];
    switch (version) {
        .a => switch (action) {
            insert_a => {
                if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidZDeltaText;
                try edits.append(allocator, .{
                    .operation = .insert,
                    .owned = true,
                    .text = try allocator.dupe(u8, payload),
                });
            },
            delete_a => try appendCountEdit(EditType, DiffListType, allocator, edits, before, pointer, payload, .delete),
            equal_a => try appendCountEdit(EditType, DiffListType, allocator, edits, before, pointer, payload, .equal),
            else => return error.BadZDeltaOperation,
        },
        .b => switch (action) {
            '+' => {
                const decoded = try decodePercent(allocator, payload);
                errdefer allocator.free(decoded);
                if (!std.unicode.wtf8ValidateSlice(decoded)) return error.InvalidZDeltaText;
                try edits.append(allocator, .{
                    .operation = .insert,
                    .owned = true,
                    .text = decoded,
                });
            },
            '-' => try appendCountEdit(EditType, DiffListType, allocator, edits, before, pointer, payload, .delete),
            '=' => try appendCountEdit(EditType, DiffListType, allocator, edits, before, pointer, payload, .equal),
            else => return error.BadZDeltaOperation,
        },
    }
}

fn decodeField(
    allocator: Allocator,
    insert_text: *ArrayList(u8),
    ops: *ArrayList(DeltaOp),
    field: []const u8,
    version: ZDeltaVersion,
) ZDeltaError!void {
    const action = field[0];
    const payload = field[1..];
    switch (version) {
        .a => switch (action) {
            insert_a => {
                if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidZDeltaText;
                try appendInsertSpan(allocator, insert_text, ops, payload);
            },
            delete_a => try ops.append(.{ .delete = try parseCountU32(payload) }),
            equal_a => try ops.append(.{ .equal = try parseCountU32(payload) }),
            else => return error.BadZDeltaOperation,
        },
        .b => switch (action) {
            '+' => {
                const decoded = try decodePercent(allocator, payload);
                defer allocator.free(decoded);
                if (!std.unicode.wtf8ValidateSlice(decoded)) return error.InvalidZDeltaText;
                try appendInsertSpan(allocator, insert_text, ops, decoded);
            },
            '-' => try ops.append(.{ .delete = try parseCountU32(payload) }),
            '=' => try ops.append(.{ .equal = try parseCountU32(payload) }),
            else => return error.BadZDeltaOperation,
        },
    }
}

fn appendCountEdit(
    comptime EditType: type,
    comptime DiffListType: type,
    allocator: Allocator,
    edits: *DiffListType,
    before: []const u8,
    pointer: *usize,
    payload: []const u8,
    operation: anytype,
) ZDeltaError!void {
    const len = try parseCount(payload);
    if (pointer.* + len < pointer.* or pointer.* + len > before.len) return error.ZDeltaLengthMismatch;
    try edits.append(allocator, EditType{
        .operation = operation,
        .owned = false,
        .text = before[pointer.* .. pointer.* + len],
    });
    pointer.* += len;
}

fn parseCount(payload: []const u8) ZDeltaError!usize {
    if (payload.len == 0) return error.BadZDeltaNumber;
    return std.fmt.parseInt(usize, payload, 16) catch error.BadZDeltaNumber;
}

fn parseCountU32(payload: []const u8) ZDeltaError!u32 {
    return checkedU32(try parseCount(payload));
}

fn appendInsertSpan(
    allocator: Allocator,
    insert_text: *ArrayList(u8),
    ops: *ArrayList(DeltaOp),
    text: []const u8,
) ZDeltaError!void {
    const span = try makeDeltaSpan(insert_text.items.len, text.len);
    try insert_text.appendSlice(text);
    try ops.append(.{ .insert = span });
    _ = allocator;
}

fn checkedU32(value: usize) ZDeltaError!u32 {
    return std.math.cast(u32, value) orelse error.BadZDeltaNumber;
}

fn makeDeltaSpan(offset: usize, len: usize) ZDeltaError!DeltaSpan {
    const end = std.math.add(usize, offset, len) catch return error.BadZDeltaNumber;
    if (end < offset) return error.BadZDeltaNumber;
    if (end > std.math.maxInt(u32)) return error.BadZDeltaNumber;
    return .{
        .offset = try checkedU32(offset),
        .len = try checkedU32(len),
    };
}

fn decodePercent(allocator: Allocator, text: []const u8) ZDeltaError![]u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null) return allocator.dupe(u8, text);
    var out = ArrayList(u8).init(allocator);
    defer out.deinit();
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (text[cursor] != '%') {
            try out.append(text[cursor]);
            cursor += 1;
            continue;
        }
        if (cursor + 2 >= text.len) return error.BadZDeltaEscape;
        const byte = std.fmt.parseInt(u8, text[cursor + 1 .. cursor + 3], 16) catch return error.BadZDeltaEscape;
        try out.append(byte);
        cursor += 3;
    }
    return out.toOwnedSlice();
}

fn deinitList(allocator: Allocator, diffs: anytype) void {
    defer diffs.deinit(allocator);
    for (diffs.items) |*edit| edit.deinit(allocator);
}

fn expectEqualDiff(expected: []const TestEdit, actual: []const TestEdit) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| {
        try testing.expectEqual(e.operation, a.operation);
        try testing.expectEqualStrings(e.text, a.text);
    }
}

fn sliceToTestDiffList(allocator: Allocator, diff_slice: []const TestEdit) !TestDiffList {
    var diff_list: TestDiffList = .empty;
    errdefer deinitList(allocator, &diff_list);
    try diff_list.ensureTotalCapacity(allocator, diff_slice.len);
    for (diff_slice) |edit| {
        diff_list.appendAssumeCapacity(try TestEdit.asOwn(
            allocator,
            edit.operation,
            edit.text,
        ));
    }
    return diff_list;
}

fn testEncodeCase(
    allocator: Allocator,
    diff_slice: []const TestEdit,
    version: ZDeltaVersion,
    expected: []const u8,
) !void {
    var diffs = try sliceToTestDiffList(allocator, diff_slice);
    defer deinitList(allocator, &diffs);
    const actual = try encode(allocator, diffs, version);
    defer allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

fn testRoundTripCase(
    allocator: Allocator,
    before: []const u8,
    diff_slice: []const TestEdit,
    version: ZDeltaVersion,
) !void {
    var diffs = try sliceToTestDiffList(allocator, diff_slice);
    defer deinitList(allocator, &diffs);
    const delta = try encode(allocator, diffs, version);
    defer allocator.free(delta);
    var decoded = try toDiffList(TestEdit, TestDiffList, allocator, before, delta);
    defer deinitList(allocator, &decoded);
    try expectEqualDiff(diff_slice, decoded.items);
}

fn testBadToDiffListCase(
    allocator: Allocator,
    before: []const u8,
    delta: []const u8,
    expected: ZDeltaError,
) anyerror!void {
    try testing.expectError(expected, toDiffList(TestEdit, TestDiffList, allocator, before, delta));
}

fn testHydrationEquivalence(
    allocator: Allocator,
    before: []const u8,
    delta_a: []const u8,
    delta_b: []const u8,
    expected: []const TestEdit,
) !void {
    var diff_a = try toDiffList(TestEdit, TestDiffList, allocator, before, delta_a);
    defer deinitList(allocator, &diff_a);
    try expectEqualDiff(expected, diff_a.items);

    var diff_b = try toDiffList(TestEdit, TestDiffList, allocator, before, delta_b);
    defer deinitList(allocator, &diff_b);
    try expectEqualDiff(expected, diff_b.items);
    try expectEqualDiff(diff_a.items, diff_b.items);
}

fn expectEqualReified(
    expected_version: ZDeltaVersion,
    expected_insert_text: []const u8,
    expected_ops: []const DeltaOp,
    actual: ZDelta,
) !void {
    try testing.expectEqual(expected_version, actual.version);
    try testing.expectEqualStrings(expected_insert_text, actual.insert_text);
    try testing.expectEqualDeep(expected_ops, actual.ops);
}

fn testDecodeCase(
    allocator: Allocator,
    zdelta: []const u8,
    expected_version: ZDeltaVersion,
    expected_insert_text: []const u8,
    expected_ops: []const DeltaOp,
) !void {
    var actual = try decode(allocator, zdelta);
    defer actual.deinit(allocator);
    try expectEqualReified(expected_version, expected_insert_text, expected_ops, actual);
}

fn testBadDecodeReifiedCase(
    allocator: Allocator,
    zdelta: []const u8,
    expected: ZDeltaError,
) anyerror!void {
    try testing.expectError(expected, decode(allocator, zdelta));
}

test "ZDelta encode" {
    const allocator = testing.allocator;
    try testing.checkAllAllocationFailures(allocator, testEncodeCase, .{
        &.{
            TestEdit.asBorrow(.equal, "abc"),
            TestEdit.asBorrow(.delete, "de"),
            TestEdit.asBorrow(.insert, "ing"),
        },
        ZDeltaVersion.b,
        "zΔ⚡b|=3|-2|+ing|",
    });
    try testing.checkAllAllocationFailures(allocator, testEncodeCase, .{
        &.{
            TestEdit.asBorrow(.equal, "abc"),
            TestEdit.asBorrow(.delete, "de"),
            TestEdit.asBorrow(.insert, "ing"),
        },
        ZDeltaVersion.a,
        "zΔ⚡a" ++ "\xff\xfe3\xff\xfc2\xff\xfding\xff",
    });
    try testing.checkAllAllocationFailures(allocator, testEncodeCase, .{
        &.{TestEdit.asBorrow(.insert, "+-=%|\x01α")},
        ZDeltaVersion.b,
        "zΔ⚡b|+%2B%2D%3D%25%7C%01α|",
    });
    try testing.checkAllAllocationFailures(allocator, testEncodeCase, .{
        &.{TestEdit.asBorrow(.insert, "Καλημέρα")},
        ZDeltaVersion.b,
        "zΔ⚡b|+Καλημέρα|",
    });
}

test "ZDelta encode rejects invalid text" {
    const allocator = testing.allocator;
    var diff_a = try sliceToTestDiffList(allocator, &.{TestEdit.asBorrow(.insert, "\xed\xa0\x80")});
    defer deinitList(allocator, &diff_a);
    try testing.expectError(error.InvalidZDeltaText, encode(allocator, diff_a, .a));

    var diff_b = try sliceToTestDiffList(allocator, &.{TestEdit.asBorrow(.insert, "\xc0")});
    defer deinitList(allocator, &diff_b);
    try testing.expectError(error.InvalidZDeltaText, encode(allocator, diff_b, .b));
}

test "ZDelta round trip" {
    const allocator = testing.allocator;
    const before = "αβZ";
    const expected = &.{
        TestEdit.asBorrow(.equal, "α"),
        TestEdit.asBorrow(.delete, "β"),
        TestEdit.asBorrow(.insert, "+λ\n"),
        TestEdit.asBorrow(.equal, "Z"),
    };
    try testing.checkAllAllocationFailures(allocator, testRoundTripCase, .{ before, expected, ZDeltaVersion.a });
    try testing.checkAllAllocationFailures(allocator, testRoundTripCase, .{ before, expected, ZDeltaVersion.b });
}

test "ZDelta toDiffList strict failures" {
    const allocator = testing.allocator;
    try testBadToDiffListCase(allocator, "", "+abc|", error.BadZDeltaHeader);
    try testBadToDiffListCase(allocator, "", "zΔ⚡q|", error.UnknownZDeltaVersion);
    try testBadToDiffListCase(allocator, "", "zΔ⚡b|+%G0|", error.BadZDeltaEscape);
    try testBadToDiffListCase(allocator, "", "zΔ⚡b|?1|", error.BadZDeltaOperation);
    try testBadToDiffListCase(allocator, "abc", "zΔ⚡a\xff", error.ZDeltaLengthMismatch);
    try testBadToDiffListCase(allocator, "abc", "zΔ⚡b|=gg|", error.BadZDeltaNumber);
    try testBadToDiffListCase(allocator, "abc", "zΔ⚡b|=4|", error.ZDeltaLengthMismatch);
    try testBadToDiffListCase(allocator, "abc", "zΔ⚡b|", error.ZDeltaLengthMismatch);
    try testBadToDiffListCase(allocator, "", "zΔ⚡\xef\xb8\x8eb|+%C0|", error.InvalidZDeltaText);
}

test "ZDelta toDiffList header tolerance and whitespace" {
    const allocator = testing.allocator;
    var bom_vs = try toDiffList(TestEdit, TestDiffList, allocator, "", "\xef\xbb\xbf" ++ "zΔ⚡" ++ "\xef\xb8\x8f" ++ "b|+abc|");
    defer deinitList(allocator, &bom_vs);
    try expectEqualDiff(&.{TestEdit.asBorrow(.insert, "abc")}, bom_vs.items);

    var spaced = try toDiffList(TestEdit, TestDiffList, allocator, "a", "zΔ⚡b|\n=1|\r\n+α|\n");
    defer deinitList(allocator, &spaced);
    try expectEqualDiff(
        &.{
            TestEdit.asBorrow(.equal, "a"),
            TestEdit.asBorrow(.insert, "α"),
        },
        spaced.items,
    );
}

test "ZDelta a and b hydrate identically" {
    const allocator = testing.allocator;
    const before = "αβZ";
    try testing.checkAllAllocationFailures(allocator, testHydrationEquivalence, .{
        before,
        "zΔ⚡a" ++ "\xff\xfe2\xff\xfc2\xff\xfd+\xce\xbb\x0a\xff\xfe1\xff",
        "zΔ⚡b|=2|-2|+%2Bλ%0A|=1|",
        &.{
            TestEdit.asBorrow(.equal, "α"),
            TestEdit.asBorrow(.delete, "β"),
            TestEdit.asBorrow(.insert, "+λ\n"),
            TestEdit.asBorrow(.equal, "Z"),
        },
    });
}

test "ZDelta decode a" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDecodeCase,
        .{
            "zΔ⚡a" ++ "\xff\xfe3\xff\xfc2\xff\xfding\xff",
            ZDeltaVersion.a,
            "ing",
            &.{
                DeltaOp{ .equal = 3 },
                DeltaOp{ .delete = 2 },
                DeltaOp{ .insert = .{ .offset = 0, .len = 3 } },
            },
        },
    );
}

test "ZDelta decode b" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDecodeCase,
        .{
            "zΔ⚡b|+ab|=2|+%2Bλ%0A|",
            ZDeltaVersion.b,
            "ab+λ\n",
            &.{
                DeltaOp{ .insert = .{ .offset = 0, .len = 2 } },
                DeltaOp{ .equal = 2 },
                DeltaOp{ .insert = .{ .offset = 2, .len = 4 } },
            },
        },
    );
}

test "ZDelta decode header tolerance and whitespace" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        testDecodeCase,
        .{
            "\xef\xbb\xbf" ++ "zΔ⚡" ++ "\xef\xb8\x8f" ++ "b|\n=1|\r\n+α|\n",
            ZDeltaVersion.b,
            "α",
            &.{
                DeltaOp{ .equal = 1 },
                DeltaOp{ .insert = .{ .offset = 0, .len = 2 } },
            },
        },
    );
}

test "ZDelta decode strict failures" {
    const allocator = testing.allocator;
    try testBadDecodeReifiedCase(allocator, "+abc|", error.BadZDeltaHeader);
    try testBadDecodeReifiedCase(allocator, "zΔ⚡q|", error.UnknownZDeltaVersion);
    try testBadDecodeReifiedCase(allocator, "zΔ⚡b|+%G0|", error.BadZDeltaEscape);
    try testBadDecodeReifiedCase(allocator, "zΔ⚡b|?1|", error.BadZDeltaOperation);
    try testBadDecodeReifiedCase(allocator, "zΔ⚡b|=gg|", error.BadZDeltaNumber);
    try testBadDecodeReifiedCase(allocator, "zΔ⚡\xef\xb8\x8eb|+%C0|", error.InvalidZDeltaText);
}

test "ZDelta decode count overflow maps to BadZDeltaNumber" {
    try testBadDecodeReifiedCase(testing.allocator, "zΔ⚡b|=100000000|", error.BadZDeltaNumber);
}

test "ZDelta decode insert overflow maps to BadZDeltaNumber" {
    try testing.expectError(error.BadZDeltaNumber, makeDeltaSpan(std.math.maxInt(u32), 1));
    try testing.expectError(error.BadZDeltaNumber, makeDeltaSpan(0, @as(usize, std.math.maxInt(u32)) + 1));
}

const TestEdit = struct {
    operation: Operation,
    owned: bool,
    text: []const u8,

    fn deinit(edit: *TestEdit, allocator: Allocator) void {
        if (edit.owned) allocator.free(edit.text);
    }

    fn asOwn(allocator: Allocator, operation: Operation, text: []const u8) Allocator.Error!TestEdit {
        return .{
            .operation = operation,
            .owned = true,
            .text = try allocator.dupe(u8, text),
        };
    }

    fn asBorrow(operation: Operation, text: []const u8) TestEdit {
        return .{
            .operation = operation,
            .owned = false,
            .text = text,
        };
    }
};

const TestDiffList = std.ArrayListUnmanaged(TestEdit);

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const testing = std.testing;
const dmp = @import("dmp.zig");
const Edit = dmp.Edit;
