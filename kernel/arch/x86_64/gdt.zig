//! Kernel-owned x86_64 GDT and TSS setup.

const std = @import("std");

extern fn zigix_lgdt_reload(ptr: *align(1) const anyopaque) callconv(.c) void;
extern fn zigix_ltr(selector: u16) callconv(.c) void;

extern var stack_top: u8;

const KERNEL_CODE: u16 = 0x08;
const KERNEL_DATA: u16 = 0x10;
pub const USER_CODE: u16 = 0x18 | 3;
pub const USER_DATA: u16 = 0x20 | 3;
const TSS_SELECTOR: u16 = 0x28;

const TSS_SIZE = 104;

var tss: [TSS_SIZE]u8 align(16) = [_]u8{0} ** TSS_SIZE;

// null, kernel code, kernel data, user code, user data, TSS low, TSS high.
var table: [7]u64 align(8) = .{
    0,
    0x00AF9A000000FFFF,
    0x00AF92000000FFFF,
    0x00AFFA000000FFFF,
    0x00AFF2000000FFFF,
    0,
    0,
};

var pointer: [10]u8 align(1) = [_]u8{0} ** 10;

pub fn init() void {
    setKernelStackTop(@intFromPtr(&stack_top));
    writeLe16(102, TSS_SIZE);
    installTssDescriptor();

    writeDescriptorPointer(&pointer, @sizeOf(@TypeOf(table)) - 1, @intFromPtr(&table));
    zigix_lgdt_reload(&pointer);
    zigix_ltr(TSS_SELECTOR);
}

pub fn defaultKernelStackTop() usize {
    return @intFromPtr(&stack_top);
}

pub fn setKernelStackTop(top: usize) void {
    writeLe64(4, top);
}

pub fn kernelStackTop() usize {
    return readLe64(4);
}

fn installTssDescriptor() void {
    const base = @intFromPtr(&tss);
    const limit: u32 = TSS_SIZE - 1;

    table[5] =
        (@as(u64, limit & 0xffff)) |
        ((@as(u64, base & 0xffff)) << 16) |
        ((@as(u64, (base >> 16) & 0xff)) << 32) |
        (@as(u64, 0x89) << 40) |
        ((@as(u64, (limit >> 16) & 0x0f)) << 48) |
        ((@as(u64, (base >> 24) & 0xff)) << 56);
    table[6] = @as(u64, (base >> 32) & 0xffff_ffff);
}

fn writeLe16(offset: usize, value: u16) void {
    tss[offset] = @intCast(value & 0x00ff);
    tss[offset + 1] = @intCast(value >> 8);
}

fn writeLe64(offset: usize, value: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        tss[offset + i] = @intCast((value >> shift) & 0xff);
    }
}

fn readLe64(offset: usize) u64 {
    var value: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        value |= @as(u64, tss[offset + i]) << shift;
    }
    return value;
}

fn writeDescriptorPointer(dest: *[10]u8, limit: u16, base: u64) void {
    dest[0] = @intCast(limit & 0x00ff);
    dest[1] = @intCast(limit >> 8);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u6 = @intCast(i * 8);
        dest[2 + i] = @intCast((base >> shift) & 0xff);
    }
}

comptime {
    std.debug.assert(KERNEL_CODE == 0x08);
    std.debug.assert(KERNEL_DATA == 0x10);
    std.debug.assert(USER_CODE == 0x1b);
    std.debug.assert(USER_DATA == 0x23);
    std.debug.assert(TSS_SIZE == 104);
}
