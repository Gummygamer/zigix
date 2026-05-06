//! Replacement userspace image for the Phase 10 execve smoke path.

const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:OK]\n");
    sys._exit(0);
}
