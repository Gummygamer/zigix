//! Minimal newlib-style syscall hooks backed by Zigix syscalls.
//!
//! This is not a full libc. It is the first narrow surface needed to start
//! building a newlib port against Zigix without teaching every C object about
//! the raw `int 0x80` wrappers.

const abi = @import("abi.zig");
const sys = @import("zigix_sys");

pub export var errno: i32 = 0;

pub const Stat = sys.Stat;

pub export fn _read(fd: i32, buf: ?*anyopaque, len: usize) isize {
    const fd_arg = fdArg(fd) orelse return -1;
    if (buf == null and len != 0) return abi.fail(sys.EFAULT, &errno);
    const bytes = anyBytesMut(buf, len);
    return abi.syscallResult(sys.read(fd_arg, bytes), &errno);
}

pub export fn _write(fd: i32, buf: ?*const anyopaque, len: usize) isize {
    const fd_arg = fdArg(fd) orelse return -1;
    if (buf == null and len != 0) return abi.fail(sys.EFAULT, &errno);
    const bytes = anyBytesConst(buf, len);
    return abi.syscallResult(sys.write(fd_arg, bytes), &errno);
}

pub export fn _open(path: ?[*:0]const u8, flags: i32, mode: i32) i32 {
    if (path == null) return @intCast(abi.fail(sys.EFAULT, &errno));
    if (flags < 0 or mode < 0) return @intCast(abi.fail(sys.EINVAL, &errno));
    return @intCast(abi.syscallResult(sys.open(path.?, @intCast(flags), @intCast(mode)), &errno));
}

pub export fn _close(fd: i32) i32 {
    const fd_arg = fdArg(fd) orelse return -1;
    return @intCast(abi.syscallResult(sys.close(fd_arg), &errno));
}

pub export fn _dup2(old_fd: i32, new_fd: i32) i32 {
    const old_arg = fdArg(old_fd) orelse return -1;
    const new_arg = fdArg(new_fd) orelse return -1;
    return @intCast(abi.syscallResult(sys.dup2(old_arg, new_arg), &errno));
}

pub export fn _chdir(path: ?[*:0]const u8) i32 {
    if (path == null) return @intCast(abi.fail(sys.EFAULT, &errno));
    return @intCast(abi.syscallResult(sys.chdir(path.?), &errno));
}

pub export fn _lseek(fd: i32, offset: isize, whence: i32) isize {
    const fd_arg = fdArg(fd) orelse return -1;
    if (whence < 0) return abi.fail(sys.EINVAL, &errno);
    return abi.syscallResult(sys.lseek(fd_arg, @intCast(offset), @intCast(whence)), &errno);
}

pub export fn _fstat(fd: i32, out: ?*Stat) i32 {
    const fd_arg = fdArg(fd) orelse return -1;
    if (out == null) return @intCast(abi.fail(sys.EFAULT, &errno));
    return @intCast(abi.syscallResult(sys.fstat(fd_arg, out.?), &errno));
}

pub export fn _stat(path: ?[*:0]const u8, out: ?*Stat) i32 {
    if (path == null or out == null) return @intCast(abi.fail(sys.EFAULT, &errno));
    return @intCast(abi.syscallResult(sys.stat(path.?, out.?), &errno));
}

pub export fn _isatty(fd: i32) i32 {
    if (abi.isStdioFd(fd)) return 1;
    errno = sys.ENOTTY;
    return 0;
}

pub export fn _getpid() i32 {
    return 1;
}

pub export fn _kill(pid: i32, sig: i32) i32 {
    _ = pid;
    _ = sig;
    return @intCast(abi.fail(sys.ENOSYS, &errno));
}

pub export fn _sbrk(increment: isize) *anyopaque {
    _ = increment;
    errno = sys.ENOMEM;
    return @ptrFromInt(~@as(usize, 0));
}

pub export fn _exit(status: i32) noreturn {
    sys._exit(@intCast(if (status < 0) 1 else status));
}

fn fdArg(fd: i32) ?u64 {
    if (fd < 0) {
        errno = sys.EBADF;
        return null;
    }
    return @intCast(fd);
}

fn anyBytesMut(buf: ?*anyopaque, len: usize) []u8 {
    if (len == 0) return &.{};
    const ptr: [*]u8 = @ptrCast(buf.?);
    return ptr[0..len];
}

fn anyBytesConst(buf: ?*const anyopaque, len: usize) []const u8 {
    if (len == 0) return &.{};
    const ptr: [*]const u8 = @ptrCast(buf.?);
    return ptr[0..len];
}
