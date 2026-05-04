//! Kernel panic handler.
//!
//! Emits `[ZIGIX:PANIC:<msg>]` on COM1 then halts. The smoke parser keys
//! off this exact bracketed marker — keep the format stable.

const arch = @import("arch");
const cpu = arch.cpu;
const log = @import("log.zig");
const serial = arch.serial;

pub fn handler(msg: []const u8, return_address: ?usize) noreturn {
    asm volatile ("cli");
    serial.write("[ZIGIX:PANIC:");
    serial.write(msg);
    serial.writeLine("]");

    log.println(.err, "panic return_address=0x{x}", .{return_address orelse 0});
    log.println(.err, "registers rip=0x{x} rsp=0x{x}", .{
        return_address orelse 0,
        stackPointer(),
    });

    cpu.halt();
}

fn stackPointer() usize {
    return asm volatile ("mov %%rsp, %[ret]"
        : [ret] "=r" (-> usize),
    );
}
