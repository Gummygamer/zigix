//! Tiny userspace syscall wrappers shared by Zigix test programs.

pub const STDIN: u64 = 0;
pub const STDOUT: u64 = 1;
pub const STDERR: u64 = 2;

pub const SYS_read: u64 = 0;
pub const SYS_write: u64 = 1;
pub const SYS_open: u64 = 2;
pub const SYS_close: u64 = 3;
pub const SYS_stat: u64 = 4;
pub const SYS_fstat: u64 = 5;
pub const SYS_lseek: u64 = 8;
pub const SYS_pipe: u64 = 22;
pub const SYS_dup: u64 = 32;
pub const SYS_execve: u64 = 59;
pub const SYS_exit: u64 = 60;
pub const SYS_wait4: u64 = 61;
pub const SYS_exit_group: u64 = 231;

pub const WNOHANG: u64 = 1;

pub fn read(fd: u64, buf: []u8) i64 {
    return syscall3(SYS_read, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn write(fd: u64, bytes: []const u8) i64 {
    return syscall3(SYS_write, fd, @intFromPtr(bytes.ptr), bytes.len);
}

pub fn execve(path: [*:0]const u8, argv: usize, envp: usize) i64 {
    return syscall3(SYS_execve, @intFromPtr(path), argv, envp);
}

pub fn wait4(pid: i64, status: ?*i32, options: u64, rusage: ?*anyopaque) i64 {
    return syscall4(
        SYS_wait4,
        @bitCast(pid),
        ptrArg(status),
        options,
        ptrArg(rusage),
    );
}

pub fn waitpid(pid: i64, status: ?*i32, options: u64) i64 {
    return wait4(pid, status, options, null);
}

pub fn exit(status: u64) noreturn {
    _ = syscall1(SYS_exit, status);
    haltForever();
}

pub fn exitGroup(status: u64) noreturn {
    _ = syscall1(SYS_exit_group, status);
    haltForever();
}

pub fn _exit(status: u64) noreturn {
    exitGroup(status);
}

fn ptrArg(ptr: anytype) u64 {
    return if (ptr) |some| @intFromPtr(some) else 0;
}

fn syscall1(num: u64, arg0: u64) i64 {
    const ret = asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return @bitCast(ret);
}

fn syscall3(num: u64, arg0: u64, arg1: u64, arg2: u64) i64 {
    const ret = asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
          [arg1] "{rsi}" (arg1),
          [arg2] "{rdx}" (arg2),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return @bitCast(ret);
}

fn syscall4(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64) i64 {
    const ret = asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
          [arg1] "{rsi}" (arg1),
          [arg2] "{rdx}" (arg2),
          [arg3] "{r10}" (arg3),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return @bitCast(ret);
}

fn haltForever() noreturn {
    while (true) asm volatile ("pause");
}
