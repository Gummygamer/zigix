//! Canonical early kernel tests.

const std = @import("std");

const arch = @import("arch");
const serial = arch.serial;

const elf = @import("elf");
const fs = @import("fs");
const mm = @import("mm");
const proc = @import("proc");
const syscall = @import("syscall");
const testing = @import("testing.zig");

var exec_stack_test_buffer: [512]u8 = [_]u8{0} ** 512;
var pipe_fill_test_buffer: [syscall.dispatch.PIPE_BUFFER_SIZE]u8 = [_]u8{'x'} ** syscall.dispatch.PIPE_BUFFER_SIZE;

pub const TEST_kernel_smoke = testing.Test{
    .name = "kernel_smoke",
    .run = kernelSmoke,
};

pub const TEST_memory_smoke = testing.Test{
    .name = "memory_smoke",
    .run = memorySmoke,
};

pub const TEST_exception_caught = testing.Test{
    .name = "exception_caught",
    .run = exceptionCaught,
};

pub const TEST_timer_tick = testing.Test{
    .name = "timer_tick",
    .run = timerTick,
};

pub const TEST_syscall_write = testing.Test{
    .name = "syscall_write",
    .run = syscallWrite,
};

pub const TEST_syscall_vfs = testing.Test{
    .name = "syscall_vfs",
    .run = syscallVfs,
};

pub const TEST_syscall_fd_table = testing.Test{
    .name = "syscall_fd_table",
    .run = syscallFdTable,
};

pub const TEST_syscall_dup2 = testing.Test{
    .name = "syscall_dup2",
    .run = syscallDup2,
};

pub const TEST_syscall_chdir = testing.Test{
    .name = "syscall_chdir",
    .run = syscallChdir,
};

pub const TEST_syscall_getpid = testing.Test{
    .name = "syscall_getpid",
    .run = syscallGetpid,
};

pub const TEST_syscall_getdents64 = testing.Test{
    .name = "syscall_getdents64",
    .run = syscallGetdents64,
};

pub const TEST_syscall_pipe = testing.Test{
    .name = "syscall_pipe",
    .run = syscallPipe,
};

pub const TEST_syscall_pipe_blocking = testing.Test{
    .name = "syscall_pipe_blocking",
    .run = syscallPipeBlocking,
};

pub const TEST_syscall_stdin_console = testing.Test{
    .name = "syscall_stdin_console",
    .run = syscallStdinConsole,
};

pub const TEST_process_lifecycle = testing.Test{
    .name = "process_lifecycle",
    .run = processLifecycle,
};

pub const TEST_process_wait_nohang = testing.Test{
    .name = "process_wait_nohang",
    .run = processWaitNohang,
};

pub const TEST_process_wait_blocking = testing.Test{
    .name = "process_wait_blocking",
    .run = processWaitBlocking,
};

pub const TEST_process_address_space = testing.Test{
    .name = "process_address_space",
    .run = processAddressSpace,
};

pub const TEST_process_page_tables = testing.Test{
    .name = "process_page_tables",
    .run = processPageTables,
};

pub const TEST_process_scheduler_groundwork = testing.Test{
    .name = "process_scheduler_groundwork",
    .run = processSchedulerGroundwork,
};

pub const TEST_process_run_queue = testing.Test{
    .name = "process_run_queue",
    .run = processRunQueue,
};

pub const TEST_process_fd_tables = testing.Test{
    .name = "process_fd_tables",
    .run = processFdTables,
};

pub const TEST_process_spawn_resume = testing.Test{
    .name = "process_spawn_resume",
    .run = processSpawnResume,
};

pub const TEST_spawn_child_image = testing.Test{
    .name = "spawn_child_image",
    .run = spawnChildImage,
};

pub const TEST_posix_spawn_handoff = testing.Test{
    .name = "posix_spawn_handoff",
    .run = posixSpawnHandoff,
};

pub const TEST_execve_load = testing.Test{
    .name = "execve_load",
    .run = execveLoad,
};

pub const TEST_execve_argv_stack = testing.Test{
    .name = "execve_argv_stack",
    .run = execveArgvStack,
};

pub const TEST_elf_static_loader = testing.Test{
    .name = "elf_static_loader",
    .run = elfStaticLoader,
};

fn kernelSmoke() testing.TestError!void {
    if (!serial.scratchRoundTrip(0x5A)) return error.SerialScratchMismatch;

    const before = serial.writtenByteCount();
    serial.writeLine("[ZIGIX:TEST:SERIAL_WRITE:kernel_smoke]");
    const after = serial.writtenByteCount();
    if (after - before != "[ZIGIX:TEST:SERIAL_WRITE:kernel_smoke]".len + 1) {
        return error.SerialWriteLineTruncated;
    }
}

fn memorySmoke() testing.TestError!void {
    const before = mm.physical.currentStats().tracked_free_pages;

    const page = try mm.physical.allocPage();
    if (page % mm.physical.PAGE_SIZE != 0) return error.PageNotAligned;
    if (mm.physical.isPageFree(page)) return error.AllocatedPageStillFree;

    const mapping = mm.paging.walk(page) orelse return error.PageWalkMissing;
    if (mapping.physical != page) return error.PageWalkWrongPhysical;
    if (!mapping.writable) return error.PageWalkReadOnly;

    mm.physical.freePage(page);
    if (!mm.physical.isPageFree(page)) return error.FreedPageStillUsed;
    if (mm.physical.currentStats().tracked_free_pages != before) return error.PageFreeCountMismatch;

    const allocator = mm.heap.allocator();
    const bytes = try allocator.alloc(u8, 64);
    bytes[0] = 0x5a;
    bytes[63] = 0xa5;
    if (bytes[0] != 0x5a or bytes[63] != 0xa5) return error.HeapRoundTripFailed;
    allocator.free(bytes);

    const mapped_page = try mm.physical.allocPage();
    const mapped_virtual = 0x4000_0000; // First byte beyond the boot 1 GiB map.
    try mm.paging.mapPage(mapped_virtual, mapped_page, true);

    const mapped = mm.paging.walk(mapped_virtual) orelse return error.NewMappingMissing;
    if (mapped.physical != mapped_page) return error.NewMappingWrongPhysical;
    if (mapped.page_size != 4096) return error.NewMappingWrongSize;

    const mapped_bytes: [*]volatile u8 = @ptrFromInt(mapped_virtual);
    mapped_bytes[0] = 0xc3;
    if (mapped_bytes[0] != 0xc3) return error.NewMappingRoundTripFailed;

    try mm.paging.unmapPage(mapped_virtual);
    if (mm.paging.walk(mapped_virtual) != null) return error.UnmappedPageStillPresent;
    mm.physical.freePage(mapped_page);

    serial.writeLine("[ZIGIX:MM:OK]");
}

