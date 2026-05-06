//! First Zigix userspace process.

const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    const argv = [_]?[*:0]const u8{ "/exec-ok", "argv-ok", null };
    const envp = [_]?[*:0]const u8{ "ZIGIX_PHASE=10", null };

    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:START]\n");
    const pid = sys.posixSpawn("/exec-ok", @intFromPtr(&argv), @intFromPtr(&envp));
    if (pid <= 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:posix_spawn_user:spawn]\n");
        sys._exit(1);
    }

    var status: i32 = -1;
    if (sys.waitpid(pid, &status, 0) != pid or status != 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:posix_spawn_user:wait]\n");
        sys._exit(1);
    }

    sys._exit(0);
}
