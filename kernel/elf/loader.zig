//! Static ELF64 load-plan validation.

const std = @import("std");

const arch = @import("arch");
const mm = @import("mm");
const proc = @import("proc");
const parse = @import("parse.zig");

pub const Error = parse.Error || error{
    EntryOutsideLoadSegments,
    InvalidUserImage,
    OutOfMemory,
    NoProcess,
    NotAligned,
    AlreadyMapped,
    NotMapped,
    RegionTableFull,
    Unsupported,
    UserStackOverflow,
};

const SMOKE_ENTRY: u64 = 0x0040_0080;
const SMOKE_LOAD_OFFSET: u64 = 0x80;
const SMOKE_LOAD_SIZE: u64 = 4;
const PAGE_SIZE: usize = mm.physical.PAGE_SIZE;
const USER_IMAGE_BASE: usize = 0x4000_0000;
const USER_IMAGE_LIMIT: usize = 0x6000_0000;
const USER_STACK_BASE: usize = 0x7000_0000;
const USER_STACK_SIZE: usize = PAGE_SIZE;
const MAX_STACK_VECTOR_ITEMS: usize = 32;

pub const LoadedImage = struct {
    entry: u64,
    segments: []const parse.Segment,
};

pub const UserImage = struct {
    entry: usize,
    stack_top: usize,
};

pub const UserLoadPlan = struct {
    entry: usize,
    segments: []const parse.Segment,
};

pub const StackSpec = struct {
    argv: []const []const u8 = &.{},
    envp: []const []const u8 = &.{},
};

pub fn validateStatic(image: []const u8, segment_buffer: []parse.Segment) Error!LoadedImage {
    const parsed = try parse.parse(image, segment_buffer);
    if (!entryInsideExecutableSegment(parsed)) return error.EntryOutsideLoadSegments;

    return .{
        .entry = parsed.entry,
        .segments = parsed.segments,
    };
}

pub fn planStaticUser(image: []const u8, segment_buffer: []parse.Segment) Error!UserLoadPlan {
    const loaded = try validateStatic(image, segment_buffer);
    for (loaded.segments) |segment| try validateUserSegment(segment);

    return .{
        .entry = toUsize(loaded.entry) orelse return error.InvalidUserImage,
        .segments = loaded.segments,
    };
}

pub fn loadStaticUser(image: []const u8, segment_buffer: []parse.Segment) Error!UserImage {
    const plan = try planStaticUser(image, segment_buffer);
    return loadPlannedUserForProcess(proc.currentPid(), image, plan, .{});
}

pub fn replaceStaticUser(image: []const u8, segment_buffer: []parse.Segment) Error!UserImage {
    return replaceStaticUserWithStack(image, segment_buffer, .{});
}

pub fn replaceStaticUserWithStack(image: []const u8, segment_buffer: []parse.Segment, stack: StackSpec) Error!UserImage {
    try validateStackSpec(stack);
    const plan = try planStaticUser(image, segment_buffer);
    releaseCurrentProcessPages();
    return loadPlannedUserForProcess(proc.currentPid(), image, plan, stack);
}

fn mapProcRegisterError(err: proc.Error) Error {
    return switch (err) {
        error.NoProcess => error.NoProcess,
        error.RegionTableFull => error.RegionTableFull,
        else => error.InvalidUserImage,
    };
}

pub fn releaseCurrentProcessPages() void {
    releaseProcessPages(proc.currentPid());
}

pub fn releaseProcessPages(pid: proc.Pid) void {
    var drained: [proc.MAX_PROCESS_REGIONS]proc.Region = undefined;
    while (true) {
        const count = proc.drainRegions(pid, &drained);
        if (count == 0) return;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            unmapRegion(drained[index]);
        }
    }
}

fn unmapRegion(region: proc.Region) void {
    var page_index: usize = 0;
    while (page_index < region.page_count) : (page_index += 1) {
        const addr = region.virtual_start + page_index * PAGE_SIZE;
        const mapping = mm.paging.walk(addr) orelse continue;
        if (mapping.page_size != PAGE_SIZE) continue;
        mm.paging.unmapPage(addr) catch continue;
        mm.physical.freePage(mapping.physical);
    }
}

