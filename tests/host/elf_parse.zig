const std = @import("std");

const elf = @import("elf_parse");

const ENTRY: u64 = 0x0040_0080;
const LOAD_OFFSET: u64 = 0x80;
const LOAD_SIZE: u64 = 4;

test "ELF parser accepts a minimal static x86_64 executable" {
    var image: [192]u8 = [_]u8{0} ** 192;
    const bytes = buildElf(&image, .{});

    var segments: [4]elf.Segment = undefined;
    const parsed = try elf.parse(bytes, &segments);

    try std.testing.expectEqual(@as(u64, ENTRY), parsed.entry);
    try std.testing.expectEqual(@as(usize, 1), parsed.segments.len);
    try std.testing.expect(parsed.segments[0].flags.read);
    try std.testing.expect(parsed.segments[0].flags.execute);
    try std.testing.expect(!parsed.segments[0].flags.write);
    try std.testing.expectEqualStrings("\x48\x31\xc0\xc3", try parsed.segments[0].fileBytes(bytes));
}

test "ELF parser rejects truncated and random inputs" {
    var segments: [4]elf.Segment = undefined;
    var truncated: [elf.ELF_HEADER_SIZE - 1]u8 = [_]u8{0} ** (elf.ELF_HEADER_SIZE - 1);
    try std.testing.expectError(error.TruncatedHeader, elf.parse(&truncated, &segments));

    var state: u64 = 0x91d3_d2c5_3f17_48ab;
    var bytes: [256]u8 = undefined;
    for (&bytes) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = @truncate(state >> 56);
    }
    try std.testing.expectError(error.BadMagic, elf.parse(&bytes, &segments));
}

test "ELF parser rejects malformed headers and segment bounds" {
    var image: [192]u8 = [_]u8{0} ** 192;
    var bytes = buildElf(&image, .{});
    var segments: [4]elf.Segment = undefined;

    image[0] = 0;
    try std.testing.expectError(error.BadMagic, elf.parse(bytes, &segments));
    image[0] = 0x7f;

    image[4] = 1;
    try std.testing.expectError(error.UnsupportedClass, elf.parse(bytes, &segments));
    image[4] = 2;

    writeU16(&image, 54, elf.PROGRAM_HEADER_SIZE - 1);
    try std.testing.expectError(error.UnsupportedHeaderSize, elf.parse(bytes, &segments));
    writeU16(&image, 54, elf.PROGRAM_HEADER_SIZE);

    bytes = image[0 .. elf.ELF_HEADER_SIZE + elf.PROGRAM_HEADER_SIZE - 1];
    try std.testing.expectError(error.InvalidProgramHeaderTable, elf.parse(bytes, &segments));
}

test "ELF parser rejects PT_LOAD segments past EOF and invalid sizes" {
    var image: [192]u8 = [_]u8{0} ** 192;
    const bytes = buildElf(&image, .{});
    var segments: [4]elf.Segment = undefined;

    writeU64(&image, elf.ELF_HEADER_SIZE + 32, 32);
    try std.testing.expectError(error.SegmentPastEof, elf.parse(bytes, &segments));

    writeU64(&image, elf.ELF_HEADER_SIZE + 32, LOAD_SIZE);
    writeU64(&image, elf.ELF_HEADER_SIZE + 40, LOAD_SIZE - 1);
    try std.testing.expectError(error.InvalidSegment, elf.parse(bytes, &segments));
}

test "ELF parser rejects overlapping PT_LOAD virtual ranges" {
    var image: [256]u8 = [_]u8{0} ** 256;
    _ = buildElf(&image, .{ .phnum = 2, .payload_offset = 0xb0 });
    const bytes = image[0..0xc4];
    var segments: [4]elf.Segment = undefined;

    writeU64(&image, elf.ELF_HEADER_SIZE + 16, 0x0040_00b0);
    writeU64(&image, elf.ELF_HEADER_SIZE + 24, 0x0040_00b0);

    const second = elf.ELF_HEADER_SIZE + elf.PROGRAM_HEADER_SIZE;
    writeProgramHeader(&image, second, .{
        .offset = 0xc0,
        .vaddr = 0x0040_00c0,
        .filesz = 4,
        .memsz = 0x20,
    });

    try std.testing.expectError(error.SegmentOverlap, elf.parse(bytes, &segments));
}

const BuildOptions = struct {
    phnum: u16 = 1,
    payload_offset: u64 = LOAD_OFFSET,
};

const ProgramHeader = struct {
    offset: u64 = LOAD_OFFSET,
    vaddr: u64 = ENTRY,
    filesz: u64 = LOAD_SIZE,
    memsz: u64 = LOAD_SIZE,
};

fn buildElf(buffer: []u8, options: BuildOptions) []const u8 {
    buffer[0] = 0x7f;
    buffer[1] = 'E';
    buffer[2] = 'L';
    buffer[3] = 'F';
    buffer[4] = 2;
    buffer[5] = 1;
    buffer[6] = 1;

    writeU16(buffer, 16, elf.ET_EXEC);
    writeU16(buffer, 18, elf.EM_X86_64);
    writeU32(buffer, 20, 1);
    writeU64(buffer, 24, ENTRY);
    writeU64(buffer, 32, elf.ELF_HEADER_SIZE);
    writeU16(buffer, 52, elf.ELF_HEADER_SIZE);
    writeU16(buffer, 54, elf.PROGRAM_HEADER_SIZE);
    writeU16(buffer, 56, options.phnum);

    writeProgramHeader(buffer, elf.ELF_HEADER_SIZE, .{
        .offset = options.payload_offset,
        .vaddr = ENTRY,
        .filesz = LOAD_SIZE,
        .memsz = 0x20,
    });

    const payload: usize = @intCast(options.payload_offset);
    buffer[payload + 0] = 0x48;
    buffer[payload + 1] = 0x31;
    buffer[payload + 2] = 0xc0;
    buffer[payload + 3] = 0xc3;

    return buffer[0 .. payload + LOAD_SIZE];
}

fn writeProgramHeader(bytes: []u8, offset: usize, ph: ProgramHeader) void {
    writeU32(bytes, offset + 0, 1);
    writeU32(bytes, offset + 4, 5);
    writeU64(bytes, offset + 8, ph.offset);
    writeU64(bytes, offset + 16, ph.vaddr);
    writeU64(bytes, offset + 24, ph.vaddr);
    writeU64(bytes, offset + 32, ph.filesz);
    writeU64(bytes, offset + 40, ph.memsz);
    writeU64(bytes, offset + 48, 0x1000);
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
