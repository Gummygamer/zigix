//! Minimal x86_64 page-table walker for the boot address space.

const arch = @import("arch");
const cpu = arch.cpu;
const physical = @import("physical.zig");

const PRESENT: u64 = 1 << 0;
const WRITABLE: u64 = 1 << 1;
const USER: u64 = 1 << 2;
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

pub const AddressSpace = struct {
    pml4: usize,
};

pub fn walk(virtual_addr: usize) ?Mapping {
    return walkIn(activeAddressSpace(), virtual_addr);
}

pub fn walkIn(space: AddressSpace, virtual_addr: usize) ?Mapping {
    const pml4: [*]const u64 = @ptrFromInt(space.pml4);
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
    return mapPageInternal(activeAddressSpace(), virtual_addr, physical_addr, .{
        .writable = writable,
        .user = false,
    });
}

pub fn mapUserPage(virtual_addr: usize, physical_addr: usize, writable: bool) MapError!void {
    return mapUserPageIn(activeAddressSpace(), virtual_addr, physical_addr, writable);
}

pub fn mapUserPageIn(space: AddressSpace, virtual_addr: usize, physical_addr: usize, writable: bool) MapError!void {
    return mapPageInternal(space, virtual_addr, physical_addr, .{
        .writable = writable,
        .user = true,
    });
}

const MapOptions = struct {
    writable: bool,
    user: bool,
};

fn mapPageInternal(space: AddressSpace, virtual_addr: usize, physical_addr: usize, options: MapOptions) MapError!void {
    if (virtual_addr % PAGE_4K != 0 or physical_addr % PAGE_4K != 0) {
        return error.NotAligned;
    }

    const pml4 = pml4FromAddressSpace(space);
    const pdpt = try ensureChildTable(&pml4[pml4Index(virtual_addr)], options.user);
    const pd = try ensureChildTable(&pdpt[pdptIndex(virtual_addr)], options.user);
    const pde = &pd[pdIndex(virtual_addr)];
    if ((pde.* & HUGE) != 0) return error.Unsupported;

    const pt = try ensureChildTable(pde, options.user);
    const pte = &pt[ptIndex(virtual_addr)];
    if ((pte.* & PRESENT) != 0) return error.AlreadyMapped;

    pte.* = @as(u64, physical_addr) | entryFlags(options);
}

pub fn unmapPage(virtual_addr: usize) MapError!void {
    return unmapPageIn(activeAddressSpace(), virtual_addr);
}

pub fn unmapPageIn(space: AddressSpace, virtual_addr: usize) MapError!void {
    if (virtual_addr % PAGE_4K != 0) return error.NotAligned;

    const pml4 = pml4FromAddressSpace(space);
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
    if (space.pml4 == activeAddressSpace().pml4) invalidatePage(virtual_addr);
}

pub fn activeAddressSpace() AddressSpace {
    return .{ .pml4 = cpu.readCr3() & ~@as(usize, 0xfff) };
}

pub fn switchAddressSpace(space: AddressSpace) void {
    cpu.writeCr3(space.pml4);
}

pub fn createUserAddressSpace() MapError!AddressSpace {
    const source_pml4 = pml4FromAddressSpace(activeAddressSpace());
    const source_pml4e = source_pml4[0];
    if ((source_pml4e & PRESENT) == 0 or (source_pml4e & HUGE) != 0) return error.Unsupported;

    const pml4_page = physical.allocPage() catch return error.OutOfMemory;
    @memset(pageBytes(pml4_page), 0);
    errdefer physical.freePage(pml4_page);

    const pdpt_page = physical.allocPage() catch return error.OutOfMemory;
    @memset(pageBytes(pdpt_page), 0);
    errdefer physical.freePage(pdpt_page);

    const new_pml4 = pml4FromAddressSpace(.{ .pml4 = pml4_page });
    const new_pdpt: [*]u64 = @ptrFromInt(pdpt_page);
    const source_pdpt = tableFromEntry(source_pml4e);

    new_pdpt[0] = source_pdpt[0];
    new_pml4[0] = @as(u64, pdpt_page) | PRESENT | WRITABLE;

    var index: usize = 1;
    while (index < 512) : (index += 1) {
        new_pml4[index] = source_pml4[index];
    }

    return .{ .pml4 = pml4_page };
}

pub fn destroyUserAddressSpace(space: AddressSpace) void {
    if (space.pml4 == activeAddressSpace().pml4) return;

    const pml4 = pml4FromAddressSpace(space);
    const pml4e0 = pml4[0];
    if ((pml4e0 & PRESENT) != 0 and (pml4e0 & HUGE) == 0) {
        const pdpt = tableFromEntryOrNull(pml4e0) orelse {
            physical.freePage(space.pml4);
            return;
        };
        var pdpt_index: usize = 1;
        while (pdpt_index < 512) : (pdpt_index += 1) {
            const pdpte = pdpt[pdpt_index];
            if ((pdpte & PRESENT) == 0 or (pdpte & HUGE) != 0) continue;
            const pd = tableFromEntryOrNull(pdpte) orelse continue;
            var pd_index: usize = 0;
            while (pd_index < 512) : (pd_index += 1) {
                const pde = pd[pd_index];
                if ((pde & PRESENT) == 0 or (pde & HUGE) != 0) continue;
                const pt = tableFromEntryOrNull(pde) orelse continue;
                physical.freePage(@intFromPtr(pt));
            }
            physical.freePage(@intFromPtr(pd));
        }
        physical.freePage(@intFromPtr(pdpt));
    }
    physical.freePage(space.pml4);
}

fn pml4FromAddressSpace(space: AddressSpace) [*]u64 {
    return @ptrFromInt(space.pml4);
}

fn ensureChildTable(entry: *u64, user: bool) MapError![*]u64 {
    if ((entry.* & PRESENT) != 0) {
        if ((entry.* & HUGE) != 0) return error.Unsupported;
        if (user) entry.* |= USER;
        return tableFromEntry(entry.*);
    }

    const page = physical.allocPage() catch return error.OutOfMemory;
    @memset(pageBytes(page), 0);
    entry.* = @as(u64, page) | PRESENT | WRITABLE | if (user) USER else 0;
    return @ptrFromInt(page);
}

fn entryFlags(options: MapOptions) u64 {
    var flags = PRESENT;
    if (options.writable) flags |= WRITABLE;
    if (options.user) flags |= USER;
    return flags;
}

fn tableFromEntry(entry: u64) [*]u64 {
    return @ptrFromInt(@as(usize, @intCast(entry & ADDR_MASK)));
}

fn tableFromEntryOrNull(entry: u64) ?[*]u64 {
    const addr: usize = @intCast(entry & ADDR_MASK);
    if (addr == 0) return null;
    return @ptrFromInt(addr);
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
