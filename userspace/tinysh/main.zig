//! Small Zigix shell.

const sys = @import("zigix_sys");

const MAX_COMMAND_BYTES: usize = 256;
const MAX_ARGS: usize = 8;
const EAGAIN: i64 = 11;
const BACKSPACE: u8 = 0x08;
const DELETE: u8 = 0x7f;

var command_buffer: [MAX_COMMAND_BYTES]u8 = [_]u8{0} ** MAX_COMMAND_BYTES;
var line_buffer: [MAX_COMMAND_BYTES]u8 = [_]u8{0} ** MAX_COMMAND_BYTES;
var spawn_argv: [MAX_ARGS + 1]?[*:0]const u8 = [_]?[*:0]const u8{null} ** (MAX_ARGS + 1);

export fn _start() callconv(.c) noreturn {
    const stack_addr = asm volatile ("lea 8(%%rbp), %[ret]"
        : [ret] "=r" (-> usize),
    );
    const stack: [*]const usize = @ptrFromInt(stack_addr);
    run(stack);
}

fn run(stack: [*]const usize) noreturn {
    const argc = stack[0];
    const argv_words = stack + 1;

    if (argc == 1) runInteractive();

    if (argc != 3) fail("tinysh_smoke", "usage");
    if (!eql(cStringSlice(arg(argv_words, 1)), "-c")) fail("tinysh_smoke", "usage");

    const command_line = cStringSlice(arg(argv_words, 2));
    const parsed = parseCommand(command_line) orelse fail("tinysh_smoke", "parse");
    if (parsed.argc == 0) fail("tinysh_smoke", "empty");

    const marker_name = if (parsed.hasRedirection()) "tinysh_redirection" else "tinysh_smoke";
    const action = runCommand(parsed, marker_name);
    if (action == .exit) sys._exit(0);

    if (parsed.stdout_path) |path| {
        verifyRedirectOutput(path, marker_name);
        _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:OK]\n");
        writePass("tinysh_redirection");
        writePass("tinysh_smoke");
    } else {
        writePass(marker_name);
    }
    sys._exit(0);
}

fn runInteractive() noreturn {
    while (true) {
        _ = sys.write(sys.STDOUT, "zigix$ ");
        const line = readLine() orelse fail("tinysh_interactive", "read");
        const parsed = parseCommand(line) orelse fail("tinysh_interactive", "parse");
        if (parsed.argc == 0) continue;

        const action = runCommand(parsed, "tinysh_interactive");
        if (action == .exit) {
            _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:PASS:tinysh_interactive]\n");
            sys._exit(0);
        }
    }
}

const ParsedCommand = struct {
    argv: *[MAX_ARGS + 1]?[*:0]const u8,
    argc: usize,
    stdin_path: ?[*:0]const u8 = null,
    stdout_path: ?[*:0]const u8 = null,

    fn hasRedirection(self: ParsedCommand) bool {
        return self.stdin_path != null or self.stdout_path != null;
    }
};

const CommandAction = enum {
    continue_loop,
    exit,
};

fn runCommand(parsed: ParsedCommand, marker_name: []const u8) CommandAction {
    const command = cStringSlice(parsed.argv[0].?);
    if (eql(command, "exit")) {
        if (parsed.hasRedirection()) fail(marker_name, "redir");
        return .exit;
    }
    if (eql(command, "cd")) {
        if (parsed.hasRedirection()) fail(marker_name, "redir");
        if (parsed.argc != 2) fail(marker_name, "cd");
        if (sys.chdir(parsed.argv[1].?) != 0) fail(marker_name, "cd");
        return .continue_loop;
    }

    var redirection = applyRedirections(parsed, marker_name);
    const pid = sys.posixSpawn(parsed.argv[0].?, @intFromPtr(parsed.argv), 0);
    if (pid <= 0) {
        _ = redirection.restore();
        fail(marker_name, "spawn");
    }

    var status: i32 = -1;
    const waited = sys.waitpid(pid, &status, 0);
    const restored = redirection.restore();
    if (!restored) fail(marker_name, "restore");
    if (waited != pid) fail(marker_name, "wait");
    if (status != 0) fail(marker_name, "status");
    return .continue_loop;
}

fn parseCommand(line: []const u8) ?ParsedCommand {
    if (line.len >= command_buffer.len) return null;
    @memset(&command_buffer, 0);
    @memset(&spawn_argv, null);
    @memcpy(command_buffer[0..line.len], line);

    var argc: usize = 0;
    var stdin_path: ?[*:0]const u8 = null;
    var stdout_path: ?[*:0]const u8 = null;
    var index: usize = 0;
    while (index < line.len) {
        while (index < line.len and isSpace(command_buffer[index])) : (index += 1) {
            command_buffer[index] = 0;
        }
        if (index >= line.len) break;

        const start = index;
        while (index < line.len and !isSpace(command_buffer[index])) : (index += 1) {}
        const token = command_buffer[start..index];
        if (index < line.len) {
            command_buffer[index] = 0;
            index += 1;
        }

        if (sliceEql(token, ">") or sliceEql(token, "<")) {
            while (index < line.len and isSpace(command_buffer[index])) : (index += 1) {
                command_buffer[index] = 0;
            }
            if (index >= line.len) return null;

            const path_start = index;
            while (index < line.len and !isSpace(command_buffer[index])) : (index += 1) {}
            const path_token = command_buffer[path_start..index];
            if (path_token.len == 0 or sliceEql(path_token, ">") or sliceEql(path_token, "<")) return null;
            if (index < line.len) {
                command_buffer[index] = 0;
                index += 1;
            }

            if (sliceEql(token, ">")) {
                if (stdout_path != null) return null;
                stdout_path = nullTerminatedAt(path_start);
            } else {
                if (stdin_path != null) return null;
                stdin_path = nullTerminatedAt(path_start);
            }
            continue;
        }

        if (argc >= MAX_ARGS) return null;
        spawn_argv[argc] = nullTerminatedAt(start);
        argc += 1;
    }

    return .{
        .argv = &spawn_argv,
        .argc = argc,
        .stdin_path = stdin_path,
        .stdout_path = stdout_path,
    };
}

