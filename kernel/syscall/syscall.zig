//! Architecture-independent syscall facade.

pub const dispatch = @import("dispatch.zig");
pub const errno = @import("errno.zig");
pub const numbers = @import("numbers.zig");

pub const Stat = dispatch.Stat;
pub const STDIN: u64 = 0;
pub const STDOUT: u64 = 1;
pub const STDERR: u64 = 2;

pub fn init() void {
    dispatch.init();
}

pub fn selfTestWriteMarker() bool {
    return dispatch.selfTestWriteMarker();
}
