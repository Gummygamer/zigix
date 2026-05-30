//! Minimal process table for Phase 10 lifecycle work.

const arch = @import("arch");
const mm = @import("mm");

pub const MAX_PROCESSES: usize = 16;
pub const MAX_PROCESS_REGIONS: usize = 16;
pub const KERNEL_STACK_PAGES: usize = 4;

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

pub const RunState = enum {
    free,
    runnable,
    running,
    blocked,
    exited,
};

const KernelStack = struct {
    base: usize = 0,
    page_count: usize = 0,
    top_override: usize = 0,
    owned: bool = false,

    fn top(self: KernelStack) usize {
        if (self.top_override != 0) return self.top_override;
        return self.base + self.page_count * mm.physical.PAGE_SIZE;
    }
};

const Process = struct {
    state: RunState = .free,
    pid: Pid = 0,
    parent: ?Pid = null,
    exit_status: u8 = 0,
    address_space: mm.paging.AddressSpace = .{ .pml4 = 0 },
    kernel_stack: KernelStack = .{},
    user_entry: usize = 0,
    user_stack_top: usize = 0,
    resume_context: arch.user.KernelContext = .{},
    resume_child: ?Pid = null,
    regions: [MAX_PROCESS_REGIONS]Region = [_]Region{.{ .virtual_start = 0, .page_count = 0 }} ** MAX_PROCESS_REGIONS,
    region_count: usize = 0,
};

pub const SpawnResume = struct {
    context: *arch.user.KernelContext,
    return_value: usize,
};

pub const UserImage = struct {
    entry: usize,
    stack_top: usize,
};

var table: [MAX_PROCESSES]Process = [_]Process{.{}} ** MAX_PROCESSES;
var next_pid: Pid = 1;
var current_pid: Pid = 1;
var run_queue: [MAX_PROCESSES]Pid = [_]Pid{0} ** MAX_PROCESSES;
var run_queue_head: usize = 0;
var run_queue_count: usize = 0;

pub fn init() void {
    for (&table) |*slot| slot.* = .{};
    clearRunQueue();
    next_pid = 1;
    const init_pid = allocatePid();
    table[0] = .{
        .state = .running,
        .pid = init_pid,
        .parent = null,
        .address_space = mm.paging.activeAddressSpace(),
        .kernel_stack = .{
            .top_override = arch.gdt.defaultKernelStackTop(),
            .owned = false,
        },
    };
    current_pid = init_pid;
    arch.gdt.setKernelStackTop(table[0].kernel_stack.top());
}

pub fn currentPid() Pid {
    return current_pid;
}

pub fn currentAddressSpace() mm.paging.AddressSpace {
    return addressSpace(current_pid) orelse mm.paging.activeAddressSpace();
}

pub fn switchTo(pid: Pid) Error!void {
    if (pid == current_pid) {
        const current = find(pid) orelse return error.NoProcess;
        if (current.state != .running) return error.NoProcess;
        return;
    }

    const next = find(pid) orelse return error.NoProcess;
    if (next.state != .runnable) return error.NoProcess;

    const previous = find(current_pid) orelse return error.NoProcess;
    _ = removeFromRunQueue(pid);
    if (previous.state == .running) previous.state = .runnable;
    if (previous.state == .runnable) try enqueueRunnable(previous.pid);

    next.state = .running;
    current_pid = pid;
    mm.paging.switchAddressSpace(next.address_space);
    arch.gdt.setKernelStackTop(next.kernel_stack.top());
}

pub fn nextRunnable() ?Pid {
    pruneRunQueue();
    if (run_queue_count == 0) return null;
    return run_queue[run_queue_head];
}

pub fn runnableQueueLen() usize {
    pruneRunQueue();
    return run_queue_count;
}

pub fn switchToNext() Error!?Pid {
    const pid = nextRunnable() orelse return null;
    try switchTo(pid);
    return pid;
}

pub fn addressSpace(pid: Pid) ?mm.paging.AddressSpace {
    const proc = find(pid) orelse return null;
    return proc.address_space;
}

pub fn runState(pid: Pid) ?RunState {
    const proc = find(pid) orelse return null;
    return proc.state;
}

pub fn parentPid(pid: Pid) ?Pid {
    const proc = find(pid) orelse return null;
    return proc.parent;
}

pub fn kernelStackTop(pid: Pid) ?usize {
    const proc = find(pid) orelse return null;
    if (proc.kernel_stack.page_count == 0 and proc.kernel_stack.top_override == 0) return null;
    return proc.kernel_stack.top();
}

