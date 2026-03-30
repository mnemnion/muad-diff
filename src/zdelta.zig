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
    ZDeltaTextLengthMismatch,
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

    pub fn beforeLength(delta: *const ZDelta) !u32 {
        var len: u32 = 0;
        for (delta.ops) |op| {
            switch (op) {
                .delete => |count| len = try addU32(len, count),
                .equal => |count| len = try addU32(len, count),
                .insert => {},
            }
        }
        return len;
    }

    pub fn midpoint(delta: *const ZDelta) !u32 {
        return (try delta.beforeLength()) / 2;
    }

    pub fn afterLength(delta: *const ZDelta) !u32 {
        var len: u32 = @intCast(delta.insert_text.len);
        for (delta.ops) |op| {
            switch (op) {
                .equal => |count| len = try addU32(len, count),
                .insert, .delete => {},
            }
        }
        return len;
    }

    pub fn padding(delta: *const ZDelta) !struct { u32, u32 } {
        const mid = try delta.midpoint();
        var t_idx: u32 = 0;
        var index: u32 = mid;
        var head_now: i64 = 0;
        var tail_now: i64 = 0;
        var head_max: i64 = 0;
        var tail_max: i64 = 0;

        for (delta.ops) |op| {
            switch (op) {
                .equal => |len| {
                    t_idx += len;
                },
                .delete => |len| {
                    if (t_idx < index) {
                        head_now -= len;
                    } else {
                        tail_now -= len;
                    }
                    remapManagerIndex(&index, t_idx, len, 0);
                },
                .insert => |span| {
                    if (t_idx < index) {
                        head_now += span.len;
                    } else {
                        tail_now += span.len;
                    }
                    remapManagerIndex(&index, t_idx, 0, span.len);
                    t_idx += span.len;
                },
            }
            head_max = @max(head_max, head_now);
            tail_max = @max(tail_max, tail_now);
        }

        return .{
            try checkedU32(@intCast(@max(@as(i64, 0), head_max))),
            try checkedU32(@intCast(@max(@as(i64, 0), tail_max))),
        };
    }

    pub fn textNumbers(delta: *const ZDelta) !struct { u32, u32, u32 } {
        const before_len = try delta.beforeLength();
        const pre_padding, const post_padding = try delta.padding();
        return .{
            before_len,
            pre_padding,
            post_padding,
        };
    }

    pub fn deinit(delta: *ZDelta, allocator: Allocator) void {
        allocator.free(delta.insert_text);
        allocator.free(delta.ops);
        delta.* = undefined;
    }
};

