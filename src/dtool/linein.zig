//! Input line reader for delta-tool.
//!
//! `LineIn` is the only subsystem that consumes stdin bytes. It does not own
//! the tool's interactive control flow; instead, `run` selects a mode and the
//! line reader parses bytes into typed events. Terminal replies are transport noise,
//! not parser state, so they remain recognizable regardless of the current
//! prompt/help mode.

pub const StdinSource = union(enum) {
    file: std.fs.File,
    bytes: []const u8,
};

pub const Source = union(enum) {
    live: StdinSource,
    replay: []const u8,
};

pub const Mode = enum {
    prompt_delta,
    prompt_edit,
    help_dismiss,
};

pub const CursorAnchor = struct {
    row: u16,
    col: u16,
};

pub const TerminalSize = struct {
    rows: u16,
    cols: u16,
};

pub const PromptCommand = struct {
    intent: zdelta_session.SessionIntent,
    canonical: u8,
};

pub const Event = union(enum) {
    prompt_command: PromptCommand,
    cursor_anchor: CursorAnchor,
    terminal_size: TerminalSize,
    help_done,
    invalid_input,
    interrupt,
    eof,
};

pub const LineIn = struct {
    source: Source,
    mode: Mode = .prompt_delta,
    cursor: usize = 0,
    pending: [64]u8 = undefined,
    pending_len: usize = 0,

    pub fn init(source: Source) LineIn {
        return .{
            .source = source,
        };
    }

    pub fn setMode(in: *LineIn, mode: Mode) void {
        in.mode = mode;
    }

    pub fn requestCursorAnchor(in: *LineIn, writer: *std.Io.Writer) !void {
        switch (in.source) {
            .live => {},
            .replay => return error.CursorAnchorUnavailable,
        }
        try writer.writeAll(CURSOR_POSITION_REQUEST);
        try writer.flush();
    }

    pub fn requestTerminalSize(in: *LineIn, writer: *std.Io.Writer) !void {
        switch (in.source) {
            .live => {},
            .replay => return error.TerminalSizeUnavailable,
        }
        try writer.writeAll(TERMINAL_SIZE_REQUEST);
        try writer.flush();
    }

    pub fn readEvent(in: *LineIn, writer: ?*std.Io.Writer) !Event {
        _ = writer;
        return switch (in.source) {
            .live => try in.readLiveEvent(),
            .replay => try in.readReplayEvent(),
        };
    }

    pub fn waitForHelpDismiss(in: *LineIn) !bool {
        in.setMode(.help_dismiss);
        while (true) {
            switch (try in.readEvent(null)) {
                .help_done => return true,
                .interrupt => return error.Interrupted,
                .eof => return false,
                .prompt_command, .cursor_anchor, .terminal_size, .invalid_input => {},
            }
        }
    }

    fn readLiveEvent(in: *LineIn) !Event {
        const byte = (try in.readByte()) orelse return .eof;
        if (byte == 3) return .interrupt;
        if (byte == ESC_BYTE) {
            if (try in.readTerminalReply()) |event| return event;
        }
        return in.parseModeByte(byte);
    }

    fn readReplayEvent(in: *LineIn) !Event {
        const command = try in.readReplayCommand();
        return switch (in.mode) {
            .prompt_delta => .{
                .prompt_command = parseReplayPrompt(.delta, command) orelse
                    return error.InvalidReplayDeltaCommand,
            },
            .prompt_edit => .{
                .prompt_command = parseReplayPrompt(.edit, command) orelse
                    return error.InvalidReplayEditCommand,
            },
            .help_dismiss => .help_done,
        };
    }

    fn parseModeByte(in: *LineIn, byte: u8) Event {
        return switch (in.mode) {
            .help_dismiss => .help_done,
            .prompt_delta => if (parsePromptByte(.delta, byte)) |command|
                .{ .prompt_command = command }
            else
                .invalid_input,
            .prompt_edit => if (parsePromptByte(.edit, byte)) |command|
                .{ .prompt_command = command }
            else
                .invalid_input,
        };
    }

    fn readByte(in: *LineIn) !?u8 {
        if (in.pending_len != 0) {
            const byte = in.pending[0];
            std.mem.copyForwards(u8, in.pending[0 .. in.pending_len - 1], in.pending[1..in.pending_len]);
            in.pending_len -= 1;
            return byte;
        }

        const stdin = switch (in.source) {
            .live => |stdin| stdin,
            .replay => unreachable,
        };

        switch (stdin) {
            .bytes => |bytes| {
                if (in.cursor >= bytes.len) return null;
                const byte = bytes[in.cursor];
                in.cursor += 1;
                return byte;
            },
            .file => |file| {
                var byte_buf: [1]u8 = undefined;
                const read_len = try file.read(byte_buf[0..]);
                if (read_len == 0) return null;
                return byte_buf[0];
            },
        }
    }

    fn pushUnread(in: *LineIn, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (in.pending_len + bytes.len > in.pending.len) {
            return error.PendingInputOverflow;
        }

        std.mem.copyBackwards(
            u8,
            in.pending[bytes.len .. bytes.len + in.pending_len],
            in.pending[0..in.pending_len],
        );
        std.mem.copyForwards(u8, in.pending[0..bytes.len], bytes);
        in.pending_len += bytes.len;
    }

    fn readTerminalReply(in: *LineIn) !?Event {
        var buf: [32]u8 = undefined;
        var len: usize = 0;
        buf[len] = ESC_BYTE;
        len += 1;

        const second = (try in.readByte()) orelse return null;
        buf[len] = second;
        len += 1;
        if (second != '[') {
            try in.pushUnread(buf[1..len]);
            return null;
        }

        var found_final = false;
        while (len < buf.len) {
            const byte = (try in.readByte()) orelse {
                try in.pushUnread(buf[1..len]);
                return null;
            };
            buf[len] = byte;
            len += 1;
            if (byte >= 0x40 and byte <= 0x7e) {
                found_final = true;
                break;
            }
        }
        if (!found_final) {
            try in.pushUnread(buf[1..len]);
            return null;
        }

        return parseTerminalReply(buf[0..len]) orelse blk: {
            try in.pushUnread(buf[1..len]);
            break :blk null;
        };
    }

    fn readReplayCommand(in: *LineIn) !u8 {
        const script = switch (in.source) {
            .live => unreachable,
            .replay => |script| script,
        };
        if (in.cursor >= script.len) return error.ReplayScriptExhausted;
        const command = script[in.cursor];
        in.cursor += 1;
        return command;
    }
};

