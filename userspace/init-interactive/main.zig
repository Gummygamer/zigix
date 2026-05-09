//! Phase 12 userspace init for scripted interactive-shell smoke.

const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    const argv = [_]?[*:0]const u8{ "/tinysh", null };
    const envp = [_]?[*:0]const u8{ "ZIGIX_PHASE=12", null };

    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:START]\n");
    const pid = sys.posixSpawn("/tinysh", @intFromPtr(&argv), @intFromPtr(&envp));
    if (pid <= 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:tinysh_interactive:spawn]\n");
        sys._exit(1);
    }

    var status: i32 = -1;
    if (sys.waitpid(pid, &status, 0) != pid or status != 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:tinysh_interactive:wait]\n");
        sys._exit(1);
    }

    sys._exit(0);
}