fn exceptionCaught() testing.TestError!void {
    if (!arch.interrupts.triggerUdSelfTest()) return error.ExceptionNotCaught;
}

fn timerTick() testing.TestError!void {
    const before = arch.interrupts.tickCount();
    var spins: usize = 0;
    while (arch.interrupts.tickCount() == before and spins < 10_000_000) : (spins += 1) {
        asm volatile ("pause");
    }
    if (arch.interrupts.tickCount() == before) return error.TimerDidNotTick;
}

fn syscallWrite() testing.TestError!void {
    if (!syscall.selfTestWriteMarker()) return error.SyscallWriteFailed;
}

fn syscallVfs() testing.TestError!void {
    const path = "/init\x00";
    const fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), 0, 0, 0, 0, 0);
    if (fd < 3) return error.SyscallOpenFailed;

    var stat: syscall.Stat = .{};
    if (syscall.dispatch.invoke(syscall.numbers.fstat, @intCast(fd), @intFromPtr(&stat), 0, 0, 0, 0) != 0) {
        return error.SyscallFstatFailed;
    }
    if (stat.size <= 0) return error.SyscallFstatEmptyFile;

    var buf: [4]u8 = undefined;
    const read = syscall.dispatch.invoke(syscall.numbers.read, @intCast(fd), @intFromPtr(&buf), buf.len, 0, 0, 0);
    if (read != buf.len) return error.SyscallReadFailed;
    if (!std.mem.eql(u8, &buf, "\x7fELF")) return error.SyscallReadWrongData;

    if (syscall.dispatch.invoke(syscall.numbers.lseek, @intCast(fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallLseekFailed;
    }

    if (syscall.dispatch.invoke(syscall.numbers.stat, @intFromPtr(path.ptr), @intFromPtr(&stat), 0, 0, 0, 0) != 0) {
        return error.SyscallStatFailed;
    }
    if (stat.size <= 0) return error.SyscallStatEmptyFile;

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
}

fn syscallFdTable() testing.TestError!void {
    const path = "/init\x00";
    const fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), 0, 0, 0, 0, 0);
    if (fd < 3) return error.SyscallOpenFailed;

    const dup_fd = syscall.dispatch.invoke(syscall.numbers.dup, @intCast(fd), 0, 0, 0, 0, 0);
    if (dup_fd < 3 or dup_fd == fd) return error.SyscallDupFailed;

    var buf: [4]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fd), @intFromPtr(&buf), buf.len, 0, 0, 0) != buf.len) {
        return error.SyscallReadFailed;
    }
    if (!std.mem.eql(u8, &buf, "\x7fELF")) return error.SyscallReadWrongData;

    var class_buf: [1]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(dup_fd), @intFromPtr(&class_buf), class_buf.len, 0, 0, 0) != class_buf.len) {
        return error.SyscallDupReadFailed;
    }
    if (class_buf[0] != 2) return error.SyscallDupDidNotShareOffset;

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.lseek, @intCast(dup_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallLseekFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(dup_fd), @intFromPtr(&buf), buf.len, 0, 0, 0) != buf.len) {
        return error.SyscallReadAfterCloseFailed;
    }
    if (!std.mem.eql(u8, &buf, "\x7fELF")) return error.SyscallDupLostOpenFile;
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(dup_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }

    const cloexec_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), syscall.dispatch.O_CLOEXEC, 0, 0, 0, 0);
    if (cloexec_fd < 3) return error.SyscallCloexecOpenFailed;
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(cloexec_fd)) != true) {
        return error.SyscallCloexecFlagMissing;
    }

    const cloexec_dup = syscall.dispatch.invoke(syscall.numbers.dup, @intCast(cloexec_fd), 0, 0, 0, 0, 0);
    if (cloexec_dup < 3) return error.SyscallCloexecDupFailed;
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(cloexec_dup)) != false) {
        return error.SyscallDupPreservedCloexec;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(cloexec_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(cloexec_dup), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
}

fn syscallDup2() testing.TestError!void {
    const path = "/init\x00";
    const fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), 0, 0, 0, 0, 0);
    if (fd < 3) return error.SyscallOpenFailed;

    const replacement_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), 0, 0, 0, 0, 0);
    if (replacement_fd < 3 or replacement_fd == fd) return error.SyscallOpenFailed;

    var magic: [4]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fd), @intFromPtr(&magic), magic.len, 0, 0, 0) != magic.len) {
        return error.SyscallReadFailed;
    }
    if (!std.mem.eql(u8, &magic, "\x7fELF")) return error.SyscallReadWrongData;

    if (syscall.dispatch.invoke(syscall.numbers.dup2, @intCast(fd), @intCast(replacement_fd), 0, 0, 0, 0) != replacement_fd) {
        return error.SyscallDup2Failed;
    }

    var class_buf: [1]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(replacement_fd), @intFromPtr(&class_buf), class_buf.len, 0, 0, 0) != class_buf.len) {
        return error.SyscallDup2ReadFailed;
    }
    if (class_buf[0] != 2) return error.SyscallDup2DidNotShareOffset;

    if (syscall.dispatch.invoke(syscall.numbers.dup2, 99, @intCast(replacement_fd), 0, 0, 0, 0) != -syscall.errno.BADF) {
        return error.SyscallDup2InvalidOldFdAccepted;
    }
    if (syscall.dispatch.invoke(syscall.numbers.lseek, @intCast(replacement_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallDup2InvalidOldClosedTarget;
    }

    const cloexec_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), syscall.dispatch.O_CLOEXEC, 0, 0, 0, 0);
    if (cloexec_fd < 3) return error.SyscallCloexecOpenFailed;
    if (syscall.dispatch.invoke(syscall.numbers.dup2, @intCast(cloexec_fd), @intCast(cloexec_fd), 0, 0, 0, 0) != cloexec_fd) {
        return error.SyscallDup2SameFdFailed;
    }
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(cloexec_fd)) != true) {
        return error.SyscallDup2SameFdChangedCloexec;
    }

    if (syscall.dispatch.invoke(syscall.numbers.dup2, @intCast(cloexec_fd), @intCast(replacement_fd), 0, 0, 0, 0) != replacement_fd) {
        return error.SyscallDup2CloexecFailed;
    }
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(replacement_fd)) != false) {
        return error.SyscallDup2PreservedCloexec;
    }

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(cloexec_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(replacement_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
}

fn syscallChdir() testing.TestError!void {
    const root = "/\x00";
    const relative_exec = "exec-ok\x00";
    const file = "/exec-ok\x00";
    const missing = "/missing\x00";

    if (syscall.dispatch.invoke(syscall.numbers.chdir, @intFromPtr(root.ptr), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallChdirRootFailed;
    }

    const fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(relative_exec.ptr), 0, 0, 0, 0, 0);
    if (fd < 3) return error.SyscallRelativeOpenFailed;
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }

    if (syscall.dispatch.invoke(syscall.numbers.chdir, @intFromPtr(file.ptr), 0, 0, 0, 0, 0) != -syscall.errno.NOTDIR) {
        return error.SyscallChdirFileAccepted;
    }
    if (syscall.dispatch.invoke(syscall.numbers.chdir, @intFromPtr(missing.ptr), 0, 0, 0, 0, 0) != -syscall.errno.NOENT) {
        return error.SyscallChdirMissingAccepted;
    }
}