/// Manages text through zdelta application without reallocating.
const TextManager = struct {
    allocator: Allocator,
    buffer: []u8,
    start: u32,
    end: u32,
    index: u32,
    t_idx: u32,
    z_idx: u32,

    fn init(
        allocator: Allocator,
        before: []const u8,
        zdelta: *const ZDelta,
    ) !TextManager {
        const before_len, const head_room, const tail_room = try zdelta.textNumbers();
        if (before.len != before_len) return error.ZDeltaTextLengthMismatch;
        const midpoint = before_len / 2;
        const total_len = std.math.add(
            usize,
            std.math.add(usize, before.len, head_room) catch return error.BadZDeltaNumber,
            tail_room,
        ) catch return error.BadZDeltaNumber;
        var text = try allocator.alloc(u8, total_len);
        @memcpy(text[head_room..][0..before.len], before);
        return .{
            .allocator = allocator,
            .buffer = text,
            .start = head_room,
            .end = head_room + before_len,
            .index = midpoint,
            .t_idx = 0,
            .z_idx = 0,
        };
    }

    fn deinit(tm: *TextManager) void {
        tm.allocator.free(tm.buffer);
        tm.* = undefined;
    }

    fn view(tm: *const TextManager) []const u8 {
        return tm.buffer[tm.start..tm.end];
    }

    fn activeLen(tm: *const TextManager) u32 {
        return tm.end - tm.start;
    }

    fn totalSlack(tm: *const TextManager) u32 {
        return tm.start + @as(u32, @intCast(tm.buffer.len)) - tm.end;
    }

    fn rebase(tm: *TextManager, new_start: u32) void {
        if (new_start == tm.start) return;
        const active_len = tm.activeLen();
        @memmove(
            tm.buffer[new_start..][0..active_len],
            tm.buffer[tm.start..][0..active_len],
        );
        tm.start = new_start;
        tm.end = new_start + active_len;
    }

    fn ensureHeadRoom(tm: *TextManager, need: u32) void {
        if (need <= tm.start) return;
        dbgassert(need <= tm.totalSlack());
        tm.rebase(need);
    }

    fn ensureTailRoom(tm: *TextManager, need: u32) void {
        const tail_room: u32 = @intCast(tm.buffer.len - tm.end);
        if (need <= tail_room) return;
        dbgassert(need <= tm.totalSlack());
        tm.rebase(tm.totalSlack() - need);
    }

    fn insert(
        tm: *TextManager,
        at: u32,
        new_text: []const u8,
    ) void {
        dbgassert(new_text.len <= std.math.maxInt(u32));
        const new_len: u32 = @intCast(new_text.len);
        dbgassert(at <= tm.activeLen());

        if (at < tm.index) {
            tm.ensureHeadRoom(new_len);
            const new_start = tm.start - new_len;
            @memmove(
                tm.buffer[new_start..][0..at],
                tm.buffer[tm.start..][0..at],
            );
            tm.start = new_start;
        } else {
            tm.ensureTailRoom(new_len);
            const abs_start = tm.start + at;
            @memmove(
                tm.buffer[abs_start + new_len ..][0 .. tm.end - abs_start],
                tm.buffer[abs_start..][0 .. tm.end - abs_start],
            );
            tm.end += new_len;
        }

        remapManagerIndex(&tm.index, at, 0, new_len);
        @memcpy(tm.buffer[tm.start + at ..][0..new_len], new_text);
    }

    fn delete(
        tm: *TextManager,
        start: u32,
        len: u32,
    ) void {
        const abs_start = tm.start + start;
        const abs_end = abs_start + len;
        dbgassert(start <= tm.activeLen());
        dbgassert(len <= tm.activeLen() - start);

        if (start < tm.index) {
            @memmove(
                tm.buffer[tm.start + len ..][0..start],
                tm.buffer[tm.start..][0..start],
            );
            tm.start += len;
        } else {
            @memmove(
                tm.buffer[abs_start..][0 .. tm.end - abs_end],
                tm.buffer[abs_end..][0 .. tm.end - abs_end],
            );
            tm.end -= len;
        }

        remapManagerIndex(&tm.index, start, len, 0);
    }

    fn finish(tm: *TextManager) ![]u8 {
        const text_len = tm.end - tm.start;
        @memmove(tm.buffer[0..text_len], tm.buffer[tm.start..][0..text_len]);
        const text = try tm.allocator.realloc(tm.buffer, text_len);
        tm.buffer = &.{};
        return text;
    }

    fn applyNext(
        tm: *TextManager,
        zdelta: *const ZDelta,
    ) ?void {
        while (currentDeltaOp(tm, zdelta)) |op| {
            switch (op) {
                .equal => |len| {
                    tm.t_idx += len;
                    tm.z_idx += 1;
                },
                .delete => |len| {
                    tm.delete(tm.t_idx, len);
                    tm.z_idx += 1;
                    return {};
                },
                .insert => |span| {
                    tm.insert(tm.t_idx, deltaInsertText(zdelta, span));
                    tm.t_idx += span.len;
                    tm.z_idx += 1;
                    return {};
                },
            }
        }
        return null;
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
                try appendInsertSpan(insert_text, ops, payload);
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
                try appendInsertSpan(insert_text, ops, decoded);
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

fn parseCount(payload: []const u8) !usize {
    if (payload.len == 0) return error.BadZDeltaNumber;
    return std.fmt.parseInt(usize, payload, 16) catch error.BadZDeltaNumber;
}

fn parseCountU32(payload: []const u8) !u32 {
    return checkedU32(try parseCount(payload));
}

fn appendInsertSpan(
    insert_text: *ArrayList(u8),
    ops: *ArrayList(DeltaOp),
    text: []const u8,
) !void {
    const span = try makeDeltaSpan(insert_text.items.len, text.len);
    try insert_text.appendSlice(text);
    try ops.append(.{ .insert = span });
}

fn checkedU32(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.BadZDeltaNumber;
}

fn addU32(a: u32, b: u32) !u32 {
    return std.math.add(u32, a, b) catch error.BadZDeltaNumber;
}

fn makeDeltaSpan(offset: usize, len: usize) !DeltaSpan {
    const end = std.math.add(usize, offset, len) catch return error.BadZDeltaNumber;
    if (end < offset) return error.BadZDeltaNumber;
    if (end > std.math.maxInt(u32)) return error.BadZDeltaNumber;
    return .{
        .offset = try checkedU32(offset),
        .len = try checkedU32(len),
    };
}

fn remapManagerIndex(
    index: *u32,
    start: u32,
    len: u32,
    new_len: u32,
) void {
    const old = index.*;
    const end = start + len;
    if (old <= start) return;
    if (old < end) {
        index.* = start + new_len;
        return;
    }
    if (new_len >= len) {
        index.* = old + (new_len - len);
    } else {
        index.* = old - (len - new_len);
    }
}

fn currentDeltaOp(
    tm: *const TextManager,
    zdelta: *const ZDelta,
) ?DeltaOp {
    if (tm.z_idx >= zdelta.ops.len) return null;
    return zdelta.ops[tm.z_idx];
}

fn deltaInsertText(
    zdelta: *const ZDelta,
    span: DeltaSpan,
) []const u8 {
    const offset: usize = span.offset;
    const len: usize = span.len;
    return zdelta.insert_text[offset..][0..len];
}

fn decodePercent(allocator: Allocator, text: []const u8) ![]u8 {
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

fn testZDelta(
    allocator: Allocator,
    insert_text: []const u8,
    ops: []const DeltaOp,
) !ZDelta {
    return .{
        .version = .b,
        .insert_text = try allocator.dupe(u8, insert_text),
        .ops = try allocator.dupe(DeltaOp, ops),
    };
}

const TestManager = struct {
    zdelta: ZDelta,
    tm: TextManager,

    fn init(
        allocator: Allocator,
        before: []const u8,
        insert_text: []const u8,
        ops: []const DeltaOp,
    ) !TestManager {
        var zdelta = try testZDelta(allocator, insert_text, ops);
        errdefer zdelta.deinit(allocator);
        return .{
            .zdelta = zdelta,
            .tm = try TextManager.init(allocator, before, &zdelta),
        };
    }

    fn deinit(test_manager: *TestManager) void {
        const allocator = test_manager.tm.allocator;
        test_manager.tm.deinit();
        test_manager.zdelta.deinit(allocator);
    }
};

fn expectManagerText(
    expected: []const u8,
    tm: *const TextManager,
) !void {
    try testing.expectEqualStrings(expected, tm.view());
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

test "ZDelta derived text numbers" {
    const allocator = testing.allocator;
    var zdelta = try testZDelta(allocator, "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 2 },
        .{ .delete = 1 },
        .{ .insert = .{ .offset = 1, .len = 1 } },
        .{ .equal = 1 },
    });
    defer zdelta.deinit(allocator);

    try testing.expectEqual(@as(u32, 4), try zdelta.beforeLength());
    try testing.expectEqual(@as(u32, 5), try zdelta.afterLength());
    try testing.expectEqual(@as(u32, 2), try zdelta.midpoint());
    try testing.expectEqual(@as(usize, 2), zdelta.insert_text.len);
    const pre_padding, const post_padding = try zdelta.padding();
    try testing.expectEqual(@as(u32, 1), pre_padding);
    try testing.expectEqual(@as(u32, 0), post_padding);

    const before_len, const pre, const post = try zdelta.textNumbers();
    try testing.expectEqual(@as(u32, 4), before_len);
    try testing.expectEqual(@as(u32, 1), pre);
    try testing.expectEqual(@as(u32, 0), post);
}

test "ZDelta TextManager rejects wrong text length" {
    const allocator = testing.allocator;
    var zdelta = try testZDelta(allocator, "", &.{
        .{ .equal = 3 },
    });
    defer zdelta.deinit(allocator);

    try testing.expectError(
        error.ZDeltaTextLengthMismatch,
        TextManager.init(allocator, "ab", &zdelta),
    );
}

test "ZDelta TextManager init empty" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "", "", &.{});
    defer test_manager.deinit();

    try testing.expectEqual(@as(u32, 0), test_manager.tm.start);
    try testing.expectEqual(@as(u32, 0), test_manager.tm.end);
    try testing.expectEqual(@as(u32, 0), test_manager.tm.index);
    try testing.expectEqual(@as(usize, 0), test_manager.zdelta.insert_text.len);
    try testing.expectEqual(@as(u32, 0), test_manager.tm.t_idx);
    try testing.expectEqual(@as(u32, 0), test_manager.tm.z_idx);
    try expectManagerText("", &test_manager.tm);
}

test "ZDelta TextManager plans front and tail slack" {
    const allocator = testing.allocator;

    var front = try TestManager.init(allocator, "abc", "X", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 3 },
    });
    defer front.deinit();
    try testing.expectEqual(@as(u32, 1), front.tm.start);
    try testing.expectEqual(@as(u32, 4), front.tm.end);
    try testing.expectEqual(@as(usize, 1), front.zdelta.insert_text.len);

    var tail = try TestManager.init(allocator, "abc", "X", &.{
        .{ .equal = 3 },
        .{ .insert = .{ .offset = 0, .len = 1 } },
    });
    defer tail.deinit();
    try testing.expectEqual(@as(u32, 0), tail.tm.start);
    try testing.expectEqual(@as(u32, 3), tail.tm.end);
    try testing.expectEqual(@as(usize, 1), tail.zdelta.insert_text.len);
    try testing.expectEqual(@as(usize, 1), tail.tm.buffer.len - tail.tm.end);
}