const RedirectionState = struct {
    saved_stdin: i64 = -1,
    saved_stdout: i64 = -1,

    fn restore(self: *RedirectionState) bool {
        var ok = true;
        if (self.saved_stdin >= 0) {
            const restored = sys.dup2(@intCast(self.saved_stdin), sys.STDIN) == sys.STDIN;
            const closed = sys.close(@intCast(self.saved_stdin)) == 0;
            ok = ok and restored and closed;
            self.saved_stdin = -1;
        }
        if (self.saved_stdout >= 0) {
            const restored = sys.dup2(@intCast(self.saved_stdout), sys.STDOUT) == sys.STDOUT;
            const closed = sys.close(@intCast(self.saved_stdout)) == 0;
            ok = ok and restored and closed;
            self.saved_stdout = -1;
        }
        return ok;
    }
};

fn applyRedirections(parsed: ParsedCommand, marker_name: []const u8) RedirectionState {
    var state: RedirectionState = .{};
    if (parsed.stdin_path) |path| {
        state.saved_stdin = sys.dup(sys.STDIN);
        if (state.saved_stdin < 0) fail(marker_name, "redir");
        const fd = sys.open(path, 0, 0);
        if (fd < 0) {
            _ = state.restore();
            fail(marker_name, "redir");
        }
        if (sys.dup2(@intCast(fd), sys.STDIN) != sys.STDIN) {
            _ = sys.close(@intCast(fd));
            _ = state.restore();
            fail(marker_name, "redir");
        }
        _ = sys.close(@intCast(fd));
    }
    if (parsed.stdout_path) |path| {
        state.saved_stdout = sys.dup(sys.STDOUT);
        if (state.saved_stdout < 0) {
            _ = state.restore();
            fail(marker_name, "redir");
        }
        const fd = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 0);
        if (fd < 0) {
            _ = state.restore();
            fail(marker_name, "redir");
        }
        if (sys.dup2(@intCast(fd), sys.STDOUT) != sys.STDOUT) {
            _ = sys.close(@intCast(fd));
            _ = state.restore();
            fail(marker_name, "redir");
        }
        _ = sys.close(@intCast(fd));
    }
    return state;
}

fn verifyRedirectOutput(path: [*:0]const u8, marker_name: []const u8) void {
    const fd = sys.open(path, 0, 0);
    if (fd < 0) fail(marker_name, "verify");

    var buf: [64]u8 = undefined;
    const amount = sys.read(@intCast(fd), buf[0..]);
    _ = sys.close(@intCast(fd));
    if (amount <= 0) fail(marker_name, "verify");
    if (!sliceEql(buf[0..@intCast(amount)], "[ZIGIX:INIT:OK]\n")) fail(marker_name, "verify");
}

fn readLine() ?[]const u8 {
    @memset(&line_buffer, 0);

    var len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const amount = sys.read(sys.STDIN, byte[0..]);
        if (amount == -EAGAIN) {
            spinPause();
            continue;
        }
        if (amount <= 0) return null;

        switch (byte[0]) {
            '\n', '\r' => {
                _ = sys.write(sys.STDOUT, "\n");
                return line_buffer[0..len];
            },
            BACKSPACE, DELETE => {
                if (len > 0) {
                    len -= 1;
                    line_buffer[len] = 0;
                    _ = sys.write(sys.STDOUT, "\x08 \x08");
                }
            },
            else => {
                if (len + 1 >= line_buffer.len) return null;
                line_buffer[len] = byte[0];
                len += 1;
                _ = sys.write(sys.STDOUT, byte[0..]);
            },
        }
    }
}

fn arg(argv_words: [*]const usize, index: usize) [*:0]const u8 {
    const ptr = argv_words[index];
    if (ptr == 0) fail("tinysh_smoke", "argv");
    return @ptrFromInt(ptr);
}

fn nullTerminatedAt(index: usize) [*:0]const u8 {
    return @ptrCast(command_buffer[index..].ptr);
}

fn cStringSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn eql(left: []const u8, comptime right: []const u8) bool {
    if (left.len != right.len) return false;
    for (right, 0..) |byte, index| {
        if (left[index] != byte) return false;
    }
    return true;
}

fn sliceEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (right, 0..) |byte, index| {
        if (left[index] != byte) return false;
    }
    return true;
}

fn writePass(marker_name: []const u8) void {
    if (sliceEql(marker_name, "tinysh_interactive")) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:PASS:tinysh_interactive]\n");
    } else if (sliceEql(marker_name, "tinysh_redirection")) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:PASS:tinysh_redirection]\n");
    } else {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:PASS:tinysh_smoke]\n");
    }
}

fn fail(marker_name: []const u8, reason: []const u8) noreturn {
    if (sliceEql(marker_name, "tinysh_interactive")) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:tinysh_interactive:");
    } else if (sliceEql(marker_name, "tinysh_redirection")) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:tinysh_redirection:");
    } else {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:tinysh_smoke:");
    }
    _ = sys.write(sys.STDOUT, reason);
    _ = sys.write(sys.STDOUT, "]\n");
    sys._exit(1);
}

fn spinPause() void {
    asm volatile ("pause");
}