fn parsePromptByte(prompt_kind: zdelta_session.SessionPrompt, byte: u8) ?PromptCommand {
    return parseReplayPrompt(prompt_kind, byte);
}

fn parseReplayPrompt(
    prompt_kind: zdelta_session.SessionPrompt,
    command: u8,
) ?PromptCommand {
    return switch (prompt_kind) {
        .delta => switch (command) {
            'y' => .{ .intent = .apply, .canonical = 'y' },
            'n' => .{ .intent = .skip, .canonical = 'n' },
            's' => .{ .intent = .split, .canonical = 's' },
            'q' => .{ .intent = .quit, .canonical = 'q' },
            '?' => .{ .intent = .help, .canonical = '?' },
            else => null,
        },
        .edit => switch (command) {
            'y' => .{ .intent = .apply, .canonical = 'y' },
            'n' => .{ .intent = .skip, .canonical = 'n' },
            'a' => .{ .intent = .apply_rest, .canonical = 'a' },
            'd' => .{ .intent = .skip_rest, .canonical = 'd' },
            'q' => .{ .intent = .quit, .canonical = 'q' },
            '?' => .{ .intent = .help, .canonical = '?' },
            else => null,
        },
    };
}

fn parseTerminalReply(bytes: []const u8) ?Event {
    if (bytes.len < 3 or bytes[0] != ESC_BYTE or bytes[1] != '[') return null;
    return switch (bytes[bytes.len - 1]) {
        'R' => .{ .cursor_anchor = parseCursorAnchor(bytes) orelse return null },
        't' => .{ .terminal_size = parseTerminalSize(bytes) orelse return null },
        else => null,
    };
}

fn parseCursorAnchor(bytes: []const u8) ?CursorAnchor {
    if (bytes.len < 6 or bytes[bytes.len - 1] != 'R') return null;
    const body = bytes[2 .. bytes.len - 1];
    const sep = std.mem.indexOfScalar(u8, body, ';') orelse return null;
    const row = std.fmt.parseUnsigned(u16, body[0..sep], 10) catch return null;
    const col = std.fmt.parseUnsigned(u16, body[sep + 1 ..], 10) catch return null;
    return .{ .row = row, .col = col };
}

