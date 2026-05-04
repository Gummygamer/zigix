//! Zigix kernel entry. Called from `long_mode_start` in
//! `kernel/arch/x86_64/boot/start.S` after long mode is established.
//!
//! Phase 2 contract: emit the boot markers, run the in-kernel smoke registry,
//! and halt through isa-debug-exit.
//!   [ZIGIX:BOOT:START]   — serial UART is up, kmain has run.
//!   [ZIGIX:BOOT:OK]      — kernel reached the end of init without panicking.
//!   [ZIGIX:TEST:PASS:kernel_smoke] — kernel-side registry ran.
//!
//! Anything else (memory map parsing, IDT, scheduler) belongs to later phases.

const std = @import("std");

const arch = @import("arch");
const cpu = arch.cpu;
const serial = arch.serial;
const log = @import("log.zig");
const panic_handler = @import("panic.zig");
const kernel_tests = @import("tests.zig");
const testing = @import("testing.zig");

// Override Zig's panic with our serial-marker handler. `FullPanic` lowers
// every safety check, unreachable, etc. into a call to our function.
pub const panic = std.debug.FullPanic(panic_handler.handler);

// Called from start.S `long_mode_start`. SysV AMD64: RDI = magic, RSI = info.
// Phase 3 will consume the real multiboot values; until then the signature
// keeps the handoff contract explicit.
export fn kmain(magic: u64, info_ptr: u64) callconv(.c) noreturn {
    _ = magic;
    _ = info_ptr;

    serial.init();
    serial.writeLine("[ZIGIX:BOOT:START]");
    serial.writeLine("[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]");
    log.println(.info, "kernel logger online", .{});
    testing.runAll(kernel_tests);
    serial.writeLine("[ZIGIX:BOOT:OK]");

    asm volatile ("cli");
    // Clean QEMU exit via isa-debug-exit (port 0xF4). QEMU exits with
    // status `(value << 1) | 1`, so 0x10 -> exit code 33. The smoke harness
    // treats that as the expected "kernel reached end" signal, while still
    // letting the serial-marker parser decide pass/fail.
    cpu.outb(0xF4, 0x10);
    cpu.halt();
}
