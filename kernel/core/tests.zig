//! Canonical early kernel tests.

const std = @import("std");

const arch = @import("arch");
const serial = arch.serial;

const elf = @import("elf");
const mm = @import("mm");
const proc = @import("proc");
const syscall = @import("syscall");
const testing = @import("testing.zig");

var exec_stack_test_buffer: [512]u8 = [_]u8{0} ** 512;

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

pub const TEST_syscall_pipe = testing.Test{
    .name = "syscall_pipe",
    .run = syscallPipe,
};

pub const TEST_process_lifecycle = testing.Test{
    .name = "process_lifecycle",
    .run = processLifecycle,
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
