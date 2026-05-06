//! Syscall numbers.
//!
//! Zigix v0 intentionally follows the Linux x86_64 number registry for the
//! small Phase 6 set so future userspace can use familiar stubs.

pub const read: u64 = 0;
pub const write: u64 = 1;
pub const open: u64 = 2;
pub const close: u64 = 3;
pub const stat: u64 = 4;
pub const fstat: u64 = 5;
pub const lseek: u64 = 8;
pub const pipe: u64 = 22;
pub const dup: u64 = 32;
pub const execve: u64 = 59;
pub const exit: u64 = 60;
pub const wait4: u64 = 61;
