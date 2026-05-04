//! Minimal x86_64 page-table walker for the boot address space.

const arch = @import("arch");
const cpu = arch.cpu;
const physical = @import("physical.zig");

const PRESENT: u64 = 1 << 0;
const WRITABLE: u64 = 1 << 1;
const HUGE: u64 = 1 << 7;
const ADDR_MASK: u64 = 0x000f_ffff_ffff_f000;

const PAGE_4K: usize = 4096;
const PAGE_2M: usize = 2 * 1024 * 1024;
const PAGE_1G: usize = 1024 * 1024 * 1024;

pub const MapError = error{
    AlreadyMapped,
    NotAligned,
    NotMapped,
    OutOfMemory,
    Unsupported,
};

pub const Mapping = struct {
    physical: usize,
    page_size: usize,
    writable: bool,
};

pub fn walk(virtual_addr: usize) ?Mapping {
    const pml4: [*]const u64 = @ptrFromInt(cpu.readCr3() & ~@as(usize, 0xfff));
    const pml4e = pml4[pml4Index(virtual_addr)];
    if ((pml4e & PRESENT) == 0) return null;

    const pdpt: [*]const u64 = @ptrFromInt(@as(usize, @intCast(pml4e & 0x000f_ffff_ffff_f000)));
    const pdpte = pdpt[pdptIndex(virtual_addr)];
    if ((pdpte & PRESENT) == 0) return null;
    if ((pdpte & HUGE) != 0) {
        return .{
            .physical = @as(usize, @intCast(pdpte & 0x000f_ffff_c000_0000)) + (virtual_addr & (PAGE_1G - 1)),
            .page_size = PAGE_1G,
            .writable = (pdpte & WRITABLE) != 0,
        };
    }

    const pd: [*]const u64 = @ptrFromInt(@as(usize, @intCast(pdpte & 0x000f_ffff_ffff_f000)));
    const pde = pd[pdIndex(virtual_addr)];
    if ((pde & PRESENT) == 0) return null;
    if ((pde & HUGE) != 0) {
        return .{
            .physical = @as(usize, @intCast(pde & 0x000f_ffff_ffe0_0000)) + (virtual_addr & (PAGE_2M - 1)),
            .page_size = PAGE_2M,
            .writable = (pde & WRITABLE) != 0,
        };
    }

    const pt: [*]const u64 = @ptrFromInt(@as(usize, @intCast(pde & 0x000f_ffff_ffff_f000)));
    const pte = pt[ptIndex(virtual_addr)];
    if ((pte & PRESENT) == 0) return null;
    return .{
        .physical = @as(usize, @intCast(pte & 0x000f_ffff_ffff_f000)) + (virtual_addr & (PAGE_4K - 1)),
        .page_size = PAGE_4K,
        .writable = (pte & WRITABLE) != 0,
    };
}

pub fn mapPage(virtual_addr: usize, physical_addr: usize, writable: bool) MapError!void {
    if (virtual_addr % PAGE_4K != 0 or physical_addr % PAGE_4K != 0) {
        return error.NotAligned;
    }

    const pml4 = activePml4();
    const pdpt = try ensureChildTable(&pml4[pml4Index(virtual_addr)]);
    const pd = try ensureChildTable(&pdpt[pdptIndex(virtual_addr)]);
    const pde = &pd[pdIndex(virtual_addr)];
    if ((pde.* & HUGE) != 0) return error.Unsupported;

    const pt = try ensureChildTable(pde);
    const pte = &pt[ptIndex(virtual_addr)];
    if ((pte.* & PRESENT) != 0) return error.AlreadyMapped;

    pte.* = @as(u64, physical_addr) | PRESENT | if (writable) WRITABLE else 0;
}

pub fn unmapPage(virtual_addr: usize) MapError!void {
    if (virtual_addr % PAGE_4K != 0) return error.NotAligned;

    const pml4 = activePml4();
    const pml4e = pml4[pml4Index(virtual_addr)];
    if ((pml4e & PRESENT) == 0) return error.NotMapped;

    const pdpt = tableFromEntry(pml4e);
    const pdpte = pdpt[pdptIndex(virtual_addr)];
    if ((pdpte & PRESENT) == 0 or (pdpte & HUGE) != 0) return error.NotMapped;

    const pd = tableFromEntry(pdpte);
    const pde = pd[pdIndex(virtual_addr)];
    if ((pde & PRESENT) == 0 or (pde & HUGE) != 0) return error.NotMapped;

    const pt = tableFromEntry(pde);
    const pte = &pt[ptIndex(virtual_addr)];
    if ((pte.* & PRESENT) == 0) return error.NotMapped;

    pte.* = 0;
    invalidatePage(virtual_addr);
}

fn activePml4() [*]u64 {
    return @ptrFromInt(cpu.readCr3() & ~@as(usize, 0xfff));
}

fn ensureChildTable(entry: *u64) MapError![*]u64 {
    if ((entry.* & PRESENT) != 0) {
        if ((entry.* & HUGE) != 0) return error.Unsupported;
        return tableFromEntry(entry.*);
    }

    const page = physical.allocPage() catch return error.OutOfMemory;
    @memset(pageBytes(page), 0);
    entry.* = @as(u64, page) | PRESENT | WRITABLE;
    return @ptrFromInt(page);
}

fn tableFromEntry(entry: u64) [*]u64 {
    return @ptrFromInt(@as(usize, @intCast(entry & ADDR_MASK)));
}

fn pageBytes(addr: usize) []u8 {
    const bytes: [*]u8 = @ptrFromInt(addr);
    return bytes[0..PAGE_4K];
}

fn invalidatePage(addr: usize) void {
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (addr),
    );
}

fn pml4Index(addr: usize) usize {
    return (addr >> 39) & 0x1ff;
}

fn pdptIndex(addr: usize) usize {
    return (addr >> 30) & 0x1ff;
}

fn pdIndex(addr: usize) usize {
    return (addr >> 21) & 0x1ff;
}

fn ptIndex(addr: usize) usize {
    return (addr >> 12) & 0x1ff;
}
