//! Zigix kernel entry. Called from `long_mode_start` in
//! `kernel/arch/x86_64/boot/start.S` after long mode is established.
//!
//! Phase 4 contract: emit the boot markers, run the in-kernel smoke registry,
//! and halt through isa-debug-exit.
//!   [ZIGIX:BOOT:START]   — serial UART is up, kmain has run.
//!   [ZIGIX:BOOT:OK]      — kernel reached the end of init without panicking.
//!   [ZIGIX:TEST:PASS:kernel_smoke] — kernel-side registry ran.
//!
//! Anything else (VFS, syscalls, scheduler) belongs to later phases.

const std = @import("std");

const arch = @import("arch");
const cpu = arch.cpu;
const serial = arch.serial;
const log = @import("log.zig");
const mm = @import("mm");
const multiboot = @import("multiboot");
const panic_handler = @import("panic.zig");
const kernel_tests = @import("tests.zig");
const testing = @import("testing.zig");

// Override Zig's panic with our serial-marker handler. `FullPanic` lowers
// every safety check, unreachable, etc. into a call to our function.
pub const panic = std.debug.FullPanic(panic_handler.handler);

// Called from start.S `long_mode_start`. SysV AMD64: RDI = magic, RSI = info.
// The boot stub passes the real Multiboot1 handoff values.
export fn kmain(magic: u64, info_ptr: u64) callconv(.c) noreturn {
    serial.init();
    serial.writeLine("[ZIGIX:BOOT:START]");
    serial.writeLine("[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]");
    log.println(.info, "kernel logger online", .{});

    const boot_info = multiboot.validate(magic, info_ptr) catch |err| {
        log.println(.err, "multiboot handoff invalid: {s}", .{@errorName(err)});
        @panic("bad multiboot handoff");
    };
    const mm_stats = mm.physical.initFromMultiboot(boot_info);
    mm.heap.init();
    log.println(.info, "memory map usable={}KiB tracked_free_pages={}", .{
        mm_stats.usable_bytes / 1024,
        mm_stats.tracked_free_pages,
    });

    arch.gdt.init();
    arch.interrupts.init();
    arch.interrupts.enable();
    log.println(.info, "interrupt descriptor table online", .{});

    testing.runAll(kernel_tests);
    serial.writeLine("[ZIGIX:BOOT:OK]");

    arch.interrupts.disable();
    // Clean QEMU exit via isa-debug-exit (port 0xF4). QEMU exits with
    // status `(value << 1) | 1`, so 0x10 -> exit code 33. The smoke harness
    // treats that as the expected "kernel reached end" signal, while still
    // letting the serial-marker parser decide pass/fail.
    cpu.outb(0xF4, 0x10);
    cpu.halt();
}
