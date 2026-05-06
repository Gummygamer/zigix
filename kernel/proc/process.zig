//! Minimal process table for Phase 10 lifecycle work.

const mm = @import("mm");

pub const MAX_PROCESSES: usize = 16;
pub const MAX_PROCESS_REGIONS: usize = 16;

pub const Pid = u32;

pub const Error = error{
    InvalidArgument,
    NoChild,
    NoProcess,
    OutOfMemory,
    RegionTableFull,
    WouldBlock,
    TableFull,
    Unsupported,
};

pub const WNOHANG: u64 = 1;

pub const Region = struct {
    virtual_start: usize,
    page_count: usize,
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
    address_space: mm.paging.AddressSpace = .{ .pml4 = 0 },
    regions: [MAX_PROCESS_REGIONS]Region = [_]Region{.{ .virtual_start = 0, .page_count = 0 }} ** MAX_PROCESS_REGIONS,
    region_count: usize = 0,
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
        .address_space = mm.paging.activeAddressSpace(),
    };
    current_pid = init_pid;
}

pub fn currentPid() Pid {
    return current_pid;
}

pub fn currentAddressSpace() mm.paging.AddressSpace {
    return addressSpace(current_pid) orelse mm.paging.activeAddressSpace();
}

pub fn addressSpace(pid: Pid) ?mm.paging.AddressSpace {
    const proc = find(pid) orelse return null;
    return proc.address_space;
}

pub fn registerCurrentRegion(virtual_start: usize, page_count: usize) Error!void {
    return registerRegion(current_pid, virtual_start, page_count);
}

pub fn registerRegion(pid: Pid, virtual_start: usize, page_count: usize) Error!void {
    if (page_count == 0) return error.InvalidArgument;
    const proc = find(pid) orelse return error.NoProcess;
    if (proc.region_count >= proc.regions.len) return error.RegionTableFull;
    proc.regions[proc.region_count] = .{
        .virtual_start = virtual_start,
        .page_count = page_count,
    };
    proc.region_count += 1;
}

pub fn currentRegionCount() usize {
    return regionCount(current_pid);
}

pub fn regionCount(pid: Pid) usize {
    const proc = find(pid) orelse return 0;
    return proc.region_count;
}

pub fn drainCurrentRegions(out: []Region) usize {
    return drainRegions(current_pid, out);
}

pub fn drainRegions(pid: Pid, out: []Region) usize {
    const proc = find(pid) orelse return 0;
    const count = proc.region_count;
    var index: usize = 0;
    while (index < count and index < out.len) : (index += 1) {
        out[index] = proc.regions[index];
    }
    proc.region_count = 0;
    return index;
}

pub fn spawnChild(parent: Pid) Error!Pid {
    if (find(parent) == null) return error.InvalidArgument;
    const slot = freeSlot() orelse return error.TableFull;
    const address_space = mm.paging.createUserAddressSpace() catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Unsupported => error.Unsupported,
        error.AlreadyMapped, error.NotAligned, error.NotMapped => error.InvalidArgument,
    };
    const pid = allocatePid();
    slot.* = .{
        .state = .running,
        .pid = pid,
        .parent = parent,
        .address_space = address_space,
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
    if ((options & ~WNOHANG) != 0) return error.InvalidArgument;
    if (requested_pid < -1 or requested_pid == 0) return error.InvalidArgument;

    const child = findExitedChild(caller, requested_pid) orelse {
        if (hasChild(caller, requested_pid)) {
            if ((options & WNOHANG) != 0) return 0;
            return error.WouldBlock;
        }
        return error.NoChild;
    };
    const waited_pid = child.pid;
    if (status_out) |out| out.* = exitStatusWord(child.exit_status);
    releaseProcessResources(child);
    child.* = .{};
    return waited_pid;
}

fn releaseProcessResources(proc: *Process) void {
    if (proc.address_space.pml4 != 0) {
        mm.paging.destroyUserAddressSpace(proc.address_space);
    }
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

fn hasChild(parent: Pid, requested_pid: i64) bool {
    for (&table) |*proc| {
        if (proc.state == .free) continue;
        if (proc.parent != parent) continue;
        if (requested_pid > 0 and proc.pid != @as(Pid, @intCast(requested_pid))) continue;
        return true;
    }
    return false;
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
