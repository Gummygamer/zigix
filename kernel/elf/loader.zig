//! Static ELF64 load-plan validation.

const arch = @import("arch");
const parse = @import("parse.zig");

pub const Error = parse.Error || error{
    EntryOutsideLoadSegments,
};

const SMOKE_ENTRY: u64 = 0x0040_0080;
const SMOKE_LOAD_OFFSET: u64 = 0x80;
const SMOKE_LOAD_SIZE: u64 = 4;

pub const LoadedImage = struct {
    entry: u64,
    segments: []const parse.Segment,
};

pub fn validateStatic(image: []const u8, segment_buffer: []parse.Segment) Error!LoadedImage {
    const parsed = try parse.parse(image, segment_buffer);
    if (!entryInsideExecutableSegment(parsed)) return error.EntryOutsideLoadSegments;

    return .{
        .entry = parsed.entry,
        .segments = parsed.segments,
    };
}

pub fn selfTestStaticLoaderMarker() bool {
    var image: [192]u8 = [_]u8{0} ** 192;
    const elf = buildSmokeElf(&image);

    var segments: [4]parse.Segment = undefined;
    const loaded = validateStatic(elf, &segments) catch return false;
    if (loaded.entry != SMOKE_ENTRY) return false;
    if (loaded.segments.len != 1) return false;
    if (loaded.segments[0].file_size != SMOKE_LOAD_SIZE) return false;

    arch.serial.writeLine("[ZIGIX:ELF:OK]");
    return true;
}

fn entryInsideExecutableSegment(image: parse.Image) bool {
    for (image.segments) |segment| {
        if (!segment.flags.execute) continue;
        const end = segment.virtual_address + segment.memory_size;
        if (image.entry >= segment.virtual_address and image.entry < end) return true;
    }
    return false;
}

fn buildSmokeElf(buffer: []u8) []const u8 {
    buffer[0] = 0x7f;
    buffer[1] = 'E';
    buffer[2] = 'L';
    buffer[3] = 'F';
    buffer[4] = 2;
    buffer[5] = 1;
    buffer[6] = 1;

    writeU16(buffer, 16, parse.ET_EXEC);
    writeU16(buffer, 18, parse.EM_X86_64);
    writeU32(buffer, 20, 1);
    writeU64(buffer, 24, SMOKE_ENTRY);
    writeU64(buffer, 32, parse.ELF_HEADER_SIZE);
    writeU16(buffer, 52, parse.ELF_HEADER_SIZE);
    writeU16(buffer, 54, parse.PROGRAM_HEADER_SIZE);
    writeU16(buffer, 56, 1);

    const phoff = parse.ELF_HEADER_SIZE;
    writeU32(buffer, phoff + 0, 1);
    writeU32(buffer, phoff + 4, 5);
    writeU64(buffer, phoff + 8, SMOKE_LOAD_OFFSET);
    writeU64(buffer, phoff + 16, SMOKE_ENTRY);
    writeU64(buffer, phoff + 24, SMOKE_ENTRY);
    writeU64(buffer, phoff + 32, SMOKE_LOAD_SIZE);
    writeU64(buffer, phoff + 40, SMOKE_LOAD_SIZE);
    writeU64(buffer, phoff + 48, 0x1000);

    const payload: usize = @intCast(SMOKE_LOAD_OFFSET);
    buffer[payload + 0] = 0x48;
    buffer[payload + 1] = 0x31;
    buffer[payload + 2] = 0xc0;
    buffer[payload + 3] = 0xc3;

    return buffer[0 .. payload + SMOKE_LOAD_SIZE];
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset + 0] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset + 0] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    bytes[offset + 0] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
    bytes[offset + 4] = @truncate(value >> 32);
    bytes[offset + 5] = @truncate(value >> 40);
    bytes[offset + 6] = @truncate(value >> 48);
    bytes[offset + 7] = @truncate(value >> 56);
}