fn syscallGetpid() testing.TestError!void {
    const parent = proc.currentPid();
    if (syscall.dispatch.invoke(syscall.numbers.getpid, 0, 0, 0, 0, 0, 0) != parent) {
        return error.SyscallGetpidWrongParent;
    }
    if (syscall.dispatch.invoke(syscall.numbers.getppid, 0, 0, 0, 0, 0, 0) != 0) {
        return error.SyscallGetppidWrongInitParent;
    }

    const child = try proc.spawnChild(parent);
    var child_reaped = false;
    errdefer {
        if (proc.currentPid() != parent) {
            proc.switchTo(parent) catch {};
        }
        if (!child_reaped and proc.runState(child) != null) {
            _ = proc.markExited(child, 1);
            _ = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
        }
    }

    try proc.switchTo(child);
    if (syscall.dispatch.invoke(syscall.numbers.getpid, 0, 0, 0, 0, 0, 0) != child) {
        return error.SyscallGetpidWrongChild;
    }
    if (syscall.dispatch.invoke(syscall.numbers.getppid, 0, 0, 0, 0, 0, 0) != parent) {
        return error.SyscallGetppidWrongChildParent;
    }

    try proc.switchTo(parent);
    if (!proc.markExited(child, 0)) return error.SyscallGetpidChildExitFailed;
    if (syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0) != child) {
        return error.SyscallGetpidChildReapFailed;
    }
    child_reaped = true;
}

fn syscallGetdents64() testing.TestError!void {
    const root = "/\x00";
    const init = "/init\x00";

    const root_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(root.ptr), 0, 0, 0, 0, 0);
    if (root_fd < 3) return error.SyscallGetdentsOpenRootFailed;

    var buf: [256]u8 = undefined;
    const bytes = syscall.dispatch.invoke(syscall.numbers.getdents64, @intCast(root_fd), @intFromPtr(&buf), buf.len, 0, 0, 0);
    if (bytes <= 0) return error.SyscallGetdentsReadFailed;

    var seen_init = false;
    var seen_exec_ok = false;
    var seen_tinysh = false;
    var offset: usize = 0;
    while (offset < @as(usize, @intCast(bytes))) {
        if (offset + 19 > @as(usize, @intCast(bytes))) return error.SyscallGetdentsShortRecord;
        const reclen = readLeU16(buf[offset + 16 .. offset + 18]);
        if (reclen < 20 or offset + reclen > @as(usize, @intCast(bytes))) return error.SyscallGetdentsBadRecordLen;
        if (readLeI64(buf[offset + 8 .. offset + 16]) <= 0) return error.SyscallGetdentsBadOffset;

        const entry_type = buf[offset + 18];
        const name = direntName(buf[offset + 19 .. offset + reclen]) orelse return error.SyscallGetdentsMissingNull;
        if (std.mem.eql(u8, name, "init")) {
            seen_init = true;
            if (entry_type != 8) return error.SyscallGetdentsWrongType;
        } else if (std.mem.eql(u8, name, "exec-ok")) {
            seen_exec_ok = true;
            if (entry_type != 8) return error.SyscallGetdentsWrongType;
        } else if (std.mem.eql(u8, name, "tinysh")) {
            seen_tinysh = true;
            if (entry_type != 8) return error.SyscallGetdentsWrongType;
        }
        offset += reclen;
    }
    if (!seen_init or !seen_exec_ok or !seen_tinysh) return error.SyscallGetdentsMissingInitramfsEntry;

    if (syscall.dispatch.invoke(syscall.numbers.getdents64, @intCast(root_fd), @intFromPtr(&buf), buf.len, 0, 0, 0) != 0) {
        return error.SyscallGetdentsEofFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(root_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }

    const small_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(root.ptr), 0, 0, 0, 0, 0);
    if (small_fd < 3) return error.SyscallGetdentsOpenRootFailed;
    var small: [8]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.getdents64, @intCast(small_fd), @intFromPtr(&small), small.len, 0, 0, 0) != -syscall.errno.INVAL) {
        return error.SyscallGetdentsSmallBufferAccepted;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(small_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }

    const file_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(init.ptr), 0, 0, 0, 0, 0);
    if (file_fd < 3) return error.SyscallOpenFailed;
    if (syscall.dispatch.invoke(syscall.numbers.getdents64, @intCast(file_fd), @intFromPtr(&buf), buf.len, 0, 0, 0) != -syscall.errno.NOTDIR) {
        return error.SyscallGetdentsFileAccepted;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(file_fd), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallCloseFailed;
    }
}

