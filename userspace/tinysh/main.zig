//! Phase 11 non-interactive tiny shell.

const sys = @import("zigix_sys");

const MAX_COMMAND_BYTES: usize = 256;
const MAX_ARGS: usize = 8;

var command_buffer: [MAX_COMMAND_BYTES]u8 = [_]u8{0} ** MAX_COMMAND_BYTES;
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

    if (argc != 3) fail("usage");
    if (!eql(cStringSlice(arg(argv_words, 1)), "-c")) fail("usage");

    const command_line = cStringSlice(arg(argv_words, 2));
    const parsed = parseCommand(command_line) orelse fail("parse");
    if (parsed.argc == 0) fail("empty");

    const command = cStringSlice(parsed.argv[0].?);
    if (eql(command, "exit")) sys._exit(0);

    const pid = sys.posixSpawn(parsed.argv[0].?, @intFromPtr(&parsed.argv), 0);
    if (pid <= 0) fail("spawn");

    var status: i32 = -1;
    if (sys.waitpid(pid, &status, 0) != pid) fail("wait");
    if (status != 0) fail("status");

    _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:PASS:tinysh_smoke]\n");
    sys._exit(0);
}

const ParsedCommand = struct {
    argv: *[MAX_ARGS + 1]?[*:0]const u8,
    argc: usize,
};

fn parseCommand(line: []const u8) ?ParsedCommand {
    if (line.len >= command_buffer.len) return null;
    @memset(&command_buffer, 0);
    @memset(&spawn_argv, null);
    @memcpy(command_buffer[0..line.len], line);

    var argc: usize = 0;
    var index: usize = 0;
    while (index < line.len) {
        while (index < line.len and isSpace(command_buffer[index])) : (index += 1) {
            command_buffer[index] = 0;
        }
        if (index >= line.len) break;
        if (argc >= MAX_ARGS) return null;

        spawn_argv[argc] = nullTerminatedAt(index);
        argc += 1;

        while (index < line.len and !isSpace(command_buffer[index])) : (index += 1) {}
        if (index < line.len) {
            command_buffer[index] = 0;
            index += 1;
        }
    }

    return .{
        .argv = &spawn_argv,
        .argc = argc,
    };
}

fn arg(argv_words: [*]const usize, index: usize) [*:0]const u8 {
    const ptr = argv_words[index];
    if (ptr == 0) fail("argv");
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

fn fail(reason: []const u8) noreturn {
    _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:tinysh_smoke:");
    _ = sys.write(sys.STDOUT, reason);
    _ = sys.write(sys.STDOUT, "]\n");
    sys._exit(1);
}
