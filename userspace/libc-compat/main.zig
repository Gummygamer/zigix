//! Phase 15 compatibility probe.
//!
//! This deliberately uses only the newlib-style hooks, rather than the raw
//! Zigix syscall wrappers.  It is a small executable gate between the shim
//! unit tests and attempting a real third-party userspace build.

const libc = @import("zigix_newlib");

const path: [*:0]const u8 = "/libc-compat-probe";
const payload = "libc compatibility probe\n";
const pass_marker = "[ZIGIX:TEST:PASS:libc_shim_compat]\n";

export fn _start() callconv(.c) noreturn {
    if (libc._getpid() <= 1 or libc._getppid() != 1) fail();
    if (libc._isatty(1) != 1) fail();
    if (libc._chdir("/") != 0) fail();

    const fd = libc._open(path, 0o2 | 0o100 | 0o1000, 0);
    if (fd < 0) fail();
    if (libc._write(fd, payload.ptr, payload.len) != payload.len) fail();

    var stat: libc.Stat = .{};
    if (libc._fstat(fd, &stat) != 0 or stat.size != payload.len) fail();
    if (libc._lseek(fd, 0, 0) != 0) fail();

    var readback: [payload.len]u8 = undefined;
    if (libc._read(fd, &readback, readback.len) != readback.len) fail();
    for (payload, 0..) |byte, index| {
        if (readback[index] != byte) fail();
    }
    if (libc._close(fd) != 0) fail();

    stat = .{};
    if (libc._stat(path, &stat) != 0 or stat.size != payload.len) fail();
    if (libc._write(1, pass_marker.ptr, pass_marker.len) != pass_marker.len) fail();
    libc._exit(0);
}

fn fail() noreturn {
    const marker = "[ZIGIX:TEST:FAIL:libc_shim_compat:hook]\n";
    _ = libc._write(1, marker.ptr, marker.len);
    libc._exit(1);
}