pub fn setUserImage(pid: Pid, entry: usize, stack_top: usize) Error!void {
    if (entry == 0 or stack_top == 0) return error.InvalidArgument;
    const proc = find(pid) orelse return error.NoProcess;
    proc.user_entry = entry;
    proc.user_stack_top = stack_top;
}

pub fn userImage(pid: Pid) ?UserImage {
    const proc = find(pid) orelse return null;
    if (proc.user_entry == 0 or proc.user_stack_top == 0) return null;
    return .{
        .entry = proc.user_entry,
        .stack_top = proc.user_stack_top,
    };
}

pub fn beginSpawnResume(parent: Pid, child: Pid) Error!*arch.user.KernelContext {
    return beginBlockingWait(parent, child);
}

pub fn beginBlockingWait(parent: Pid, child: Pid) Error!*arch.user.KernelContext {
    const parent_proc = find(parent) orelse return error.NoProcess;
    const child_proc = find(child) orelse return error.NoProcess;
    if (child_proc.parent != parent) return error.InvalidArgument;
    if (parent_proc.resume_child != null) return error.WouldBlock;

    parent_proc.resume_context = .{};
    parent_proc.resume_child = child;
    switch (parent_proc.state) {
        .running, .runnable => parent_proc.state = .blocked,
        .blocked => {},
        .free, .exited => return error.NoProcess,
    }
    return &parent_proc.resume_context;
}

pub fn finishSpawnResume(parent: Pid, child: Pid) void {
    const parent_proc = find(parent) orelse return;
    if (parent_proc.resume_child != child) return;
    parent_proc.resume_child = null;
    parent_proc.resume_context = .{};
    if (parent_proc.state == .blocked) {
        parent_proc.state = if (current_pid == parent) .running else .runnable;
        if (parent_proc.state == .runnable) enqueueRunnable(parent) catch {};
    }
}

pub fn exitCurrent(status: u64) ?SpawnResume {
    const child = find(current_pid) orelse return null;
    if (child.state == .free) return null;

    _ = removeFromRunQueue(child.pid);
    child.state = .exited;
    child.exit_status = @truncate(status);

    const parent_pid = child.parent orelse return null;
    const parent = find(parent_pid) orelse return null;
    if (parent.resume_child != child.pid) return null;
    if (parent.state != .blocked and parent.state != .runnable and parent.state != .running) return null;

    parent.state = .running;
    _ = removeFromRunQueue(parent.pid);
    current_pid = parent.pid;
    mm.paging.switchAddressSpace(parent.address_space);
    arch.gdt.setKernelStackTop(parent.kernel_stack.top());

    return .{
        .context = &parent.resume_context,
        .return_value = child.pid,
    };
}

pub fn block(pid: Pid) Error!void {
    const proc = find(pid) orelse return error.NoProcess;
    switch (proc.state) {
        .runnable, .running => {
            _ = removeFromRunQueue(pid);
            proc.state = .blocked;
        },
        .blocked => {},
        .free, .exited => return error.NoProcess,
    }
}

pub fn wake(pid: Pid) Error!void {
    const proc = find(pid) orelse return error.NoProcess;
    switch (proc.state) {
        .blocked => {
            proc.state = .runnable;
            enqueueRunnable(pid) catch |err| {
                proc.state = .blocked;
                return err;
            };
        },
        .runnable, .running => {},
        .free, .exited => return error.NoProcess,
    }
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
    var address_space_owned = true;
    errdefer if (address_space_owned) mm.paging.destroyUserAddressSpace(address_space);

    const kernel_stack = allocateKernelStack() catch return error.OutOfMemory;
    const pid = allocatePid();
    slot.* = .{
        .state = .runnable,
        .pid = pid,
        .parent = parent,
        .address_space = address_space,
        .kernel_stack = kernel_stack,
    };
    enqueueRunnable(pid) catch |err| {
        address_space_owned = false;
        releaseProcessResources(slot);
        slot.* = .{};
        return err;
    };
    address_space_owned = false;
    return pid;
}

pub fn markExited(pid: Pid, status: u64) bool {
    const proc = find(pid) orelse return false;
    if (proc.state == .free) return false;
    _ = removeFromRunQueue(pid);
    proc.state = .exited;
    proc.exit_status = @truncate(status);
    wakeWaitingParent(proc);
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
    releaseMappedRegions(proc);
    if (proc.address_space.pml4 != 0) {
        mm.paging.destroyUserAddressSpace(proc.address_space);
    }
    releaseKernelStack(proc.kernel_stack);
}

