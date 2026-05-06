//! First Zigix userspace process.

const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    const argv = [_]?[*:0]const u8{ "/exec-ok", "argv-ok", null };
    const envp = [_]?[*:0]const u8{ "ZIGIX_PHASE=10", null };

    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:START]\n");
    _ = sys.posixSpawn("/exec-ok", @intFromPtr(&argv), @intFromPtr(&envp));
    _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:posix_spawn_user:returned]\n");
    sys._exit(1);
}
