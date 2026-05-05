//! Pure ELF64 parser for the static loader.

const std = @import("std");

pub const ELF_HEADER_SIZE: usize = 64;
pub const PROGRAM_HEADER_SIZE: usize = 56;

pub const ET_EXEC: u16 = 2;
pub const EM_X86_64: u16 = 62;

const PT_LOAD: u32 = 1;
const PT_INTERP: u32 = 3;

const PF_X: u32 = 1 << 0;
const PF_W: u32 = 1 << 1;
const PF_R: u32 = 1 << 2;

pub const Error = error{
    TruncatedHeader,
    BadMagic,
    UnsupportedClass,
    UnsupportedEndian,
    UnsupportedVersion,
    UnsupportedType,
    UnsupportedMachine,
    UnsupportedHeaderSize,
    InvalidProgramHeaderTable,
    UnsupportedProgramHeader,
    TooManySegments,
    NoLoadSegments,
    InvalidSegment,
    SegmentPastEof,
    SegmentOverlap,
};

pub const SegmentFlags = struct {
    read: bool,
    write: bool,
    execute: bool,
};

pub const Segment = struct {
    offset: u64,
    virtual_address: u64,
    physical_address: u64,
    file_size: u64,
    memory_size: u64,
    flags: SegmentFlags,
    alignment: u64,

    pub fn fileBytes(self: Segment, image: []const u8) Error![]const u8 {
        const start = toUsize(self.offset) orelse return error.SegmentPastEof;
        const len = toUsize(self.file_size) orelse return error.SegmentPastEof;
        const end = checkedEnd(start, len, image.len) orelse return error.SegmentPastEof;
        return image[start..end];
    }
};

pub const Image = struct {
    entry: u64,
    segments: []const Segment,
};

pub fn parse(image: []const u8, segment_buffer: []Segment) Error!Image {
    if (image.len < ELF_HEADER_SIZE) return error.TruncatedHeader;
    if (!std.mem.eql(u8, image[0..4], "\x7fELF")) return error.BadMagic;
    if (image[4] != 2) return error.UnsupportedClass;
    if (image[5] != 1) return error.UnsupportedEndian;
    if (image[6] != 1) return error.UnsupportedVersion;

    if (readU16(image, 16) != ET_EXEC) return error.UnsupportedType;
    if (readU16(image, 18) != EM_X86_64) return error.UnsupportedMachine;
    if (readU32(image, 20) != 1) return error.UnsupportedVersion;

    const entry = readU64(image, 24);
    const phoff = readU64(image, 32);
    const ehsize = readU16(image, 52);
    const phentsize = readU16(image, 54);
    const phnum = readU16(image, 56);

    if (ehsize != ELF_HEADER_SIZE) return error.UnsupportedHeaderSize;
    if (phentsize != PROGRAM_HEADER_SIZE) return error.UnsupportedHeaderSize;

    const phoff_usize = toUsize(phoff) orelse return error.InvalidProgramHeaderTable;
    const phnum_usize: usize = phnum;
    const ph_table_size = checkedMul(PROGRAM_HEADER_SIZE, phnum_usize) orelse return error.InvalidProgramHeaderTable;
    _ = checkedEnd(phoff_usize, ph_table_size, image.len) orelse return error.InvalidProgramHeaderTable;

    var segment_count: usize = 0;
    var index: usize = 0;
    while (index < phnum_usize) : (index += 1) {
        const ph = image[phoff_usize + index * PROGRAM_HEADER_SIZE ..][0..PROGRAM_HEADER_SIZE];
        const header_type = readU32(ph, 0);
        switch (header_type) {
            PT_LOAD => {
                if (segment_count == segment_buffer.len) return error.TooManySegments;

                const flags_raw = readU32(ph, 4);
                const offset = readU64(ph, 8);
                const vaddr = readU64(ph, 16);
                const paddr = readU64(ph, 24);
                const filesz = readU64(ph, 32);
                const memsz = readU64(ph, 40);
                const alignment = readU64(ph, 48);

                try validateLoadSegment(image, offset, vaddr, filesz, memsz, alignment);
                try rejectVirtualOverlap(segment_buffer[0..segment_count], vaddr, memsz);

                segment_buffer[segment_count] = .{
                    .offset = offset,
                    .virtual_address = vaddr,
                    .physical_address = paddr,
                    .file_size = filesz,
                    .memory_size = memsz,
                    .flags = .{
                        .read = (flags_raw & PF_R) != 0,
                        .write = (flags_raw & PF_W) != 0,
                        .execute = (flags_raw & PF_X) != 0,
                    },
                    .alignment = alignment,
                };
                segment_count += 1;
            },
            PT_INTERP => return error.UnsupportedProgramHeader,
            else => {},
        }
    }

    if (segment_count == 0) return error.NoLoadSegments;
    return .{
        .entry = entry,
        .segments = segment_buffer[0..segment_count],
    };
}

fn validateLoadSegment(image: []const u8, offset: u64, vaddr: u64, filesz: u64, memsz: u64, alignment: u64) Error!void {
    if (filesz > memsz) return error.InvalidSegment;
    if (memsz == 0) return error.InvalidSegment;
    if (alignment != 0 and !isPowerOfTwo(alignment)) return error.InvalidSegment;
    if (alignment > 1 and (offset % alignment) != (vaddr % alignment)) return error.InvalidSegment;

    const offset_usize = toUsize(offset) orelse return error.SegmentPastEof;
    const file_size_usize = toUsize(filesz) orelse return error.SegmentPastEof;
    _ = checkedEnd(offset_usize, file_size_usize, image.len) orelse return error.SegmentPastEof;

    _ = checkedAdd(vaddr, memsz) orelse return error.InvalidSegment;
}

fn rejectVirtualOverlap(existing: []const Segment, vaddr: u64, memsz: u64) Error!void {
    const end = checkedAdd(vaddr, memsz) orelse return error.InvalidSegment;
    for (existing) |segment| {
        const other_end = checkedAdd(segment.virtual_address, segment.memory_size) orelse return error.InvalidSegment;
        if (vaddr < other_end and segment.virtual_address < end) return error.SegmentOverlap;
    }
}

fn checkedEnd(start: usize, len: usize, total: usize) ?usize {
    if (start > total) return null;
    if (len > total - start) return null;
    return start + len;
}

fn checkedMul(a: usize, b: usize) ?usize {
    if (a != 0 and b > std.math.maxInt(usize) / a) return null;
    return a * b;
}

fn checkedAdd(a: u64, b: u64) ?u64 {
    if (b > std.math.maxInt(u64) - a) return null;
    return a + b;
}

fn toUsize(value: u64) ?usize {
    if (value > std.math.maxInt(usize)) return null;
    return @intCast(value);
}

fn isPowerOfTwo(value: u64) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) |
        (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, bytes[offset]) |
        (@as(u64, bytes[offset + 1]) << 8) |
        (@as(u64, bytes[offset + 2]) << 16) |
        (@as(u64, bytes[offset + 3]) << 24) |
        (@as(u64, bytes[offset + 4]) << 32) |
        (@as(u64, bytes[offset + 5]) << 40) |
        (@as(u64, bytes[offset + 6]) << 48) |
        (@as(u64, bytes[offset + 7]) << 56);
}