fn parseTerminalSize(bytes: []const u8) ?TerminalSize {
    if (bytes.len < 8 or bytes[bytes.len - 1] != 't') return null;
    const body = bytes[2 .. bytes.len - 1];
    var parts = std.mem.splitScalar(u8, body, ';');
    const kind = parts.next() orelse return null;
    if (!std.mem.eql(u8, kind, "8")) return null;
    const rows_text = parts.next() orelse return null;
    const cols_text = parts.next() orelse return null;
    if (parts.next() != null) return null;

    return .{
        .rows = std.fmt.parseUnsigned(u16, rows_text, 10) catch return null,
        .cols = std.fmt.parseUnsigned(u16, cols_text, 10) catch return null,
    };
}

const ESC_BYTE: u8 = 0x1b;
const ESC = "\x1b";
const CSI = ESC ++ "[";
const CURSOR_POSITION_REQUEST = CSI ++ "6n";
const TERMINAL_SIZE_REQUEST = CSI ++ "18t";

test "delta prompt parser accepts lowercase canonical commands only" {
    var in = LineIn.init(.{ .live = .{ .bytes = "y?Y\n" } });
    in.setMode(.prompt_delta);

    try std.testing.expectEqualDeep(
        Event{ .prompt_command = .{ .intent = .apply, .canonical = 'y' } },
        try in.readEvent(null),
    );
    try std.testing.expectEqualDeep(
        Event{ .prompt_command = .{ .intent = .help, .canonical = '?' } },
        try in.readEvent(null),
    );
    try std.testing.expectEqualDeep(Event.invalid_input, try in.readEvent(null));
    try std.testing.expectEqualDeep(Event.invalid_input, try in.readEvent(null));
}

test "edit prompt parser accepts lowercase canonical commands only" {
    var in = LineIn.init(.{ .live = .{ .bytes = "a?A\n" } });
    in.setMode(.prompt_edit);

    try std.testing.expectEqualDeep(
        Event{ .prompt_command = .{ .intent = .apply_rest, .canonical = 'a' } },
        try in.readEvent(null),
    );
    try std.testing.expectEqualDeep(
        Event{ .prompt_command = .{ .intent = .help, .canonical = '?' } },
        try in.readEvent(null),
    );
    try std.testing.expectEqualDeep(Event.invalid_input, try in.readEvent(null));
    try std.testing.expectEqualDeep(Event.invalid_input, try in.readEvent(null));
}

test "ctrl c emits interrupt" {
    var in = LineIn.init(.{ .live = .{ .bytes = "\x03" } });
    in.setMode(.prompt_delta);

    try std.testing.expectEqualDeep(Event.interrupt, try in.readEvent(null));
}

test "cursor replies are recognized regardless of mode" {
    var in = LineIn.init(.{ .live = .{ .bytes = "\x1b[12;34R" } });
    in.setMode(.help_dismiss);

    try std.testing.expectEqualDeep(
        Event{ .cursor_anchor = .{ .row = 12, .col = 34 } },
        try in.readEvent(null),
    );
}

test "terminal size replies are recognized regardless of mode" {
    var in = LineIn.init(.{ .live = .{ .bytes = "\x1b[8;40;120t" } });
    in.setMode(.prompt_delta);

    try std.testing.expectEqualDeep(
        Event{ .terminal_size = .{ .rows = 40, .cols = 120 } },
        try in.readEvent(null),
    );
}

test "help dismiss mode turns any ordinary key into help done" {
    var in = LineIn.init(.{ .live = .{ .bytes = "q" } });
    in.setMode(.help_dismiss);

    try std.testing.expectEqualDeep(Event.help_done, try in.readEvent(null));
}

test "invalid replay command fails immediately" {
    var in = LineIn.init(.{ .replay = "help" });
    in.setMode(.prompt_delta);

    try std.testing.expectError(error.InvalidReplayDeltaCommand, in.readEvent(null));
}

test "replay exhaustion is reported" {
    var in = LineIn.init(.{ .replay = "" });
    in.setMode(.prompt_delta);

    try std.testing.expectError(error.ReplayScriptExhausted, in.readEvent(null));
}

const std = @import("std");
const zdelta_session = @import("../zdelta/session.zig");
