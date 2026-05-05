//! 16550-compatible UART driver, COM1 only. The smallest thing that lets
//! the kernel emit machine-readable serial markers.
//!
//! Anything more (interrupt-driven RX, line discipline, second UART)
//! belongs to a later phase.

const cpu = @import("cpu.zig");

const COM1: u16 = 0x3F8;

const REG_DATA: u16 = 0;
const REG_INT_ENABLE: u16 = 1;
const REG_DLAB_LO: u16 = 0;
const REG_DLAB_HI: u16 = 1;
const REG_FCR: u16 = 2;
const REG_LCR: u16 = 3;
const REG_MCR: u16 = 4;
const REG_LSR: u16 = 5;
const REG_SCRATCH: u16 = 7;

var bytes_written: usize = 0;

pub fn init() void {
    // Disable all UART interrupts; we drive it polled.
    cpu.outb(COM1 + REG_INT_ENABLE, 0x00);

    // Enable DLAB to set baud-rate divisor.
    cpu.outb(COM1 + REG_LCR, 0x80);

    // 38400 baud (divisor 3). The exact rate doesn't matter for QEMU's
    // virtual serial; we just need to set *something* sensible.
    cpu.outb(COM1 + REG_DLAB_LO, 0x03);
    cpu.outb(COM1 + REG_DLAB_HI, 0x00);

    // 8N1, DLAB off.
    cpu.outb(COM1 + REG_LCR, 0x03);

    // Enable + clear FIFOs, 14-byte trigger level.
    cpu.outb(COM1 + REG_FCR, 0xC7);

    // RTS + DTR + OUT2 (OUT2 gates IRQ on real hardware; harmless in QEMU).
    cpu.outb(COM1 + REG_MCR, 0x0B);
}

inline fn transmitReady() bool {
    return (cpu.inb(COM1 + REG_LSR) & 0x20) != 0;
}

pub fn writeByte(b: u8) void {
    while (!transmitReady()) {}
    cpu.outb(COM1 + REG_DATA, b);
    bytes_written +%= 1;
}

pub fn write(bytes: []const u8) void {
    for (bytes) |b| writeByte(b);
}

pub fn writeLine(bytes: []const u8) void {
    write(bytes);
    writeByte('\n');
}

pub fn writeDecimal(value: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var n = value;

    if (n == 0) {
        writeByte('0');
        return;
    }

    while (n != 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    write(buf[i..]);
}

pub fn writeHex(value: u64) void {
    write("0x");
    var shift: u6 = 60;
    var seen_non_zero = false;
    while (true) {
        const nibble: u8 = @intCast((value >> shift) & 0xF);
        if (nibble != 0 or seen_non_zero or shift == 0) {
            seen_non_zero = true;
            writeByte(if (nibble < 10) '0' + nibble else 'a' + (nibble - 10));
        }
        if (shift == 0) break;
        shift -= 4;
    }
}

pub fn writtenByteCount() usize {
    return bytes_written;
}

pub fn scratchRoundTrip(value: u8) bool {
    cpu.outb(COM1 + REG_SCRATCH, value);
    return cpu.inb(COM1 + REG_SCRATCH) == value;
}
