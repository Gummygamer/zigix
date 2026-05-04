//! Multiboot1 handoff structures and early validation.

pub const MAGIC: u32 = 0x2BADB002;

const FLAG_MEM = 1 << 0;
const FLAG_MMAP = 1 << 6;

pub const Error = error{
    BadMagic,
    MissingInfo,
    MissingBasicMemory,
    MissingMemoryMap,
};

pub const Info = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    syms0: u32,
    syms1: u32,
    syms2: u32,
    syms3: u32,
    mmap_length: u32,
    mmap_addr: u32,
    drives_length: u32,
    drives_addr: u32,
    config_table: u32,
    boot_loader_name: u32,
    apm_table: u32,
    vbe_control_info: u32,
    vbe_mode_info: u32,
    vbe_mode: u16,
    vbe_interface_seg: u16,
    vbe_interface_off: u16,
    vbe_interface_len: u16,

    pub fn hasBasicMemory(self: *const Info) bool {
        return (self.flags & FLAG_MEM) != 0;
    }

    pub fn hasMemoryMap(self: *const Info) bool {
        return (self.flags & FLAG_MMAP) != 0 and self.mmap_addr != 0 and self.mmap_length != 0;
    }
};

pub const MmapType = enum(u32) {
    usable = 1,
    reserved = 2,
    acpi_reclaimable = 3,
    acpi_nvs = 4,
    bad = 5,
    _,
};

const MmapEntryRaw = extern struct {
    size: u32,
    base_addr_low: u32,
    base_addr_high: u32,
    length_low: u32,
    length_high: u32,
    typ: u32,
};

pub const MmapEntry = struct {
    base: u64,
    length: u64,
    typ: MmapType,
};

pub const MmapIterator = struct {
    cursor: usize,
    end: usize,

    pub fn next(self: *MmapIterator) ?MmapEntry {
        if (self.cursor >= self.end) return null;

        const raw: *const MmapEntryRaw = @ptrFromInt(self.cursor);
        if (raw.size < 20) {
            self.cursor = self.end;
            return null;
        }

        const entry = MmapEntry{
            .base = (@as(u64, raw.base_addr_high) << 32) | raw.base_addr_low,
            .length = (@as(u64, raw.length_high) << 32) | raw.length_low,
            .typ = @enumFromInt(raw.typ),
        };
        self.cursor += @as(usize, raw.size) + @sizeOf(u32);
        if (self.cursor > self.end) self.cursor = self.end;
        return entry;
    }
};

pub fn validate(magic: u64, info_ptr: u64) Error!*const Info {
    if (@as(u32, @truncate(magic)) != MAGIC) return error.BadMagic;
    if (info_ptr == 0) return error.MissingInfo;

    const info: *const Info = @ptrFromInt(@as(usize, @intCast(info_ptr)));
    if (!info.hasBasicMemory()) return error.MissingBasicMemory;
    if (!info.hasMemoryMap()) return error.MissingMemoryMap;
    return info;
}

pub fn mmapIterator(info: *const Info) MmapIterator {
    const start: usize = @intCast(info.mmap_addr);
    return .{
        .cursor = start,
        .end = start + @as(usize, @intCast(info.mmap_length)),
    };
}