fn syscallPipe() testing.TestError!void {
    var fds: [2]i32 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.pipe, @intFromPtr(&fds), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeFailed;
    }
    if (fds[0] < 3 or fds[1] < 3 or fds[0] == fds[1]) return error.SyscallPipeBadFds;

    const message = "pipe-ok";
    if (syscall.dispatch.invoke(syscall.numbers.write, @intCast(fds[1]), @intFromPtr(message.ptr), message.len, 0, 0, 0) != message.len) {
        return error.SyscallPipeWriteFailed;
    }

    var buf: [message.len]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fds[0]), @intFromPtr(&buf), buf.len, 0, 0, 0) != buf.len) {
        return error.SyscallPipeReadFailed;
    }
    if (!std.mem.eql(u8, &buf, message)) return error.SyscallPipeWrongData;

    const dup_write = syscall.dispatch.invoke(syscall.numbers.dup, @intCast(fds[1]), 0, 0, 0, 0, 0);
    if (dup_write < 3) return error.SyscallPipeDupFailed;

    const tail = "!";
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fds[1]), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.write, @intCast(dup_write), @intFromPtr(tail.ptr), tail.len, 0, 0, 0) != tail.len) {
        return error.SyscallPipeDupWriteFailed;
    }

    var tail_buf: [1]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fds[0]), @intFromPtr(&tail_buf), tail_buf.len, 0, 0, 0) != tail_buf.len) {
        return error.SyscallPipeDupReadFailed;
    }
    if (tail_buf[0] != '!') return error.SyscallPipeDupWrongData;

    if (syscall.dispatch.invoke(syscall.numbers.write, @intCast(fds[0]), @intFromPtr(tail.ptr), tail.len, 0, 0, 0) != -syscall.errno.BADF) {
        return error.SyscallPipeReadEndWritable;
    }
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(dup_write), @intFromPtr(&tail_buf), tail_buf.len, 0, 0, 0) != -syscall.errno.BADF) {
        return error.SyscallPipeWriteEndReadable;
    }

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(dup_write), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fds[0]), @intFromPtr(&tail_buf), tail_buf.len, 0, 0, 0) != 0) {
        return error.SyscallPipeEofFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fds[0]), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeCloseFailed;
    }

    var closed_read_fds: [2]i32 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.pipe, @intFromPtr(&closed_read_fds), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(closed_read_fds[0]), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.write, @intCast(closed_read_fds[1]), @intFromPtr(tail.ptr), tail.len, 0, 0, 0) != -syscall.errno.PIPE) {
        return error.SyscallPipeNoReadersFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(closed_read_fds[1]), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeCloseFailed;
    }
}

fn syscallPipeBlocking() testing.TestError!void {
    const parent = proc.currentPid();
    const child = try proc.spawnChild(parent);
    var child_reaped = false;
    var fds: [2]i32 = undefined;
    var fds_open = false;

    errdefer {
        if (proc.currentPid() != parent) {
            proc.switchTo(parent) catch {};
        }
        if (fds_open) {
            _ = syscall.dispatch.invoke(syscall.numbers.close, @intCast(fds[0]), 0, 0, 0, 0, 0);
            _ = syscall.dispatch.invoke(syscall.numbers.close, @intCast(fds[1]), 0, 0, 0, 0, 0);
        }
        if (!child_reaped and proc.runState(child) != null) {
            _ = proc.markExited(child, 1);
            _ = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
        }
    }

    if (syscall.dispatch.invoke(syscall.numbers.pipe, @intFromPtr(&fds), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeFailed;
    }
    fds_open = true;

    try proc.switchTo(child);
    var one: [1]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fds[0]), @intFromPtr(&one), one.len, 0, 0, 0) != -syscall.errno.AGAIN) {
        return error.SyscallPipeEmptyReadDidNotBlock;
    }
    if (proc.runState(child) != .blocked) return error.SyscallPipeReaderNotBlocked;

    try proc.switchTo(parent);
    const msg = "r";
    if (syscall.dispatch.invoke(syscall.numbers.write, @intCast(fds[1]), @intFromPtr(msg.ptr), msg.len, 0, 0, 0) != msg.len) {
        return error.SyscallPipeWakeWriteFailed;
    }
    if (proc.runState(child) != .runnable) return error.SyscallPipeReaderNotWoken;

    try proc.switchTo(child);
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fds[0]), @intFromPtr(&one), one.len, 0, 0, 0) != one.len) {
        return error.SyscallPipeReadAfterWakeFailed;
    }
    if (one[0] != 'r') return error.SyscallPipeReadAfterWakeWrongData;

    try proc.switchTo(parent);
    if (syscall.dispatch.invoke(syscall.numbers.write, @intCast(fds[1]), @intFromPtr(&pipe_fill_test_buffer), pipe_fill_test_buffer.len, 0, 0, 0) != pipe_fill_test_buffer.len) {
        return error.SyscallPipeFillFailed;
    }

    try proc.switchTo(child);
    const tail = "!";
    if (syscall.dispatch.invoke(syscall.numbers.write, @intCast(fds[1]), @intFromPtr(tail.ptr), tail.len, 0, 0, 0) != -syscall.errno.AGAIN) {
        return error.SyscallPipeFullWriteDidNotBlock;
    }
    if (proc.runState(child) != .blocked) return error.SyscallPipeWriterNotBlocked;

    try proc.switchTo(parent);
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(fds[0]), @intFromPtr(&one), one.len, 0, 0, 0) != one.len) {
        return error.SyscallPipeDrainFailed;
    }
    if (proc.runState(child) != .runnable) return error.SyscallPipeWriterNotWoken;

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fds[0]), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(fds[1]), 0, 0, 0, 0, 0) != 0) {
        return error.SyscallPipeCloseFailed;
    }
    fds_open = false;

    if (!proc.markExited(child, 0)) return error.SyscallPipeBlockingChildExitFailed;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    if (waited != child) return error.SyscallPipeBlockingChildReapFailed;
    child_reaped = true;
}

fn syscallStdinConsole() testing.TestError!void {
    serial.clearReceivedForTest();

    var buf: [4]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, syscall.STDIN, @intFromPtr(&buf), buf.len, 0, 0, 0) != -syscall.errno.AGAIN) {
        return error.SyscallStdinEmptyDidNotReturnAgain;
    }

    serial.injectReceivedForTest("abc");
    if (syscall.dispatch.invoke(syscall.numbers.read, syscall.STDIN, @intFromPtr(&buf), 2, 0, 0, 0) != 2) {
        return error.SyscallStdinFirstReadFailed;
    }
    if (!std.mem.eql(u8, buf[0..2], "ab")) return error.SyscallStdinFirstReadWrongData;

    if (syscall.dispatch.invoke(syscall.numbers.read, syscall.STDIN, @intFromPtr(&buf), buf.len, 0, 0, 0) != 1) {
        return error.SyscallStdinSecondReadFailed;
    }
    if (buf[0] != 'c') return error.SyscallStdinSecondReadWrongData;

    if (syscall.dispatch.invoke(syscall.numbers.read, syscall.STDIN, @intFromPtr(&buf), buf.len, 0, 0, 0) != -syscall.errno.AGAIN) {
        return error.SyscallStdinDrainedDidNotReturnAgain;
    }
}