test "ZDelta TextManager plans mixed pressure" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 2 },
        .{ .delete = 1 },
        .{ .insert = .{ .offset = 1, .len = 1 } },
        .{ .equal = 1 },
    });
    defer test_manager.deinit();

    try testing.expectEqual(@as(u32, 1), test_manager.tm.start);
    try testing.expectEqual(@as(usize, 0), test_manager.tm.buffer.len - test_manager.tm.end);
    try testing.expectEqual(@as(usize, 2), test_manager.zdelta.insert_text.len);
}

test "ZDelta TextManager replace same size" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "", &.{
        .{ .equal = 4 },
    });
    defer test_manager.deinit();

    test_manager.tm.delete(1, 2);
    test_manager.tm.insert(1, "XY");
    try expectManagerText("aXYd", &test_manager.tm);
    try testing.expectEqual(@as(usize, 0), test_manager.zdelta.insert_text.len);
}

test "ZDelta TextManager grow from head side" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 2 } },
        .{ .equal = 4 },
    });
    defer test_manager.deinit();

    test_manager.tm.insert(0, "XY");
    try expectManagerText("XYabcd", &test_manager.tm);
    try testing.expectEqual(@as(u32, 0), test_manager.tm.start);
    try testing.expectEqual(@as(usize, 2), test_manager.zdelta.insert_text.len);
}

