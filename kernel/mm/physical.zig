//! Early physical page-frame allocator.
//!
//! The Phase 1 boot page table identity-maps the first 1 GiB, so this
//! allocator deliberately tracks only that range for now.

const multiboot = @import("multiboot");

pub const PAGE_SIZE: usize = 4096;
const ONE_MIB: u64 = 1024 * 1024;
const MAX_TRACKED_PHYS: u64 = 1024 * 1024 * 1024;
const FRAME_COUNT: usize = @intCast(MAX_TRACKED_PHYS / PAGE_SIZE);
const BITMAP_BYTES = FRAME_COUNT / 8;

extern const __kernel_start: u8;
extern const __kernel_end: u8;

pub const Error = error{
    OutOfMemory,
};

pub const Stats = struct {
    usable_bytes: u64,
    tracked_free_pages: usize,
    total_pages: usize,
};

var page_bitmap: [BITMAP_BYTES]u8 = [_]u8{0xff} ** BITMAP_BYTES;
var stats: Stats = .{
    .usable_bytes = 0,
    .tracked_free_pages = 0,
    .total_pages = FRAME_COUNT,
};
var initialized = false;

pub fn initFromMultiboot(info: *const multiboot.Info) Stats {
    @memset(page_bitmap[0..], 0xff);
    stats = .{
        .usable_bytes = 0,
        .tracked_free_pages = 0,
        .total_pages = FRAME_COUNT,
    };

    var it = multiboot.mmapIterator(info);
    while (it.next()) |entry| {
        if (entry.typ != .usable or entry.length == 0) continue;
        stats.usable_bytes += entry.length;
        releaseUsableRange(entry.base, entry.length);
    }

    reserveRange(0, ONE_MIB);
    reserveRange(kernelStart(), kernelEnd() - kernelStart());
    reserveMultibootInfo(info);

    stats.tracked_free_pages = countFreePages();
    initialized = true;
    return stats;
}

pub fn allocPage() Error!usize {
    if (!initialized) return error.OutOfMemory;

    for (page_bitmap[0..], 0..) |byte, byte_index| {
        if (byte == 0xff) continue;
        var bit: usize = 0;
        while (bit < 8) : (bit += 1) {
            const bit_index: u3 = @intCast(bit);
            const mask: u8 = @as(u8, 1) << bit_index;
            if ((byte & mask) == 0) {
                const frame = byte_index * 8 + bit;
                setUsed(frame);
                stats.tracked_free_pages -= 1;
                return frame * PAGE_SIZE;
            }
        }
    }

    return error.OutOfMemory;
}

pub fn freePage(addr: usize) void {
    if (!initialized or addr % PAGE_SIZE != 0) return;
    const frame = addr / PAGE_SIZE;
    if (frame >= FRAME_COUNT or isFree(frame)) return;
    setFree(frame);
    stats.tracked_free_pages += 1;
}

pub fn isPageFree(addr: usize) bool {
    if (addr % PAGE_SIZE != 0) return false;
    const frame = addr / PAGE_SIZE;
    if (frame >= FRAME_COUNT) return false;
    return isFree(frame);
}

pub fn currentStats() Stats {
    return stats;
}

pub fn kernelStart() u64 {
    return @intFromPtr(&__kernel_start);
}

pub fn kernelEnd() u64 {
    return @intFromPtr(&__kernel_end);
}

fn reserveMultibootInfo(info: *const multiboot.Info) void {
    reserveRange(@intFromPtr(info), @sizeOf(multiboot.Info));
    reserveRange(info.mmap_addr, info.mmap_length);

    if (info.mods_count != 0 and info.mods_addr != 0) {
        reserveRange(info.mods_addr, @as(u64, info.mods_count) * 16);
        var modules = multiboot.moduleIterator(info);
        while (modules.next()) |module| {
            if (module.mod_end > module.mod_start) {
                reserveRange(module.mod_start, module.mod_end - module.mod_start);
            }
        }
    }
}

fn releaseUsableRange(base: u64, length: u64) void {
    const start = alignForward(base, PAGE_SIZE);
    const end = alignBackward(saturatingAdd(base, length), PAGE_SIZE);
    if (end <= start) return;

    var addr = start;
    while (addr < end and addr < MAX_TRACKED_PHYS) : (addr += PAGE_SIZE) {
        setFree(@intCast(addr / PAGE_SIZE));
    }
}

pub fn reserveRange(base: u64, length: u64) void {
    const start = alignBackward(base, PAGE_SIZE);
    const end = alignForward(saturatingAdd(base, length), PAGE_SIZE);
    if (end <= start) return;

    var addr = start;
    while (addr < end and addr < MAX_TRACKED_PHYS) : (addr += PAGE_SIZE) {
        setUsed(@intCast(addr / PAGE_SIZE));
    }
}

fn countFreePages() usize {
    var count: usize = 0;
    for (0..FRAME_COUNT) |frame| {
        if (isFree(frame)) count += 1;
    }
    return count;
}

fn isFree(frame: usize) bool {
    const byte_index = frame / 8;
    const bit: u3 = @intCast(frame % 8);
    return (page_bitmap[byte_index] & (@as(u8, 1) << bit)) == 0;
}

fn setFree(frame: usize) void {
    const byte_index = frame / 8;
    const bit: u3 = @intCast(frame % 8);
    page_bitmap[byte_index] &= ~(@as(u8, 1) << bit);
}

fn setUsed(frame: usize) void {
    const byte_index = frame / 8;
    const bit: u3 = @intCast(frame % 8);
    page_bitmap[byte_index] |= @as(u8, 1) << bit;
}

fn alignForward(value: u64, comptime alignment: usize) u64 {
    const mask = @as(u64, alignment - 1);
    return (value + mask) & ~mask;
}

fn alignBackward(value: u64, comptime alignment: usize) u64 {
    const mask = @as(u64, alignment - 1);
    return value & ~mask;
}

fn saturatingAdd(a: u64, b: u64) u64 {
    const result, const overflow = @addWithOverflow(a, b);
    return if (overflow != 0) MAX_TRACKED_PHYS else result;
}