fn releaseMappedRegions(process: *Process) void {
    if (process.address_space.pml4 == 0) {
        process.region_count = 0;
        return;
    }

    var region_index: usize = 0;
    while (region_index < process.region_count) : (region_index += 1) {
        const region = process.regions[region_index];
        var page_index: usize = 0;
        while (page_index < region.page_count) : (page_index += 1) {
            const addr = region.virtual_start + page_index * mm.physical.PAGE_SIZE;
            const mapping = mm.paging.walkIn(process.address_space, addr) orelse continue;
            if (mapping.page_size != mm.physical.PAGE_SIZE) continue;
            mm.paging.unmapPageIn(process.address_space, addr) catch continue;
            mm.physical.freePage(mapping.physical);
        }
    }
    process.region_count = 0;
}

pub fn liveChildForWait(parent: Pid, requested_pid: i64) ?Pid {
    if (requested_pid < -1 or requested_pid == 0) return null;
    for (&table) |*proc| {
        if (proc.state == .free or proc.state == .exited) continue;
        if (proc.parent != parent) continue;
        if (requested_pid > 0 and proc.pid != @as(Pid, @intCast(requested_pid))) continue;
        return proc.pid;
    }
    return null;
}

fn wakeWaitingParent(child: *Process) void {
    const parent_pid = child.parent orelse return;
    const parent = find(parent_pid) orelse return;
    if (parent.resume_child != child.pid) return;
    if (parent.state == .blocked) {
        parent.state = .runnable;
        enqueueRunnable(parent.pid) catch {};
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

fn allocateKernelStack() Error!KernelStack {
    const base = mm.physical.allocPages(KERNEL_STACK_PAGES) catch return error.OutOfMemory;
    return .{
        .base = base,
        .page_count = KERNEL_STACK_PAGES,
        .owned = true,
    };
}

fn releaseKernelStack(stack: KernelStack) void {
    if (!stack.owned) return;
    mm.physical.freePages(stack.base, stack.page_count);
}

fn allocatePid() Pid {
    const pid = next_pid;
    next_pid += 1;
    if (next_pid == 0) next_pid = 1;
    return pid;
}

fn clearRunQueue() void {
    @memset(run_queue[0..], 0);
    run_queue_head = 0;
    run_queue_count = 0;
}

fn enqueueRunnable(pid: Pid) Error!void {
    if (pid == 0) return;
    const proc = find(pid) orelse return error.NoProcess;
    if (proc.state != .runnable) return error.NoProcess;
    if (isQueued(pid)) return;
    if (run_queue_count >= run_queue.len) return error.TableFull;

    const tail = (run_queue_head + run_queue_count) % run_queue.len;
    run_queue[tail] = pid;
    run_queue_count += 1;
}

fn removeFromRunQueue(pid: Pid) bool {
    var kept: [MAX_PROCESSES]Pid = [_]Pid{0} ** MAX_PROCESSES;
    var kept_count: usize = 0;
    var removed = false;

    var index: usize = 0;
    while (index < run_queue_count) : (index += 1) {
        const queued = run_queue[(run_queue_head + index) % run_queue.len];
        if (queued == pid) {
            removed = true;
            continue;
        }
        kept[kept_count] = queued;
        kept_count += 1;
    }

    clearRunQueue();
    while (run_queue_count < kept_count) : (run_queue_count += 1) {
        run_queue[run_queue_count] = kept[run_queue_count];
    }
    return removed;
}

fn pruneRunQueue() void {
    var kept: [MAX_PROCESSES]Pid = [_]Pid{0} ** MAX_PROCESSES;
    var kept_count: usize = 0;

    var index: usize = 0;
    while (index < run_queue_count) : (index += 1) {
        const pid = run_queue[(run_queue_head + index) % run_queue.len];
        const proc = find(pid) orelse continue;
        if (proc.state != .runnable) continue;
        if (containsPid(kept[0..kept_count], pid)) continue;
        kept[kept_count] = pid;
        kept_count += 1;
    }

    clearRunQueue();
    while (run_queue_count < kept_count) : (run_queue_count += 1) {
        run_queue[run_queue_count] = kept[run_queue_count];
    }
}

fn isQueued(pid: Pid) bool {
    var index: usize = 0;
    while (index < run_queue_count) : (index += 1) {
        if (run_queue[(run_queue_head + index) % run_queue.len] == pid) return true;
    }
    return false;
}

fn containsPid(pids: []const Pid, pid: Pid) bool {
    for (pids) |item| {
        if (item == pid) return true;
    }
    return false;
}