test "ZDelta TextManager grow from tail side" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "XY", &.{
        .{ .equal = 4 },
        .{ .insert = .{ .offset = 0, .len = 2 } },
    });
    defer test_manager.deinit();

    test_manager.tm.insert(4, "XY");
    try expectManagerText("abcdXY", &test_manager.tm);
    try testing.expectEqual(@as(usize, 2), test_manager.zdelta.insert_text.len);
}

test "ZDelta TextManager shrink from head side" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "", &.{
        .{ .delete = 2 },
        .{ .equal = 2 },
    });
    defer test_manager.deinit();

    test_manager.tm.delete(0, 2);
    try expectManagerText("cd", &test_manager.tm);
    try testing.expectEqual(@as(u32, 2), test_manager.tm.start);
    try testing.expectEqual(@as(usize, 0), test_manager.zdelta.insert_text.len);
}

test "ZDelta TextManager shrink from tail side" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "", &.{
        .{ .equal = 2 },
        .{ .delete = 2 },
    });
    defer test_manager.deinit();

    test_manager.tm.delete(2, 2);
    try expectManagerText("ab", &test_manager.tm);
    try testing.expectEqual(@as(usize, 0), test_manager.zdelta.insert_text.len);
}

test "ZDelta TextManager finish trims slack" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 2 } },
        .{ .equal = 4 },
    });
    defer test_manager.zdelta.deinit(allocator);

    test_manager.tm.insert(0, "XY");
    const finished = try test_manager.tm.finish();
    defer allocator.free(finished);
    test_manager.tm.buffer = &.{};
    try testing.expectEqualStrings("XYabcd", finished);
}

test "ZDelta TextManager applyNext" {
    const allocator = testing.allocator;
    var test_manager = try TestManager.init(allocator, "abcd", "XY", &.{
        .{ .insert = .{ .offset = 0, .len = 1 } },
        .{ .equal = 2 },
        .{ .delete = 1 },
        .{ .insert = .{ .offset = 1, .len = 1 } },
        .{ .equal = 1 },
    });
    defer test_manager.deinit();

    try testing.expectEqual(@as(?void, {}), test_manager.tm.applyNext(&test_manager.zdelta));
    try testing.expectEqual(@as(u32, 1), test_manager.tm.t_idx);
    try testing.expectEqual(@as(u32, 1), test_manager.tm.z_idx);
    try expectManagerText("Xabcd", &test_manager.tm);

    try testing.expectEqual(@as(?void, {}), test_manager.tm.applyNext(&test_manager.zdelta));
    try testing.expectEqual(@as(u32, 3), test_manager.tm.t_idx);
    try testing.expectEqual(@as(u32, 3), test_manager.tm.z_idx);
    try expectManagerText("Xabd", &test_manager.tm);

    try testing.expectEqual(@as(?void, {}), test_manager.tm.applyNext(&test_manager.zdelta));
    try testing.expectEqual(@as(u32, 4), test_manager.tm.t_idx);
    try testing.expectEqual(@as(u32, 4), test_manager.tm.z_idx);
    try expectManagerText("XabYd", &test_manager.tm);

    try testing.expectEqual(@as(?void, null), test_manager.tm.applyNext(&test_manager.zdelta));
    try testing.expectEqual(@as(u32, 5), test_manager.tm.t_idx);
    try testing.expectEqual(@as(u32, 5), test_manager.tm.z_idx);
    try expectManagerText("XabYd", &test_manager.tm);
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
const common = @import("dmp/common.zig");
const dbgassert = common.dbgassert;
