const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const os = std.os;
const mem = std.mem;

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

    buffer: std.ArrayList(std.ArrayList(u8)),
    allocator: Allocator,
    cursor_x: usize = 0,
    cursor_y: usize = 0,
    line_count: usize = 0,
    tty: fs.File = undefined,
    file: fs.File = undefined,
    tty_w: usize = undefined,
    tty_h: usize = undefined,
    orig_termios: os.termios = undefined,
    curr_termios: os.termios = undefined,

    const Self = @This();

    pub fn init(allocator: Allocator, file_path: ?[]const u8) !Self {
        var self: Self = .{
            .buffer = std.ArrayList(std.ArrayList(u8)).init(allocator),
            .allocator = allocator,
        };

        if (file_path) |path| {
            // opens the path to the file otherwise create it
            self.file = fs.cwd().openFile(path, .{ .mode = .read_write }) catch try fs.cwd().createFile(path, .{ .read = true });

            const file_stat = try self.file.stat();
            const file_size = file_stat.size;
            const text = try self.file.readToEndAlloc(allocator, file_size);
            defer allocator.free(text);

            try self.buffer.append(std.ArrayList(u8).init(allocator));
            for (text) |char| {
                if (char == '\n') {
                    try self.buffer.append(std.ArrayList(u8).init(allocator));
                    self.line_count += 1;
                    self.cursor_y += 1;
                    continue;
                }
                try self.buffer.items[self.line_count].append(char);
            }
            self.cursor_x = self.buffer.getLast().items.len;
        } else {
            try self.buffer.append(std.ArrayList(u8).init(allocator));
        }

        //Bunch of gibberish to turn the terminal into something usable as a text editor
        //Includes stopping input buffering as well as other things like disabling automatic carriage return
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

        const writer = self.tty.writer();
        try writer.writeAll(Editor.AltBuffer);
        try self.draw_buffer(writer);

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

        for (self.buffer.items) |line| {
            line.deinit();
        }
        self.buffer.deinit();
        self.tty.close();
        self.file.close();
        try bw.flush();
    }

    pub fn save_to_file(self: *Self) !void {
        // TODO: Something wrong here
        var fw = self.file.writer();
        for (self.buffer.items) |line| {
            try fw.writeAll(line.items);
            try fw.writeByte('\n');
        }
    }

    pub fn tty_cursor_move(writer: anytype, row: usize, col: usize) !void {
        _ = try writer.print("\x1B[{};{}H", .{ row + 1, col + 1 });
    }

    pub fn get_tty_size(self: *Self) !void {
        var size = std.mem.zeroInit(os.system.winsize, .{});
        const err = os.system.ioctl(self.tty.handle, os.system.T.IOCGWINSZ, @intFromPtr(&size));
        if (os.errno(err) != .SUCCESS) return os.unexpectedErrno(@enumFromInt(err));
        self.tty_h = size.ws_row;
        self.tty_w = size.ws_col;
    }

    pub fn cursor_move(self: *Self, index: usize) !void {
        if (index > self.buffer.items.len) return error.cursor_outside_buffer;
        self.cursor = index;
    }

    pub fn delete(self: *Self) !void {
        var current_line = &self.buffer.items[self.cursor_y];
        while (current_line.items.len < self.cursor_x) self.cursor_x -= 1;
        //var above_line = &self.buffer.items[self.cursor_y-1];
        if (self.cursor_x != 0) {
            self.cursor_x -= 1;
            _ = current_line.orderedRemove(self.cursor_x);
        } else if (self.buffer.items.len > 1) {
            if (current_line.items.len != 0) {
                try self.buffer.items[self.cursor_y - 1].appendSlice(current_line.items);
            }
            if (self.cursor_y != 0) {
                self.cursor_x = self.buffer.items[self.cursor_y - 1].items.len - current_line.items.len;
                self.buffer.items[self.cursor_y].deinit();
                _ = self.buffer.orderedRemove(self.cursor_y);
                self.cursor_y -= 1;
            }
            if (self.line_count != 0) {
                self.line_count -= 1;
            }
        }
    }

    pub fn insert(self: *Self, char: u8) !void {
        var current_line = &self.buffer.items[self.cursor_y];
        while (current_line.items.len < self.cursor_x) try current_line.append(' ');
        try current_line.insert(self.cursor_x, char);
        self.cursor_x += 1;
    }

    pub fn newline(self: *Self) !void {
        try self.buffer.insert(self.cursor_y + 1, std.ArrayList(u8).init(self.allocator));
        var current_line = &self.buffer.items[self.cursor_y];
        var new_line = &self.buffer.items[self.cursor_y + 1];
        if (self.cursor_x < current_line.items.len) {
            try new_line.appendSlice(current_line.items[self.cursor_x..]);
            for (self.cursor_x..current_line.items.len) |_| {
                _ = current_line.pop();
            }
        }
        self.line_count += 1;
        self.cursor_y += 1;
        self.cursor_x = 0;
    }

    pub fn insertSlice(self: *Self, slice: []const u8) !void {
        for (slice) |char| try self.insert(char);
    }

    pub fn get_line_length(self: *Self) usize {
        if (self.buffer.items.len != 0) {
            var current_line = &self.buffer.items[self.cursor_y];
            return current_line.items.len;
        } else return 0;
    }

    pub fn get_buffer_size(self: *Self) usize {
        var result: usize = 0;
        for (self.buffer.items) |line| {
            result += line.items.len;
        }
        return result;
    }

    pub fn draw_buffer(self: *Self, writer: anytype) !void {
        try writer.print("{s}{s}", .{ Self.ClearScreen, Self.ResetCursor });
        try self.get_tty_size();
        for (self.buffer.items) |line| {
            const limit = if (line.items.len > self.tty_w) self.tty_w else line.items.len;
            try writer.print("{s}\r\n", .{line.items[0..limit]});
        }
        try Self.tty_cursor_move(writer, self.tty_h+1, 0);
        const status_line_fmt = try std.fmt.allocPrint(self.allocator,"CURSOR POS: {d}x {d}y | TTY SIZE: {d}x {d}y | BUFFER SIZE: {d} | LINE COUNT: {d} | LINE LENGTH: {d}", .{ self.cursor_x, self.cursor_y, self.tty_w, self.tty_h, self.get_buffer_size(), self.line_count, self.get_line_length() });
        defer self.allocator.free(status_line_fmt);
        const status_line_max = if (status_line_fmt.len > self.tty_w) self.tty_w else status_line_fmt.len;
        try writer.writeAll(status_line_fmt[0..status_line_max]);
        try Self.tty_cursor_move(writer, self.cursor_y, self.cursor_x);
    }

    pub fn loop(self: *Self) !void {
        const writer = self.tty.writer();

        while (true) {
            var buffer: [1]u8 = undefined;
            _ = try self.tty.read(&buffer);

            switch (buffer[0]) {
                '\x1B', '\x1F' => {
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
                    } else if (mem.eql(u8, esc_buffer[0..esc_read], "[A")) {
                        // TODO: add bounds here
                        if (self.cursor_y != 0) {
                            self.cursor_y -= 1;
                        }
                    } else if (mem.eql(u8, esc_buffer[0..esc_read], "[D")) {
                        // TODO: add bounds here
                        if (self.cursor_x != 0) {
                            self.cursor_x -= 1;
                        }
                    } else if (mem.eql(u8, esc_buffer[0..esc_read], "[C")) {
                        // TODO: add bounds here
                        self.cursor_x += 1;
                    } else if (mem.eql(u8, esc_buffer[0..esc_read], "[B")) {
                        // TODO: also add bounds here
                        if (self.cursor_y < self.buffer.items.len - 1) {
                            self.cursor_y += 1;
                        }
                    }
                },
                '\x1F' & 's' => try self.save_to_file(),
                '\x1F' & 'q' => break,
                '\x08', '\x7F' => try self.delete(),
                '\x0D' => try self.newline(),
                '\x09' => try self.insertSlice("    "),
                else => try self.insert(buffer[0]),
            }
            try self.draw_buffer(writer);
        }
    }
};

pub fn main() !void {
    //Allocator setup
    //var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    //defer arena.deinit();
    //const allocator = arena.allocator();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    var editor = try Editor.init(allocator, args.next());
    try editor.loop();
    try editor.deinit();
}

test "Editor - overflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var editor = try Editor.init(allocator, "LICENSE");

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

    try editor.deinit();
    try std.testing.expect(gpa.deinit() == .ok);
}