fn processLifecycle() testing.TestError!void {
    const any_child = try proc.spawnChild(proc.currentPid());
    if (!proc.markExited(any_child, 3)) return error.ProcessExitFailed;

    var status: i32 = 0;
    const any_waited = syscall.dispatch.invoke(syscall.numbers.wait4, @bitCast(@as(i64, -1)), @intFromPtr(&status), 0, 0, 0, 0);
    if (any_waited != any_child) return error.ProcessWaitAnyFailed;
    if (status != 3 << 8) return error.ProcessWaitStatusWrong;

    const child = try proc.spawnChild(proc.currentPid());
    if (!proc.markExited(child, 7)) return error.ProcessExitFailed;

    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, @intFromPtr(&status), 0, 0, 0, 0);
    if (waited != child) return error.ProcessWaitFailed;
    if (status != 7 << 8) return error.ProcessWaitStatusWrong;

    if (syscall.dispatch.invoke(syscall.numbers.wait4, child, @intFromPtr(&status), 0, 0, 0, 0) != -syscall.errno.CHILD) {
        return error.ProcessDoubleWaitSucceeded;
    }
}

fn processWaitNohang() testing.TestError!void {
    const child = try proc.spawnChild(proc.currentPid());

    var status: i32 = 0x5555;
    const nohang = syscall.dispatch.invoke(syscall.numbers.wait4, child, @intFromPtr(&status), proc.WNOHANG, 0, 0, 0);
    if (nohang != 0) return error.ProcessWaitNohangFailed;
    if (status != 0x5555) return error.ProcessWaitNohangWroteStatus;

    const would_block = syscall.dispatch.invoke(syscall.numbers.wait4, child, @intFromPtr(&status), 0, 0, 0, 0);
    if (would_block != -syscall.errno.AGAIN) return error.ProcessWaitWouldBlockWrongErrno;
    if (status != 0x5555) return error.ProcessWaitWouldBlockWroteStatus;

    if (!proc.markExited(child, 11)) return error.ProcessExitFailed;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, @intFromPtr(&status), proc.WNOHANG, 0, 0, 0);
    if (waited != child) return error.ProcessWaitFailed;
    if (status != 11 << 8) return error.ProcessWaitStatusWrong;

    if (syscall.dispatch.invoke(syscall.numbers.wait4, @bitCast(@as(i64, -1)), @intFromPtr(&status), proc.WNOHANG, 0, 0, 0) != -syscall.errno.CHILD) {
        return error.ProcessWaitNoChildrenWrongErrno;
    }
}

fn processWaitBlocking() testing.TestError!void {
    const parent = proc.currentPid();
    const path = "/exec-ok\x00";
    const arg0 = "/exec-ok\x00";
    const argv = [_]u64{ @intFromPtr(arg0.ptr), 0 };

    const child_ret = syscall.dispatch.invoke(syscall.numbers.posix_spawn, @intFromPtr(path.ptr), @intFromPtr(&argv), 0, 0, 0, 0);
    if (child_ret <= 0) return error.ProcessBlockingWaitSpawnFailed;

    const child: proc.Pid = @intCast(child_ret);
    if (proc.currentPid() != parent) return error.ProcessBlockingWaitSpawnChangedCurrent;
    if (proc.runState(child) != .runnable) return error.ProcessBlockingWaitChildNotRunnable;

    var status: i32 = 0x7777;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, @intFromPtr(&status), 0, 0, 0, 0);
    if (waited != child) return error.ProcessBlockingWaitFailed;
    if (status != 0) return error.ProcessBlockingWaitStatusWrong;
    if (proc.currentPid() != parent) return error.ProcessBlockingWaitWrongCurrent;
    if (proc.runState(child) != null) return error.ProcessBlockingWaitChildSurvivedReap;
}

fn processAddressSpace() testing.TestError!void {
    if (proc.currentRegionCount() != 0) return error.RegionRegistryNotEmpty;

    try proc.registerCurrentRegion(0x4000_0000, 4);
    try proc.registerCurrentRegion(0x4001_0000, 8);
    try proc.registerCurrentRegion(0x4002_0000, 1);
    if (proc.currentRegionCount() != 3) return error.RegionRegistryCountWrong;

    var buffer: [proc.MAX_PROCESS_REGIONS]proc.Region = undefined;
    const drained = proc.drainCurrentRegions(&buffer);
    if (drained != 3) return error.RegionRegistryDrainCountWrong;
    if (buffer[0].virtual_start != 0x4000_0000 or buffer[0].page_count != 4) {
        return error.RegionRegistryDrainOrderWrong;
    }
    if (buffer[2].virtual_start != 0x4002_0000 or buffer[2].page_count != 1) {
        return error.RegionRegistryDrainOrderWrong;
    }
    if (proc.currentRegionCount() != 0) return error.RegionRegistryNotDrained;

    if (proc.registerCurrentRegion(0x5000_0000, 0)) |_| {
        return error.RegionRegistryAcceptedZero;
    } else |err| {
        if (err != error.InvalidArgument) return error.RegionRegistryWrongZeroError;
    }

    var index: usize = 0;
    while (index < proc.MAX_PROCESS_REGIONS) : (index += 1) {
        try proc.registerCurrentRegion(0x5000_0000 + index * 0x10_0000, 1);
    }
    if (proc.currentRegionCount() != proc.MAX_PROCESS_REGIONS) return error.RegionRegistryFillFailed;

    if (proc.registerCurrentRegion(0x6000_0000, 1)) |_| {
        return error.RegionRegistryAcceptedOverflow;
    } else |err| {
        if (err != error.RegionTableFull) return error.RegionRegistryWrongOverflowError;
    }

    if (proc.drainCurrentRegions(&buffer) != proc.MAX_PROCESS_REGIONS) return error.RegionRegistryFinalDrainCountWrong;
    if (proc.currentRegionCount() != 0) return error.RegionRegistryFinalNotDrained;
}

fn processPageTables() testing.TestError!void {
    const child = try proc.spawnChild(proc.currentPid());
    const child_space = proc.addressSpace(child) orelse return error.ProcessMissingAddressSpace;
    const user_addr: usize = 0x4000_0000;

    if (mm.paging.walk(user_addr) != null) return error.ProcessParentUserMappingDirty;

    const page = try mm.physical.allocPage();
    var mapped = false;
    errdefer {
        if (mapped) mm.paging.unmapPageIn(child_space, user_addr) catch {};
        mm.physical.freePage(page);
        _ = proc.markExited(child, 1);
        _ = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    }

    try mm.paging.mapUserPageIn(child_space, user_addr, page, true);
    mapped = true;

    if (mm.paging.walk(user_addr) != null) return error.ProcessChildMappingLeakedToParent;
    const child_mapping = mm.paging.walkIn(child_space, user_addr) orelse return error.ProcessChildMappingMissing;
    if (child_mapping.physical != page) return error.ProcessChildMappingWrongPhysical;
    if (!child_mapping.writable) return error.ProcessChildMappingReadOnly;

    try mm.paging.unmapPageIn(child_space, user_addr);
    mapped = false;
    mm.physical.freePage(page);

    if (!proc.markExited(child, 0)) return error.ProcessPageTableChildExitFailed;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    if (waited != child) return error.ProcessPageTableChildReapFailed;
}

