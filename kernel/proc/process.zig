//! Minimal process table for Phase 10 lifecycle work.

pub const MAX_PROCESSES: usize = 16;

pub const Pid = u32;

pub const Error = error{
    InvalidArgument,
    NoChild,
    TableFull,
};

const State = enum {
    free,
    running,
    exited,
};

const Process = struct {
    state: State = .free,
    pid: Pid = 0,
    parent: ?Pid = null,
    exit_status: u8 = 0,
};

var table: [MAX_PROCESSES]Process = [_]Process{.{}} ** MAX_PROCESSES;
var next_pid: Pid = 1;
var current_pid: Pid = 1;

pub fn init() void {
    for (&table) |*slot| slot.* = .{};
    next_pid = 1;
    const init_pid = allocatePid();
    table[0] = .{
        .state = .running,
        .pid = init_pid,
        .parent = null,
    };
    current_pid = init_pid;
}

pub fn currentPid() Pid {
    return current_pid;
}

pub fn spawnChild(parent: Pid) Error!Pid {
    if (find(parent) == null) return error.InvalidArgument;
    const slot = freeSlot() orelse return error.TableFull;
    const pid = allocatePid();
    slot.* = .{
        .state = .running,
        .pid = pid,
        .parent = parent,
    };
    return pid;
}

pub fn markExited(pid: Pid, status: u64) bool {
    const proc = find(pid) orelse return false;
    if (proc.state == .free) return false;
    proc.state = .exited;
    proc.exit_status = @truncate(status);
    return true;
}

pub fn wait4(caller: Pid, requested_pid: i64, status_out: ?*i32, options: u64) Error!Pid {
    if (options != 0) return error.InvalidArgument;
    if (requested_pid < -1 or requested_pid == 0) return error.InvalidArgument;

    const child = findExitedChild(caller, requested_pid) orelse return error.NoChild;
    const waited_pid = child.pid;
    if (status_out) |out| out.* = exitStatusWord(child.exit_status);
    child.* = .{};
    return waited_pid;
}

fn findExitedChild(parent: Pid, requested_pid: i64) ?*Process {
    for (&table) |*proc| {
        if (proc.state != .exited) continue;
        if (proc.parent != parent) continue;
        if (requested_pid > 0 and proc.pid != @as(Pid, @intCast(requested_pid))) continue;
        return proc;
    }
    return null;
}

fn exitStatusWord(status: u8) i32 {
    return @as(i32, status) << 8;
}

fn find(pid: Pid) ?*Process {
    for (&table) |*proc| {
        if (proc.state != .free and proc.pid == pid) return proc;
    }
    return null;
}

fn freeSlot() ?*Process {
    for (&table) |*proc| {
        if (proc.state == .free) return proc;
    }
    return null;
}

fn allocatePid() Pid {
    const pid = next_pid;
    next_pid += 1;
    if (next_pid == 0) next_pid = 1;
    return pid;
}
