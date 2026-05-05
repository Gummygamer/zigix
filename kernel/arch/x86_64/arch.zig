//! x86_64 architecture facade.
//!
//! Re-exports the per-arch primitives the rest of the kernel uses, so
//! arch-agnostic code imports `arch.cpu` / `arch.serial` instead of
//! reaching into `kernel/arch/x86_64/...` directly. When a second arch
//! lands, the build picks the matching `arch.zig`.

pub const cpu = @import("cpu.zig");
pub const gdt = @import("gdt.zig");
pub const interrupts = @import("interrupts.zig");
pub const serial = @import("serial.zig");