fn processSchedulerGroundwork() testing.TestError!void {
    const parent = proc.currentPid();
    const parent_space = mm.paging.activeAddressSpace();
    if (proc.runState(parent) != .running) return error.ProcessParentNotRunning;

    const child = try proc.spawnChild(parent);
    errdefer {
        if (proc.currentPid() != parent) {
            proc.switchTo(parent) catch {};
        }
        _ = proc.markExited(child, 1);
        _ = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    }

    if (proc.runState(child) != .runnable) return error.ProcessChildNotRunnable;
    const child_stack_top = proc.kernelStackTop(child) orelse return error.ProcessChildKernelStackMissing;
    if (child_stack_top % mm.physical.PAGE_SIZE != 0) return error.ProcessChildKernelStackUnaligned;

    const child_space = proc.addressSpace(child) orelse return error.ProcessMissingAddressSpace;
    if (child_space.pml4 == parent_space.pml4) return error.ProcessChildAddressSpaceShared;

    try proc.block(child);
    if (proc.runState(child) != .blocked) return error.ProcessChildNotBlocked;
    if (proc.switchTo(child) != error.NoProcess) return error.ProcessSwitchedToBlockedChild;

    try proc.wake(child);
    if (proc.runState(child) != .runnable) return error.ProcessChildNotWoken;

    try proc.switchTo(child);
    if (proc.currentPid() != child) return error.ProcessSwitchDidNotUpdateCurrent;
    if (proc.runState(parent) != .runnable) return error.ProcessParentNotRunnable;
    if (proc.runState(child) != .running) return error.ProcessChildNotRunning;
    if (mm.paging.activeAddressSpace().pml4 != child_space.pml4) return error.ProcessSwitchWrongAddressSpace;
    if (arch.gdt.kernelStackTop() != child_stack_top) return error.ProcessSwitchWrongKernelStack;

    try proc.switchTo(parent);
    if (proc.currentPid() != parent) return error.ProcessSwitchBackFailed;
    if (proc.runState(parent) != .running) return error.ProcessParentNotRunning;
    if (proc.runState(child) != .runnable) return error.ProcessChildNotRunnable;
    if (mm.paging.activeAddressSpace().pml4 != parent_space.pml4) return error.ProcessSwitchBackWrongAddressSpace;

    if (!proc.markExited(child, 0)) return error.ProcessSchedulerChildExitFailed;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    if (waited != child) return error.ProcessSchedulerChildReapFailed;
    if (proc.runState(child) != null) return error.ProcessSchedulerChildSurvivedReap;
}

fn processRunQueue() testing.TestError!void {
    const parent = proc.currentPid();
    if (proc.runnableQueueLen() != 0) return error.ProcessRunQueueDirty;

    const first = try proc.spawnChild(parent);
    const second = try proc.spawnChild(parent);
    var first_reaped = false;
    var second_reaped = false;
    errdefer {
        if (proc.currentPid() != parent) {
            proc.switchTo(parent) catch {};
        }
        if (!first_reaped and proc.runState(first) != null) {
            _ = proc.markExited(first, 1);
            _ = syscall.dispatch.invoke(syscall.numbers.wait4, first, 0, 0, 0, 0, 0);
        }
        if (!second_reaped and proc.runState(second) != null) {
            _ = proc.markExited(second, 1);
            _ = syscall.dispatch.invoke(syscall.numbers.wait4, second, 0, 0, 0, 0, 0);
        }
    }

    if (proc.runnableQueueLen() != 2) return error.ProcessRunQueueSpawnLenWrong;
    if (proc.nextRunnable() != first) return error.ProcessRunQueueSpawnOrderWrong;

    const switched_first = try proc.switchToNext() orelse return error.ProcessRunQueueSwitchMissing;
    if (switched_first != first) return error.ProcessRunQueueSwitchWrongPid;
    if (proc.currentPid() != first) return error.ProcessRunQueueSwitchWrongCurrent;
    if (proc.runState(parent) != .runnable) return error.ProcessRunQueueParentNotQueued;
    if (proc.nextRunnable() != second) return error.ProcessRunQueueSecondNotNext;

    try proc.block(second);
    if (proc.nextRunnable() != parent) return error.ProcessRunQueueBlockDidNotRemove;

    try proc.wake(second);
    if (proc.nextRunnable() != parent) return error.ProcessRunQueueWakeWrongOrder;
    if (proc.runnableQueueLen() != 2) return error.ProcessRunQueueWakeLenWrong;

    const switched_parent = try proc.switchToNext() orelse return error.ProcessRunQueueParentSwitchMissing;
    if (switched_parent != parent) return error.ProcessRunQueueParentSwitchWrongPid;
    if (proc.currentPid() != parent) return error.ProcessRunQueueParentSwitchWrongCurrent;
    if (proc.nextRunnable() != second) return error.ProcessRunQueueWakeDidNotEnqueue;

    if (!proc.markExited(first, 0)) return error.ProcessRunQueueFirstExitFailed;
    var status: i32 = 0;
    const waited_first = syscall.dispatch.invoke(syscall.numbers.wait4, first, @intFromPtr(&status), 0, 0, 0, 0);
    if (waited_first != first) return error.ProcessRunQueueFirstReapFailed;
    first_reaped = true;

    if (!proc.markExited(second, 0)) return error.ProcessRunQueueSecondExitFailed;
    const waited_second = syscall.dispatch.invoke(syscall.numbers.wait4, second, @intFromPtr(&status), 0, 0, 0, 0);
    if (waited_second != second) return error.ProcessRunQueueSecondReapFailed;
    second_reaped = true;
    if (proc.runnableQueueLen() != 0) return error.ProcessRunQueueNotDrained;
}

