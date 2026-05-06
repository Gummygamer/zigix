//! First Zigix userspace process.

const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:START]\n");
    _ = sys.execve("/exec-ok", 0, 0);
    _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:execve_user:returned]\n");
    sys._exit(1);
}
