//! Structured command log.
//!
//! When shell integration reports that a command finished (OSC 133;D),
//! the surface turns the command line, its output, and its metadata into
//! one JSON object per line (JSONL) and appends it to a file. The goal is
//! that everything done in the terminal stays available as plain data.
//!
//! This file only depends on `std` so it can be unit tested on its own.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Output larger than this is cut (on a UTF-8 boundary) and flagged.
pub const max_output_bytes = 64 * 1024;

pub const Record = struct {
    /// Unix time in milliseconds when the command finished.
    ts_ms: i64,
    host: []const u8,
    cwd: ?[]const u8,
    input: ?[]const u8,
    output: ?[]const u8,
    output_truncated: bool,
    exit_code: ?u8,
    duration_ms: u64,
};

/// Serialize a record as a single JSON line including the trailing
/// newline. Strings that are not valid UTF-8 are made lossy so the line
/// is always valid JSON. The caller owns the result.
pub fn formatLine(alloc: Allocator, record: Record) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var clean = record;
    clean.host = try sanitize(a, record.host);
    if (record.cwd) |v| clean.cwd = try sanitize(a, v);
    if (record.input) |v| clean.input = try sanitize(a, v);
    if (record.output) |v| clean.output = try sanitize(a, v);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    std.json.Stringify.value(clean, .{}, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeByte('\n') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Drop trailing whitespace (blanks and newlines) from `text`.
pub fn trimEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " \t\r\n");
}

/// Cut `text` to at most `max` bytes without splitting a UTF-8 sequence.
/// The boolean is true if anything was removed.
pub fn truncate(text: []const u8, max: usize) struct { []const u8, bool } {
    if (text.len <= max) return .{ text, false };
    var end = max;
    // Back up over continuation bytes so we never cut a code point in half.
    while (end > 0 and (text[end] & 0b1100_0000) == 0b1000_0000) end -= 1;
    return .{ text[0..end], true };
}

/// Replace bytes that are not valid UTF-8 with '?'. Returns the input
/// itself when it is already valid.
fn sanitize(alloc: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.append(alloc, '?');
            i += 1;
            continue;
        };
        if (i + len <= text.len and std.unicode.utf8ValidateSlice(text[i .. i + len])) {
            try out.appendSlice(alloc, text[i .. i + len]);
            i += len;
        } else {
            try out.append(alloc, '?');
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Append one line to the file at `path`, creating the file (and its
/// parent directory) if needed. The line goes out in a single write(2)
/// on an O_APPEND descriptor, so several surfaces or processes can log to
/// the same file without interleaving records.
pub fn appendLine(io: std.Io, path: [:0]const u8, line: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
    }

    const fd = std.c.open(
        path.ptr,
        .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true },
        @as(std.c.mode_t, 0o600),
    );
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    const n = std.c.write(fd, line.ptr, line.len);
    if (n < 0 or @as(usize, @intCast(n)) != line.len) return error.WriteFailed;
}

test "formatLine escapes and ends with newline" {
    const alloc = std.testing.allocator;
    const line = try formatLine(alloc, .{
        .ts_ms = 1,
        .host = "h",
        .cwd = "/tmp",
        .input = "echo \"hi\"",
        .output = "hi\nthere",
        .output_truncated = false,
        .exit_code = 0,
        .duration_ms = 12,
    });
    defer alloc.free(line);

    try std.testing.expect(line[line.len - 1] == '\n');
    const parsed = try std.json.parseFromSlice(Record, alloc, line, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("echo \"hi\"", parsed.value.input.?);
    try std.testing.expectEqualStrings("hi\nthere", parsed.value.output.?);
    try std.testing.expectEqual(@as(?u8, 0), parsed.value.exit_code);
}

test "formatLine keeps nulls and survives invalid utf-8" {
    const alloc = std.testing.allocator;
    const line = try formatLine(alloc, .{
        .ts_ms = 2,
        .host = "h",
        .cwd = null,
        .input = null,
        .output = "ok\xff\xfeend",
        .output_truncated = false,
        .exit_code = null,
        .duration_ms = 0,
    });
    defer alloc.free(line);

    const parsed = try std.json.parseFromSlice(Record, alloc, line, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.cwd == null);
    try std.testing.expect(parsed.value.exit_code == null);
    try std.testing.expectEqualStrings("ok??end", parsed.value.output.?);
}

test "trimEnd drops trailing blanks and newlines only" {
    try std.testing.expectEqualStrings("a b", trimEnd("a b \n  \t"));
    try std.testing.expectEqualStrings(" a", trimEnd(" a"));
    try std.testing.expectEqualStrings("", trimEnd(" \n"));
}

test "truncate never splits a code point" {
    // "あ" is 3 bytes; cutting at 4 would land inside the second one.
    const text = "あああ";
    const cut, const was_cut = truncate(text, 4);
    try std.testing.expect(was_cut);
    try std.testing.expectEqualStrings("あ", cut);

    const same, const not_cut = truncate("abc", 10);
    try std.testing.expect(!not_cut);
    try std.testing.expectEqualStrings("abc", same);
}

test "appendLine appends whole lines" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(dir);
    const path = try std.fmt.allocPrintSentinel(alloc, "{s}/sub/log.jsonl", .{dir}, 0);
    defer alloc.free(path);

    try appendLine(io, path, "{\"a\":1}\n");
    try appendLine(io, path, "{\"a\":2}\n");

    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [64]u8 = undefined;
    var reader = file.reader(io, &buf);
    const all = try reader.interface.allocRemaining(alloc, .limited(1024));
    defer alloc.free(all);
    try std.testing.expectEqualStrings("{\"a\":1}\n{\"a\":2}\n", all);
}
