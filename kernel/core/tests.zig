//! Canonical early kernel tests.

const arch = @import("arch");
const serial = arch.serial;

const mm = @import("mm");
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
