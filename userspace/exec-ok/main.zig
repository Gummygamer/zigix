//! Small userspace command used by exec and tinysh smoke paths.

const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:OK]\n");
    sys._exit(0);
}