pub fn buildInitialStackForTest(stack: []u8, stack_base: usize, spec: StackSpec) Error!usize {
    try validateStackSpecForSize(spec, stack.len);
    return buildInitialStack(stack, stack_base, spec);
}

pub fn loadStaticUserForProcess(pid: proc.Pid, image: []const u8, segment_buffer: []parse.Segment, stack_spec: StackSpec) Error!UserImage {
    const plan = try planStaticUser(image, segment_buffer);
    return loadPlannedUserForProcess(pid, image, plan, stack_spec);
}

fn loadPlannedUserForProcess(pid: proc.Pid, image: []const u8, plan: UserLoadPlan, stack_spec: StackSpec) Error!UserImage {
    try validateStackSpec(stack_spec);
    errdefer releaseProcessPages(pid);

    for (plan.segments) |segment| {
        try mapSegmentForProcess(pid, segment);
        const file_bytes = try segment.fileBytes(image);
        const dest: [*]u8 = @ptrFromInt(segment.virtual_address);
        @memcpy(dest[0..file_bytes.len], file_bytes);
    }

    const stack_page = try mm.physical.allocPage();
    @memset(pageBytes(stack_page), 0);
    mm.paging.mapUserPage(USER_STACK_BASE, stack_page, true) catch |err| {
        mm.physical.freePage(stack_page);
        return err;
    };
    proc.registerRegion(pid, USER_STACK_BASE, 1) catch |err| {
        mm.paging.unmapPage(USER_STACK_BASE) catch {};
        mm.physical.freePage(stack_page);
        return mapProcRegisterError(err);
    };
    const stack_bytes = userStackBytes();
    const stack_top = try buildInitialStack(stack_bytes, USER_STACK_BASE, stack_spec);

    return .{
        .entry = plan.entry,
        .stack_top = stack_top,
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

fn mapSegmentForProcess(pid: proc.Pid, segment: parse.Segment) Error!void {
    try validateUserSegment(segment);

    const segment_start = toUsize(segment.virtual_address) orelse return error.InvalidUserImage;
    const memory_size = toUsize(segment.memory_size) orelse return error.InvalidUserImage;
    const raw_end = checkedAdd(segment_start, memory_size) orelse return error.InvalidUserImage;
    const start = alignBackward(segment_start, PAGE_SIZE);
    const end = alignForward(raw_end, PAGE_SIZE);

    var addr = start;
    var mapped: usize = 0;
    while (addr < end) : ({
        addr += PAGE_SIZE;
        mapped += 1;
    }) {
        const page = mm.physical.allocPage() catch |err| {
            rollbackPartialSegment(start, mapped);
            return err;
        };
        @memset(pageBytes(page), 0);
        mm.paging.mapUserPage(addr, page, true) catch |err| {
            mm.physical.freePage(page);
            rollbackPartialSegment(start, mapped);
            return err;
        };
    }

    proc.registerRegion(pid, start, (end - start) / PAGE_SIZE) catch |err| {
        rollbackPartialSegment(start, mapped);
        return mapProcRegisterError(err);
    };
}

fn rollbackPartialSegment(start: usize, mapped: usize) void {
    var addr = start;
    var index: usize = 0;
    while (index < mapped) : ({
        addr += PAGE_SIZE;
        index += 1;
    }) {
        const mapping = mm.paging.walk(addr) orelse continue;
        if (mapping.page_size != PAGE_SIZE) continue;
        mm.paging.unmapPage(addr) catch continue;
        mm.physical.freePage(mapping.physical);
    }
}

fn validateUserSegment(segment: parse.Segment) Error!void {
    const segment_start = toUsize(segment.virtual_address) orelse return error.InvalidUserImage;
    const memory_size = toUsize(segment.memory_size) orelse return error.InvalidUserImage;
    const raw_end = checkedAdd(segment_start, memory_size) orelse return error.InvalidUserImage;
    if (segment_start < USER_IMAGE_BASE or raw_end > USER_IMAGE_LIMIT) {
        return error.InvalidUserImage;
    }
}

fn pageBytes(addr: usize) []u8 {
    const raw: [*]u8 = @ptrFromInt(addr);
    return raw[0..PAGE_SIZE];
}

fn userStackBytes() []u8 {
    const raw: [*]u8 = @ptrFromInt(USER_STACK_BASE);
    return raw[0..USER_STACK_SIZE];
}

fn validateStackSpec(spec: StackSpec) Error!void {
    try validateStackSpecForSize(spec, USER_STACK_SIZE);
}

fn validateStackSpecForSize(spec: StackSpec, stack_size: usize) Error!void {
    if (spec.argv.len > MAX_STACK_VECTOR_ITEMS or spec.envp.len > MAX_STACK_VECTOR_ITEMS) {
        return error.UserStackOverflow;
    }
    if (stackUsage(spec) > stack_size) return error.UserStackOverflow;
}

fn stackUsage(spec: StackSpec) usize {
    var bytes: usize = 15;
    for (spec.argv) |arg| bytes += arg.len + 1;
    for (spec.envp) |env| bytes += env.len + 1;
    bytes += (1 + spec.argv.len + 1 + spec.envp.len + 1) * @sizeOf(usize);
    return bytes;
}

fn buildInitialStack(stack: []u8, stack_base: usize, spec: StackSpec) Error!usize {
    var sp = stack.len;
    var argv_ptrs: [MAX_STACK_VECTOR_ITEMS]usize = undefined;
    var envp_ptrs: [MAX_STACK_VECTOR_ITEMS]usize = undefined;

    for (spec.envp, 0..) |env, index| {
        envp_ptrs[index] = try pushCString(stack, stack_base, &sp, env);
    }
    for (spec.argv, 0..) |arg, index| {
        argv_ptrs[index] = try pushCString(stack, stack_base, &sp, arg);
    }

    sp = alignBackward(sp, 16);
    try pushWord(stack, &sp, 0);
    var env_index = spec.envp.len;
    while (env_index > 0) {
        env_index -= 1;
        try pushWord(stack, &sp, envp_ptrs[env_index]);
    }
    try pushWord(stack, &sp, 0);
    var arg_index = spec.argv.len;
    while (arg_index > 0) {
        arg_index -= 1;
        try pushWord(stack, &sp, argv_ptrs[arg_index]);
    }
    try pushWord(stack, &sp, spec.argv.len);

    return stack_base + sp;
}

fn pushCString(stack: []u8, stack_base: usize, sp: *usize, value: []const u8) Error!usize {
    const needed = value.len + 1;
    if (needed > sp.*) return error.UserStackOverflow;
    sp.* -= needed;
    @memcpy(stack[sp.* .. sp.* + value.len], value);
    stack[sp.* + value.len] = 0;
    return stack_base + sp.*;
}

fn pushWord(stack: []u8, sp: *usize, value: usize) Error!void {
    if (sp.* < @sizeOf(usize)) return error.UserStackOverflow;
    sp.* -= @sizeOf(usize);
    writeUsize(stack[sp.* .. sp.* + @sizeOf(usize)], value);
}

fn writeUsize(bytes: []u8, value: usize) void {
    var index: usize = 0;
    while (index < @sizeOf(usize)) : (index += 1) {
        const shift: std.math.Log2Int(usize) = @intCast(index * 8);
        bytes[index] = @truncate(value >> shift);
    }
}

fn checkedAdd(a: usize, b: usize) ?usize {
    if (b > std.math.maxInt(usize) - a) return null;
    return a + b;
}

fn toUsize(value: u64) ?usize {
    if (value > std.math.maxInt(usize)) return null;
    return @intCast(value);
}

fn alignForward(value: usize, comptime alignment: usize) usize {
    const mask = alignment - 1;
    return (value + mask) & ~mask;
}

fn alignBackward(value: usize, comptime alignment: usize) usize {
    const mask = alignment - 1;
    return value & ~mask;
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