fn processFdTables() testing.TestError!void {
    const parent = proc.currentPid();
    const path = "/init\x00";
    const cloexec_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), syscall.dispatch.O_CLOEXEC, 0, 0, 0, 0);
    if (cloexec_fd < 3) return error.ProcessFdCloexecOpenFailed;

    const keep_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), 0, 0, 0, 0, 0);
    if (keep_fd < 3) return error.ProcessFdKeepOpenFailed;

    const child = try proc.spawnChild(parent);
    var child_reaped = false;
    errdefer {
        if (proc.currentPid() != parent) {
            proc.switchTo(parent) catch {};
        }
        _ = syscall.dispatch.invoke(syscall.numbers.close, @intCast(cloexec_fd), 0, 0, 0, 0, 0);
        _ = syscall.dispatch.invoke(syscall.numbers.close, @intCast(keep_fd), 0, 0, 0, 0, 0);
        if (!child_reaped and proc.runState(child) != null) {
            _ = proc.markExited(child, 1);
            _ = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
        }
    }

    try proc.switchTo(child);
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(cloexec_fd)) != true) {
        return error.ProcessFdChildDidNotInheritCloexec;
    }
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(keep_fd)) != false) {
        return error.ProcessFdChildDidNotInheritKeepFd;
    }

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(keep_fd), 0, 0, 0, 0, 0) != 0) {
        return error.ProcessFdChildCloseFailed;
    }
    syscall.dispatch.closeOnExecForTest();
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(cloexec_fd)) != null) {
        return error.ProcessFdChildCloexecSurvived;
    }
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(keep_fd)) != null) {
        return error.ProcessFdChildCloseSurvived;
    }

    try proc.switchTo(parent);
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(cloexec_fd)) != true) {
        return error.ProcessFdParentCloexecChanged;
    }
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(keep_fd)) != false) {
        return error.ProcessFdParentKeepChanged;
    }

    var byte: [1]u8 = undefined;
    if (syscall.dispatch.invoke(syscall.numbers.read, @intCast(keep_fd), @intFromPtr(&byte), byte.len, 0, 0, 0) != byte.len) {
        return error.ProcessFdParentReadFailed;
    }
    if (byte[0] != 0x7f) return error.ProcessFdParentReadWrongData;

    if (!proc.markExited(child, 0)) return error.ProcessFdChildExitFailed;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    if (waited != child) return error.ProcessFdChildReapFailed;
    child_reaped = true;

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(cloexec_fd), 0, 0, 0, 0, 0) != 0) {
        return error.ProcessFdParentCloseFailed;
    }
    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(keep_fd), 0, 0, 0, 0, 0) != 0) {
        return error.ProcessFdParentCloseFailed;
    }
}

fn processSpawnResume() testing.TestError!void {
    const parent = proc.currentPid();
    const parent_space = mm.paging.activeAddressSpace();
    const parent_stack_top = proc.kernelStackTop(parent) orelse return error.ProcessParentKernelStackMissing;
    const child = try proc.spawnChild(parent);
    var child_reaped = false;
    errdefer {
        if (proc.currentPid() != parent) {
            proc.switchTo(parent) catch {};
        }
        if (!child_reaped and proc.runState(child) != null) {
            _ = proc.markExited(child, 1);
            _ = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
        }
        proc.finishSpawnResume(parent, child);
    }

    const context = try proc.beginSpawnResume(parent, child);
    try proc.switchTo(child);
    const handoff = proc.exitCurrent(23) orelse return error.ProcessSpawnResumeMissing;
    if (handoff.context != context) return error.ProcessSpawnResumeWrongContext;
    if (handoff.return_value != child) return error.ProcessSpawnResumeWrongPid;
    if (proc.currentPid() != parent) return error.ProcessSpawnResumeWrongCurrent;
    if (proc.runState(parent) != .running) return error.ProcessSpawnResumeParentNotRunning;
    if (proc.runState(child) != .exited) return error.ProcessSpawnResumeChildNotExited;
    if (mm.paging.activeAddressSpace().pml4 != parent_space.pml4) return error.ProcessSpawnResumeWrongAddressSpace;
    if (arch.gdt.kernelStackTop() != parent_stack_top) return error.ProcessSpawnResumeWrongKernelStack;

    proc.finishSpawnResume(parent, child);
    var status: i32 = 0;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, @intFromPtr(&status), 0, 0, 0, 0);
    if (waited != child) return error.ProcessSpawnResumeWaitFailed;
    if (status != 23 << 8) return error.ProcessSpawnResumeStatusWrong;
    child_reaped = true;
}

fn spawnChildImage() testing.TestError!void {
    if (proc.currentRegionCount() != 0) return error.SpawnParentRegionRegistryDirty;

    const child = try proc.spawnChild(proc.currentPid());
    errdefer {
        elf.loader.releaseProcessPages(child);
        _ = proc.markExited(child, 1);
        _ = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    }
    const inode = fs.vfs.lookup("/exec-ok") catch return error.SpawnImageMissing;

    var segments: [8]elf.parse.Segment = undefined;
    const arg0 = "/exec-ok";
    const arg1 = "spawn-test";
    const env0 = "ZIGIX_SPAWN=1";
    const argv = [_][]const u8{ arg0, arg1 };
    const envp = [_][]const u8{env0};
    const image = try elf.loader.loadStaticUserForProcess(child, inode.data, &segments, .{
        .argv = &argv,
        .envp = &envp,
    });
    if (image.entry == 0 or image.stack_top == 0) return error.SpawnImageLoadInvalid;
    if (proc.currentRegionCount() != 0) return error.SpawnLoadRegisteredParentRegion;
    if (proc.regionCount(child) == 0) return error.SpawnLoadDidNotRegisterChildRegions;
    if (mm.paging.walk(image.entry) != null) return error.SpawnLoadMappedParentImage;

    const child_space = proc.addressSpace(child) orelse return error.SpawnMissingAddressSpace;
    if (mm.paging.walkIn(child_space, image.entry) == null) return error.SpawnChildEntryMappingMissing;
    if (mm.paging.walkIn(child_space, image.stack_top - @sizeOf(usize)) == null) {
        return error.SpawnChildStackMappingMissing;
    }

    elf.loader.releaseProcessPages(child);
    if (proc.regionCount(child) != 0) return error.SpawnReleaseLeftChildRegions;
    if (proc.currentRegionCount() != 0) return error.SpawnReleaseChangedParentRegions;

    if (!proc.markExited(child, 0)) return error.SpawnChildExitFailed;
    const waited = syscall.dispatch.invoke(syscall.numbers.wait4, child, 0, 0, 0, 0, 0);
    if (waited != child) return error.SpawnChildReapFailed;
}

