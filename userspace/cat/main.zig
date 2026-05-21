//! Small userspace file display command.

const sys = @import("zigix_sys");

const BUFFER_BYTES: usize = 256;

export fn _start() callconv(.c) noreturn {
    const stack_addr = asm volatile ("lea 8(%%rbp), %[ret]"
        : [ret] "=r" (-> usize),
    );
    const stack: [*]const usize = @ptrFromInt(stack_addr);
    const argc = stack[0];
    const argv_words = stack + 1;

    if (argc < 2) {
        writeAll(sys.STDERR, "cat: usage: cat FILE...\n") catch {};
        sys._exit(1);
    }

    var ok = true;
    var index: usize = 1;
    while (index < argc) : (index += 1) {
        if (!dumpFile(arg(argv_words, index))) ok = false;
    }

    sys._exit(if (ok) 0 else 1);
}

fn dumpFile(path: [*:0]const u8) bool {
    const fd = sys.open(path, 0, 0);
    if (fd < 0) {
        writeAll(sys.STDERR, "cat: open failed: ") catch {};
        writeAll(sys.STDERR, cStringSlice(path)) catch {};
        writeAll(sys.STDERR, "\n") catch {};
        return false;
    }

    var buffer: [BUFFER_BYTES]u8 = undefined;
    while (true) {
        const amount = sys.read(@intCast(fd), buffer[0..]);
        if (amount < 0) {
            _ = sys.close(@intCast(fd));
            writeAll(sys.STDERR, "cat: read failed: ") catch {};
            writeAll(sys.STDERR, cStringSlice(path)) catch {};
            writeAll(sys.STDERR, "\n") catch {};
            return false;
        }
        if (amount == 0) break;
        writeAll(sys.STDOUT, buffer[0..@intCast(amount)]) catch {
            _ = sys.close(@intCast(fd));
            return false;
        };
    }

    return sys.close(@intCast(fd)) == 0;
}

fn writeAll(fd: u64, bytes: []const u8) error{WriteFailed}!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const amount = sys.write(fd, bytes[written..]);
        if (amount <= 0) return error.WriteFailed;
        written += @intCast(amount);
    }
}

fn arg(argv_words: [*]const usize, index: usize) [*:0]const u8 {
    const ptr = argv_words[index];
    if (ptr == 0) sys._exit(1);
    return @ptrFromInt(ptr);
}

fn cStringSlice(ptr: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (ptr[len] != 0) : (len += 1) {}
    return ptr[0..len];
}
