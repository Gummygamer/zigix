//! Zigix kernel entry. Called from `long_mode_start` in
//! `kernel/arch/x86_64/boot/start.S` after long mode is established.
//!
//! Phase 8 contract: emit the boot markers, mount the initramfs-backed VFS,
//! run the in-kernel smoke registry,
//! and launch the first userspace init.
//!   [ZIGIX:BOOT:START]   — serial UART is up, kmain has run.
//!   [ZIGIX:BOOT:OK]      — kernel reached the end of init without panicking.
//!   [ZIGIX:TEST:PASS:kernel_smoke] — kernel-side registry ran.
//!
//! Scheduling and process lifecycle belong to later phases.

const std = @import("std");

const arch = @import("arch");
const serial = arch.serial;
const log = @import("log.zig");
const elf = @import("elf");
const fs = @import("fs");
const mm = @import("mm");
const multiboot = @import("multiboot");
const panic_handler = @import("panic.zig");
const syscall = @import("syscall");
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
    syscall.init();

    fs.initFromMultiboot(boot_info) catch |err| {
        log.println(.err, "filesystem init failed: {s}", .{@errorName(err)});
        @panic("filesystem init failed");
    };
    const init_inode = fs.vfs.lookup("/init") catch |err| {
        log.println(.err, "required initramfs file missing: {s}", .{@errorName(err)});
        @panic("missing /init");
    };
    serial.writeLine("[ZIGIX:VFS:OK]");

    testing.runAll(kernel_tests);
    serial.writeLine("[ZIGIX:BOOT:OK]");

    var user_segments: [8]elf.parse.Segment = undefined;
    const init_image = elf.loader.loadStaticUser(init_inode.data, &user_segments) catch |err| {
        log.println(.err, "loading /init failed: {s}", .{@errorName(err)});
        @panic("init load failed");
    };

    arch.user.enter(init_image.entry, init_image.stack_top);
}
