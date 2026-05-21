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
pub const SYS_dup2: u64 = 33;
pub const SYS_getpid: u64 = 39;
pub const SYS_execve: u64 = 59;
pub const SYS_exit: u64 = 60;
pub const SYS_wait4: u64 = 61;
pub const SYS_chdir: u64 = 80;
pub const SYS_getppid: u64 = 110;
pub const SYS_getdents64: u64 = 217;
pub const SYS_exit_group: u64 = 231;
pub const SYS_posix_spawn: u64 = 4000;

pub const EIO: i32 = 5;
pub const E2BIG: i32 = 7;
pub const EBADF: i32 = 9;
pub const EAGAIN: i32 = 11;
pub const ENOMEM: i32 = 12;
pub const EFAULT: i32 = 14;
pub const ENOTDIR: i32 = 20;
pub const ENOENT: i32 = 2;
pub const EINVAL: i32 = 22;
pub const ENFILE: i32 = 23;
pub const ENOTTY: i32 = 25;
pub const ENOSYS: i32 = 38;

pub const O_CLOEXEC: u64 = 0o2000000;

pub const SEEK_SET: u64 = 0;
pub const SEEK_CUR: u64 = 1;
pub const SEEK_END: u64 = 2;

pub const WNOHANG: u64 = 1;

pub const Stat = extern struct {
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u64 = 1,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    rdev: u64 = 0,
    size: i64 = 0,
    blksize: i64 = 4096,
    blocks: i64 = 0,
};

pub fn read(fd: u64, buf: []u8) i64 {
    return syscall3(SYS_read, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn write(fd: u64, bytes: []const u8) i64 {
    return syscall3(SYS_write, fd, @intFromPtr(bytes.ptr), bytes.len);
}

pub fn open(path: [*:0]const u8, flags: u64, mode: u64) i64 {
    return syscall3(SYS_open, @intFromPtr(path), flags, mode);
}

pub fn close(fd: u64) i64 {
    return syscall1(SYS_close, fd);
}

pub fn stat(path: [*:0]const u8, out: *Stat) i64 {
    return syscall2(SYS_stat, @intFromPtr(path), @intFromPtr(out));
}

pub fn fstat(fd: u64, out: *Stat) i64 {
    return syscall2(SYS_fstat, fd, @intFromPtr(out));
}

pub fn lseek(fd: u64, offset: i64, whence: u64) i64 {
    return syscall3(SYS_lseek, fd, @bitCast(offset), whence);
}

pub fn pipe(fds: *[2]i32) i64 {
    return syscall1(SYS_pipe, @intFromPtr(fds));
}

pub fn dup(fd: u64) i64 {
    return syscall1(SYS_dup, fd);
}

pub fn dup2(old_fd: u64, new_fd: u64) i64 {
    return syscall2(SYS_dup2, old_fd, new_fd);
}

pub fn getpid() i64 {
    return syscall0(SYS_getpid);
}

pub fn getppid() i64 {
    return syscall0(SYS_getppid);
}

pub fn getdents64(fd: u64, buf: []u8) i64 {
    return syscall3(SYS_getdents64, fd, @intFromPtr(buf.ptr), buf.len);
}

pub fn execve(path: [*:0]const u8, argv: usize, envp: usize) i64 {
    return syscall3(SYS_execve, @intFromPtr(path), argv, envp);
}

pub fn posixSpawn(path: [*:0]const u8, argv: usize, envp: usize) i64 {
    return syscall3(SYS_posix_spawn, @intFromPtr(path), argv, envp);
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

pub fn chdir(path: [*:0]const u8) i64 {
    return syscall1(SYS_chdir, @intFromPtr(path));
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

fn syscall0(num: u64) i64 {
    const ret = asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return @bitCast(ret);
}

fn syscall1(num: u64, arg0: u64) i64 {
    const ret = asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
        : .{ .rcx = true, .r11 = true, .memory = true });
    return @bitCast(ret);
}

fn syscall2(num: u64, arg0: u64, arg1: u64) i64 {
    const ret = asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
          [arg1] "{rsi}" (arg1),
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
