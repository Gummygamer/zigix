//! Canonical early kernel tests.

const std = @import("std");

const arch = @import("arch");
const serial = arch.serial;

const elf = @import("elf");
const mm = @import("mm");
const syscall = @import("syscall");
const testing = @import("testing.zig");

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

fn elfStaticLoader() testing.TestError!void {
    if (!elf.selfTestStaticLoaderMarker()) return error.ElfStaticLoaderFailed;
}
