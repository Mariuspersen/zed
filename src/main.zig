const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const os = std.os;

const Editor = struct {
    const ClearScreen = "\x1B[2J";
    const ResetCursor = "\x1B[H";
    const HideCursor = "\x1B[?25l";
    const SaveCursorPos = "\x1B[s";
    const SaveScreen = "\x1B[?47h";
    const AltBuffer = "\x1B[?1049h";
    const NormBuffer = "\x1B[?1049l";
    const RestoreScreen = "\x1B[?47l";
    const RestoreCursorPos = "\x1B[u";

    buffer: std.ArrayList(u8),
    cursor: usize,
    line_count: usize = 0,
    tty: fs.File = undefined,
    tty_w: usize = undefined,
    tty_h: usize = undefined,
    orig_termios: os.termios = undefined,
    curr_termios: os.termios = undefined,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        var self: Self = .{
            .buffer = std.ArrayList(u8).init(allocator),
            .cursor = 0,
        };

        const stdout_file = std.io.getStdOut().writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout = bw.writer();

        self.tty = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
        self.orig_termios = try os.tcgetattr(self.tty.handle);

        self.curr_termios = self.orig_termios;
        self.curr_termios.lflag &= ~@as(
            os.system.tcflag_t,
            os.system.ECHO |
                os.system.ICANON |
                os.system.ISIG |
                os.system.IEXTEN,
        );
        self.curr_termios.iflag &= ~@as(
            os.system.tcflag_t,
            os.system.IXON |
                os.system.ICRNL |
                os.system.BRKINT |
                os.system.INPCK |
                os.system.ISTRIP,
        );

        self.curr_termios.oflag &= ~@as(os.system.tcflag_t, os.system.OPOST);
        self.curr_termios.cflag |= os.system.CS8;
        self.curr_termios.cc[os.system.V.TIME] = 0;
        self.curr_termios.cc[os.system.V.MIN] = 1;
        try os.tcsetattr(self.tty.handle, .FLUSH, self.curr_termios);

        try stdout.writeAll(Editor.AltBuffer);
        try stdout.writeAll(Editor.ClearScreen);
        try stdout.writeAll(Editor.ResetCursor);
        try bw.flush();

        return self;
    }

    pub fn deinit(self: *Self) !void {
        try os.tcsetattr(self.tty.handle, .FLUSH, self.orig_termios);

        const stdout_file = std.io.getStdOut().writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout = bw.writer();

        try stdout.writeAll(Editor.NormBuffer);
        try stdout.writeAll(Editor.ClearScreen);
        try stdout.writeAll(Editor.ResetCursor);

        self.buffer.deinit();
        self.tty.close();
        try bw.flush();
    }

    pub fn tty_cursor_move(writer: anytype, row: usize, col: usize) !void {
        _ = try writer.print("\x1B[{};{}H",.{row + 1, col + 1});
    }

    pub fn get_tty_size(self: *Self) !void {
        var size = std.mem.zeroInit(os.system.winsize, .{});
        const err = os.system.ioctl(self.tty.handle, os.system.T.IOCGWINSZ,@intFromPtr(&size));
        if(os.errno(err) != .SUCCESS) return os.unexpectedErrno(@enumFromInt(err));
        self.tty_h = size.ws_row;
        self.tty_w = size.ws_col;
    }

    pub fn cursor_move(self: *Self, index: usize) !void {
        if (index > self.buffer.items.len) return error.cursor_outside_buffer;
        self.cursor = index;
    }

    pub fn delete(self: *Self) !void {
        var line_removed: bool = false;
        while(self.cursor != 0 and (self.buffer.items[self.cursor-1] == '\n' or self.buffer.items[self.cursor-1] == '\n')) : (self.cursor -= 1) {
            _ = self.buffer.orderedRemove(self.cursor-1);
            line_removed = true;
        }
        if (self.cursor != 0) {
            self.cursor -= 1;
            _ = self.buffer.orderedRemove(self.cursor);
        }
        if(self.cursor != 0 and line_removed) self.line_count -= 1;
            

    }

    pub fn insert(self: *Self, char: u8) !void {
        if (self.cursor >= self.buffer.items.len) {
            try self.buffer.append(char);
        } else {
            try self.buffer.insert(self.cursor, char);
        }
        self.cursor += 1;
    }

    pub fn insertSlice(self: *Self, slice: []const u8) !void {
        for (slice) |char| try self.insert(char);
    }

    pub fn get_line_length(self: *Self) usize {
        var line_start: usize = 0;
        var line_length: usize = 0;
        var line_count: usize = 0;
        
        while (line_start < self.buffer.items.len) {
            if(self.line_count == line_count) break;
            if(self.buffer.items[line_start] == '\r') line_count += 1;
            line_start += 1;
        }

        if(line_count != 0) line_start += 1;

        while (line_start+line_length < self.buffer.items.len) {
            if(self.buffer.items[line_start+line_length] == '\r') break;
            line_length += 1;
        }

        return line_length;
    }

    pub fn loop(self: *Self) !void {
        const stdout_file = std.io.getStdOut().writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout = bw.writer();

        while (true) {
            var buffer: [1]u8 = undefined;
            _ = try self.tty.read(&buffer);

            switch (buffer[0]) {
                '\x1B' => {
                    self.curr_termios.cc[os.system.V.TIME] = 1;
                    self.curr_termios.cc[os.system.V.MIN] = 0;
                    try os.tcsetattr(self.tty.handle, .NOW, self.curr_termios);

                    var esc_buffer: [8]u8 = undefined;
                    const esc_read = try self.tty.read(&esc_buffer);

                    self.curr_termios.cc[os.system.V.TIME] = 0;
                    self.curr_termios.cc[os.system.V.MIN] = 1;
                    try os.tcsetattr(self.tty.handle, .NOW, self.curr_termios);

                    if (esc_read == 0) {
                        break;
                    } else {
                        try stdout.writeAll(esc_buffer[0..esc_read]);
                        try bw.flush();
                    }
                },
                '\x08', '\x7F' => try self.delete(),
                '\x0D' => {
                    try self.insertSlice("\r\n");
                    self.line_count += 1;
                },
                else => try self.insert(buffer[0]),
            }
            try stdout.print("{s}{s}{s}", .{ Self.ClearScreen, Self.ResetCursor, self.buffer.items });
            try self.get_tty_size();
            try Self.tty_cursor_move(stdout,self.tty_h,0);
            try stdout.print("CURSOR POS: {d} BUFFER SIZE: {d} LINE COUNT: {d} LINE LENGTH: {d}", .{self.cursor, self.buffer.items.len, self.line_count, self.get_line_length()});
            try Self.tty_cursor_move(stdout,self.line_count,self.get_line_length());
            try bw.flush();
        }
    }
};

pub fn main() !void {

    //Allocator setup
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var editor = try Editor.init(allocator);
    try editor.loop();
    try editor.deinit();
}

test "Editor - overflow" {
    var editor = try Editor.init(std.testing.allocator);
    defer editor.deinit();

    try editor.insert('A');
    try editor.insert('B');
    try editor.insert('C');
    try editor.insert('D');
    try editor.insert('E');
    try editor.insert('F');
    try editor.insert('G');
    try editor.cursor_move(0);
    try editor.insert('F');
    try editor.cursor_move(1);
    try editor.delete();

    std.debug.print("{s}{s}{s}", .{ Editor.ClearScreen, Editor.ResetCursor, editor.buffer.items });
}
