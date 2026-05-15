//! Shared ABI decisions for the first libc porting shim.

pub const Strategy = enum {
    newlib,
};

pub const strategy: Strategy = .newlib;

pub const ENOMEM: i32 = 12;
pub const EFAULT: i32 = 14;
pub const EINVAL: i32 = 22;
pub const ENOTTY: i32 = 25;
pub const ENOSYS: i32 = 38;

pub fn syscallResult(ret: i64, errno_slot: *i32) isize {
    if (ret < 0) {
        errno_slot.* = @intCast(-ret);
        return -1;
    }
    return @intCast(ret);
}

pub fn fail(code: i32, errno_slot: *i32) isize {
    errno_slot.* = code;
    return -1;
}

pub fn isStdioFd(fd: i32) bool {
    return fd >= 0 and fd <= 2;
}
