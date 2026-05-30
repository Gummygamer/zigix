//! Small userspace directory listing command.

const sys = @import("zigix_sys");

const DIRENT_BUFFER_BYTES: usize = 512;
const PATH_BUFFER_BYTES: usize = 256;

// linux_dirent64 layout produced by the kernel's getdents64.
const DIRENT_RECLEN_OFFSET: usize = 16;
const DIRENT_NAME_OFFSET: usize = 19;

// Kept off the 4 KiB user stack; this command runs single-threaded.
var dirent_buffer: [DIRENT_BUFFER_BYTES]u8 = undefined;
var path_buffer: [PATH_BUFFER_BYTES]u8 = undefined;

export fn _start() callconv(.c) noreturn {
    const stack_addr = asm volatile ("lea 8(%%rbp), %[ret]"
        : [ret] "=r" (-> usize),
    );
    const stack: [*]const usize = @ptrFromInt(stack_addr);
    const argc = stack[0];
    const argv_words = stack + 1;

    if (argc < 2) {
        sys._exit(if (listDir(".", false)) 0 else 1);
    }

    const multiple = argc > 2;
    var ok = true;
    var index: usize = 1;
    while (index < argc) : (index += 1) {
        if (!listDir(cStringSlice(arg(argv_words, index)), multiple)) ok = false;
    }

    sys._exit(if (ok) 0 else 1);
}

fn listDir(path: []const u8, header: bool) bool {
    const fd = openPath(path);
    if (fd < 0) {
        reportError("ls: cannot open: ", path);
        return false;
    }

    if (header) {
        writeAll(sys.STDOUT, path) catch {};
        writeAll(sys.STDOUT, ":\n") catch {};
    }

    var ok = true;
    while (true) {
        const amount = sys.getdents64(@intCast(fd), dirent_buffer[0..]);
        if (amount < 0) {
            reportError("ls: read failed: ", path);
            ok = false;
            break;
        }
        if (amount == 0) break;
        if (!printEntries(dirent_buffer[0..@intCast(amount)])) {
            ok = false;
            break;
        }
    }

    return (sys.close(@intCast(fd)) == 0) and ok;
}

fn printEntries(records: []const u8) bool {
    var offset: usize = 0;
    while (offset + DIRENT_NAME_OFFSET <= records.len) {
        const reclen = readU16(records[offset + DIRENT_RECLEN_OFFSET ..]);
        if (reclen < DIRENT_NAME_OFFSET + 1 or offset + reclen > records.len) return false;

        const name = cSliceWithin(records[offset + DIRENT_NAME_OFFSET .. offset + reclen]);
        writeAll(sys.STDOUT, name) catch return false;
        writeAll(sys.STDOUT, "\n") catch return false;

        offset += reclen;
    }
    return true;
}

// Directories require a read-capable descriptor; flags 0 means O_RDONLY here.
fn openPath(path: []const u8) i64 {
    if (path.len + 1 > path_buffer.len) return -@as(i64, sys.ENOMEM);
    @memcpy(path_buffer[0..path.len], path);
    path_buffer[path.len] = 0;
    return sys.open(@ptrCast(&path_buffer), 0, 0);
}

fn reportError(prefix: []const u8, path: []const u8) void {
    writeAll(sys.STDERR, prefix) catch {};
    writeAll(sys.STDERR, path) catch {};
    writeAll(sys.STDERR, "\n") catch {};
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

fn cSliceWithin(bytes: []const u8) []const u8 {
    var len: usize = 0;
    while (len < bytes.len and bytes[len] != 0) : (len += 1) {}
    return bytes[0..len];
}

fn readU16(bytes: []const u8) usize {
    return @as(usize, bytes[0]) | (@as(usize, bytes[1]) << 8);
}
