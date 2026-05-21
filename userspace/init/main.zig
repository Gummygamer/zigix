//! First Zigix userspace process.

const libc = @import("zigix_newlib");
const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    const argv = [_]?[*:0]const u8{ "/tinysh", "-c", "exec-ok", null };
    const envp = [_]?[*:0]const u8{ "ZIGIX_PHASE=11", null };

    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:START]\n");
    const pid = sys.posixSpawn("/tinysh", @intFromPtr(&argv), @intFromPtr(&envp));
    if (pid <= 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:posix_spawn_user:spawn]\n");
        sys._exit(1);
    }

    var status: i32 = -1;
    if (sys.waitpid(pid, &status, 0) != pid or status != 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:posix_spawn_user:wait]\n");
        sys._exit(1);
    }

    const libc_marker = "[ZIGIX:TEST:PASS:libc_shim_newlib]\n";
    if (libc._write(1, libc_marker.ptr, libc_marker.len) != libc_marker.len) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:libc_shim_newlib:write]\n");
        sys._exit(1);
    }
    if (libc._getpid() != 1 or libc._getppid() != 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:libc_shim_getpid:identity]\n");
        sys._exit(1);
    }

    sys._exit(0);
}