fn posixSpawnHandoff() testing.TestError!void {
    if (proc.currentRegionCount() != 0) return error.PosixSpawnParentRegionRegistryDirty;

    const path = "/exec-ok\x00";
    const arg0 = "/exec-ok\x00";
    const arg1 = "spawn-handoff\x00";
    const env0 = "ZIGIX_SPAWN=handoff\x00";
    const argv = [_]u64{ @intFromPtr(arg0.ptr), @intFromPtr(arg1.ptr), 0 };
    const envp = [_]u64{ @intFromPtr(env0.ptr), 0 };

    const prepared = syscall.dispatch.preparePosixSpawnForTest(
        @intFromPtr(path.ptr),
        @intFromPtr(&argv),
        @intFromPtr(&envp),
    ) orelse return error.PosixSpawnPrepareFailed;
    defer syscall.dispatch.cleanupPreparedSpawnForTest(prepared.pid);

    if (prepared.entry == 0 or prepared.stack_top == 0) return error.PosixSpawnImageInvalid;
    if (proc.currentRegionCount() != 0) return error.PosixSpawnRegisteredParentRegion;
    if (proc.regionCount(prepared.pid) == 0) return error.PosixSpawnChildRegionsMissing;
    if (mm.paging.walk(prepared.entry) != null) return error.PosixSpawnMappedParentImage;

    const child_space = proc.addressSpace(prepared.pid) orelse return error.PosixSpawnMissingAddressSpace;
    if (mm.paging.walkIn(child_space, prepared.entry) == null) return error.PosixSpawnChildEntryMissing;
    if (mm.paging.walkIn(child_space, prepared.stack_top - @sizeOf(usize)) == null) {
        return error.PosixSpawnChildStackMissing;
    }

    const missing = "/missing\x00";
    if (syscall.dispatch.invoke(syscall.numbers.posix_spawn, @intFromPtr(missing.ptr), 0, 0, 0, 0, 0) != -syscall.errno.NOENT) {
        return error.PosixSpawnMissingPathWrongErrno;
    }
}

fn execveLoad() testing.TestError!void {
    const path = "/init\x00";
    const exec_path = "/exec-ok";
    const cloexec_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), syscall.dispatch.O_CLOEXEC, 0, 0, 0, 0);
    if (cloexec_fd < 3) return error.ExecveCloexecOpenFailed;

    const keep_fd = syscall.dispatch.invoke(syscall.numbers.open, @intFromPtr(path.ptr), 0, 0, 0, 0, 0);
    if (keep_fd < 3) return error.ExecveOpenFailed;

    if (!syscall.dispatch.execvePlanForTest(exec_path)) return error.ExecvePlanFailed;

    syscall.dispatch.closeOnExecForTest();
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(cloexec_fd)) != null) {
        return error.ExecveCloexecFdSurvived;
    }
    if (syscall.dispatch.fdCloseOnExecForTest(@intCast(keep_fd)) != false) {
        return error.ExecveClosedPlainFd;
    }

    if (syscall.dispatch.invoke(syscall.numbers.close, @intCast(keep_fd), 0, 0, 0, 0, 0) != 0) {
        return error.ExecveCloseFailed;
    }

    var too_many: [9]u64 = undefined;
    const arg = "arg\x00";
    for (&too_many) |*slot| slot.* = @intFromPtr(arg.ptr);
    if (syscall.dispatch.execArgsForTest(@intFromPtr(&too_many), 0)) |_| {
        return error.ExecveAcceptedTooManyArgs;
    } else |err| {
        if (err != error.TooMany) return error.ExecveWrongArgError;
    }
}

fn execveArgvStack() testing.TestError!void {
    const arg0 = "/exec-ok\x00";
    const arg1 = "argv-ok\x00";
    const env0 = "ZIGIX_PHASE=10\x00";
    const argv = [_]u64{ @intFromPtr(arg0.ptr), @intFromPtr(arg1.ptr), 0 };
    const envp = [_]u64{ @intFromPtr(env0.ptr), 0 };

    const args = try syscall.dispatch.execArgsForTest(@intFromPtr(&argv), @intFromPtr(&envp));
    var argv_slices: [8][]const u8 = undefined;
    var envp_slices: [8][]const u8 = undefined;
    @memset(exec_stack_test_buffer[0..], 0);
    const base: usize = 0x1000;
    const sp = try elf.loader.buildInitialStackForTest(&exec_stack_test_buffer, base, .{
        .argv = args.argv(&argv_slices),
        .envp = args.envp(&envp_slices),
    });
    if (sp < base or sp >= base + exec_stack_test_buffer.len) return error.ExecveStackPointerOutOfRange;

    const offset = sp - base;
    if (readStackWord(&exec_stack_test_buffer, offset + 0 * @sizeOf(usize)) != 2) return error.ExecveArgcWrong;
    const argv0_ptr = readStackWord(&exec_stack_test_buffer, offset + 1 * @sizeOf(usize));
    const argv1_ptr = readStackWord(&exec_stack_test_buffer, offset + 2 * @sizeOf(usize));
    if (readStackWord(&exec_stack_test_buffer, offset + 3 * @sizeOf(usize)) != 0) return error.ExecveArgvMissingNull;
    const env0_ptr = readStackWord(&exec_stack_test_buffer, offset + 4 * @sizeOf(usize));
    if (readStackWord(&exec_stack_test_buffer, offset + 5 * @sizeOf(usize)) != 0) return error.ExecveEnvpMissingNull;

    if (!stackCStringEquals(&exec_stack_test_buffer, base, argv0_ptr, "/exec-ok")) return error.ExecveArgv0Wrong;
    if (!stackCStringEquals(&exec_stack_test_buffer, base, argv1_ptr, "argv-ok")) return error.ExecveArgv1Wrong;
    if (!stackCStringEquals(&exec_stack_test_buffer, base, env0_ptr, "ZIGIX_PHASE=10")) return error.ExecveEnv0Wrong;
}

fn elfStaticLoader() testing.TestError!void {
    if (!elf.selfTestStaticLoaderMarker()) return error.ElfStaticLoaderFailed;
}

fn direntName(bytes: []const u8) ?[]const u8 {
    for (bytes, 0..) |byte, index| {
        if (byte == 0) return bytes[0..index];
    }
    return null;
}

fn readLeU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readLeI64(bytes: []const u8) i64 {
    var value: u64 = 0;
    var index: usize = 0;
    while (index < 8) : (index += 1) {
        value |= @as(u64, bytes[index]) << @intCast(index * 8);
    }
    return @bitCast(value);
}

fn readStackWord(stack: []const u8, offset: usize) usize {
    var value: usize = 0;
    var index: usize = 0;
    while (index < @sizeOf(usize)) : (index += 1) {
        const shift: std.math.Log2Int(usize) = @intCast(index * 8);
        value |= @as(usize, stack[offset + index]) << shift;
    }
    return value;
}

fn stackCStringEquals(stack: []const u8, base: usize, ptr: usize, expected: []const u8) bool {
    if (ptr < base) return false;
    const offset = ptr - base;
    if (offset + expected.len >= stack.len) return false;
    if (!std.mem.eql(u8, stack[offset .. offset + expected.len], expected)) return false;
    return stack[offset + expected.len] == 0;
}
