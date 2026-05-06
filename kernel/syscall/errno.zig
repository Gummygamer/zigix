//! Linux-compatible errno values used by the syscall layer.

pub const PERM: i64 = 1;
pub const NOENT: i64 = 2;
pub const SRCH: i64 = 3;
pub const INTR: i64 = 4;
pub const IO: i64 = 5;
pub const BIG: i64 = 7;
pub const NOEXEC: i64 = 8;
pub const BADF: i64 = 9;
pub const CHILD: i64 = 10;
pub const AGAIN: i64 = 11;
pub const FAULT: i64 = 14;
pub const INVAL: i64 = 22;
pub const NOSYS: i64 = 38;
pub const NAMETOOLONG: i64 = 36;
pub const NFILE: i64 = 23;
pub const PIPE: i64 = 32;
pub const ISDIR: i64 = 21;
pub const NOTDIR: i64 = 20;

pub fn fail(code: i64) i64 {
    return -code;
}
