//! First Zigix userspace process.

const libc = @import("zigix_newlib");
const sys = @import("zigix_sys");

export fn _start() callconv(.c) noreturn {
    const mkdir_argv = [_]?[*:0]const u8{ "/tinysh", "-c", "mkdir shell-dir", null };
    const cd_argv = [_]?[*:0]const u8{ "/tinysh", "-c", "cd shell-dir", null };
    const redir_argv = [_]?[*:0]const u8{ "/tinysh", "-c", "exec-ok > redir-out", null };
    const cat_argv = [_]?[*:0]const u8{ "/tinysh", "-c", "cat cat-input", null };
    const envp = [_]?[*:0]const u8{ "ZIGIX_PHASE=11", null };

    _ = sys.write(sys.STDOUT, "[ZIGIX:INIT:START]\n");
    runProgram("/tinysh", @intFromPtr(&mkdir_argv), @intFromPtr(&envp), "tinysh_mkdir");
    runProgram("/tinysh", @intFromPtr(&cd_argv), @intFromPtr(&envp), "tinysh_mkdir");
    runProgram("/tinysh", @intFromPtr(&redir_argv), @intFromPtr(&envp), "posix_spawn_user");
    writeCatInput();
    runProgram("/tinysh", @intFromPtr(&cat_argv), @intFromPtr(&envp), "cat");

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

fn writeCatInput() void {
    const path = "cat-input";
    const marker = "[ZIGIX:TEST:PASS:cat]\n";
    const fd = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 0);
    if (fd < 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:cat:create]\n");
        sys._exit(1);
    }
    if (sys.write(@intCast(fd), marker) != @as(i64, @intCast(marker.len))) {
        _ = sys.close(@intCast(fd));
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:cat:write]\n");
        sys._exit(1);
    }
    if (sys.close(@intCast(fd)) != 0) {
        _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:cat:close]\n");
        sys._exit(1);
    }
}

fn runProgram(path: [*:0]const u8, argv: usize, envp: usize, marker_name: []const u8) void {
    const pid = sys.posixSpawn(path, argv, envp);
    if (pid <= 0) {
        fail(marker_name, "spawn");
    }

    var status: i32 = -1;
    if (sys.waitpid(pid, &status, 0) != pid or status != 0) {
        fail(marker_name, "wait");
    }
}

fn fail(marker_name: []const u8, reason: []const u8) noreturn {
    _ = sys.write(sys.STDOUT, "[ZIGIX:TEST:FAIL:");
    _ = sys.write(sys.STDOUT, marker_name);
    _ = sys.write(sys.STDOUT, ":");
    _ = sys.write(sys.STDOUT, reason);
    _ = sys.write(sys.STDOUT, "]\n");
    sys._exit(1);
}
