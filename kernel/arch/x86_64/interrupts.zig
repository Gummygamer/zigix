//! x86_64 interrupt descriptor table, exception test hook, and PIT timer.

const cpu = @import("cpu.zig");
const serial = @import("serial.zig");

extern fn zigix_isr_de() callconv(.c) void;
extern fn zigix_isr_ud() callconv(.c) void;
extern fn zigix_isr_df() callconv(.c) void;
extern fn zigix_isr_gp() callconv(.c) void;
extern fn zigix_isr_pf() callconv(.c) void;
extern fn zigix_irq0_timer() callconv(.c) void;
extern fn zigix_int80_syscall() callconv(.c) void;
extern fn zigix_lidt(ptr: *align(1) const anyopaque) callconv(.c) void;

const KERNEL_CODE_SELECTOR: u16 = 0x08;
const INTERRUPT_GATE: u8 = 0x8E;
const USER_INTERRUPT_GATE: u8 = 0xEE;
const TIMER_VECTOR: u8 = 32;
const SYSCALL_VECTOR: u8 = 0x80;
const PIT_FREQUENCY_HZ: u32 = 100;
const PIT_BASE_HZ: u32 = 1_193_182;

const InterruptFrame = extern struct {
    rip: u64,
    cs: u64,
    rflags: u64,
};

var idt: [256]u128 align(16) = [_]u128{0} ** 256;
var idt_pointer: [10]u8 align(1) = [_]u8{0} ** 10;

var ud_test_armed: bool = false;
var ud_test_caught: bool = false;
var timer_ticks: u64 = 0;

pub fn init() void {
    setGate(0, zigix_isr_de);
    setGate(6, zigix_isr_ud);
    setGate(8, zigix_isr_df);
    setGate(13, zigix_isr_gp);
    setGate(14, zigix_isr_pf);
    setGate(TIMER_VECTOR, zigix_irq0_timer);
    setUserGate(SYSCALL_VECTOR, zigix_int80_syscall);

    writeDescriptorPointer(&idt_pointer, @sizeOf(@TypeOf(idt)) - 1, @intFromPtr(&idt));
    zigix_lidt(&idt_pointer);

    remapPic();
    initPit(PIT_FREQUENCY_HZ);
}

pub fn enable() void {
    asm volatile ("sti");
}

pub fn disable() void {
    asm volatile ("cli");
}

pub fn tickCount() u64 {
    const ticks: *volatile u64 = &timer_ticks;
    return ticks.*;
}

pub fn triggerUdSelfTest() bool {
    const armed: *volatile bool = &ud_test_armed;
    const caught: *volatile bool = &ud_test_caught;
    caught.* = false;
    armed.* = true;
    asm volatile ("ud2");
    return caught.* and !armed.*;
}

fn setGate(vector: u8, comptime handler: fn () callconv(.c) void) void {
    setGateWithAttributes(vector, handler, INTERRUPT_GATE);
}

fn setUserGate(vector: u8, comptime handler: fn () callconv(.c) void) void {
    setGateWithAttributes(vector, handler, USER_INTERRUPT_GATE);
}

fn setGateWithAttributes(vector: u8, comptime handler: fn () callconv(.c) void, attributes: u8) void {
    const offset = @intFromPtr(&handler);
    idt[vector] =
        @as(u128, offset & 0xffff) |
        (@as(u128, KERNEL_CODE_SELECTOR) << 16) |
        (@as(u128, attributes) << 40) |
        (@as(u128, (offset >> 16) & 0xffff) << 48) |
        (@as(u128, (offset >> 32) & 0xffff_ffff) << 64);
}

fn remapPic() void {
    const master_mask = cpu.inb(0x21);
    const slave_mask = cpu.inb(0xA1);

    cpu.outb(0x20, 0x11);
    ioWait();
    cpu.outb(0xA0, 0x11);
    ioWait();
    cpu.outb(0x21, 0x20);
    ioWait();
    cpu.outb(0xA1, 0x28);
    ioWait();
    cpu.outb(0x21, 0x04);
    ioWait();
    cpu.outb(0xA1, 0x02);
    ioWait();
    cpu.outb(0x21, 0x01);
    ioWait();
    cpu.outb(0xA1, 0x01);
    ioWait();

    // Preserve the bootloader mask state, but always unmask IRQ0 for PIT.
    cpu.outb(0x21, master_mask & 0xFE);
    cpu.outb(0xA1, slave_mask);
}

fn initPit(comptime hz: u32) void {
    const divisor: u16 = @intCast(PIT_BASE_HZ / hz);
    cpu.outb(0x43, 0x36);
    cpu.outb(0x40, @intCast(divisor & 0x00ff));
    cpu.outb(0x40, @intCast(divisor >> 8));
}

fn ioWait() void {
    cpu.outb(0x80, 0);
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

export fn x86_64_handle_ud(frame: *InterruptFrame) callconv(.c) void {
    const armed: *volatile bool = &ud_test_armed;
    const caught: *volatile bool = &ud_test_caught;
    if (!armed.*) {
        handleUnexpectedException(6, 0, frame);
    }

    frame.rip += 2; // `ud2` is two bytes.
    caught.* = true;
    armed.* = false;
}

export fn x86_64_handle_exception(vector: u64, error_code: u64, frame: *InterruptFrame) callconv(.c) noreturn {
    handleUnexpectedException(vector, error_code, frame);
}

export fn x86_64_handle_timer() callconv(.c) void {
    const ticks: *volatile u64 = &timer_ticks;
    ticks.* +%= 1;
    cpu.outb(0x20, 0x20);
}

fn handleUnexpectedException(vector: u64, error_code: u64, frame: *InterruptFrame) noreturn {
    disable();
    serial.write("[ZIGIX:EXCEPTION:");
    serial.writeDecimal(vector);
    serial.write(":ERR=");
    serial.writeHex(error_code);
    if (vector == 14) {
        serial.write(":CR2=");
        serial.writeHex(cpu.readCr2());
    }
    serial.write(":RIP=");
    serial.writeHex(frame.rip);
    serial.writeLine("]");
    cpu.halt();
}
