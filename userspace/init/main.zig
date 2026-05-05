//! First Zigix userspace process.

const SYS_write: u64 = 1;
const SYS_exit: u64 = 60;

const STDOUT: u64 = 1;

export fn _start() callconv(.c) noreturn {
    write(STDOUT, "[ZIGIX:INIT:START]\n");
    write(STDOUT, "[ZIGIX:INIT:OK]\n");
    exit(0);
}

fn write(fd: u64, bytes: []const u8) void {
    _ = syscall3(SYS_write, fd, @intFromPtr(bytes.ptr), bytes.len);
}

fn exit(status: u64) noreturn {
    _ = syscall1(SYS_exit, status);
    while (true) asm volatile ("pause");
}

fn syscall1(num: u64, arg0: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn syscall3(num: u64, arg0: u64, arg1: u64, arg2: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
          [arg1] "{rsi}" (arg1),
          [arg2] "{rdx}" (arg2),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
