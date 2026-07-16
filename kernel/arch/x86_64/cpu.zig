//! Minimal x86_64 CPU primitives used in early boot.

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub inline fn readCr3() usize {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> usize),
    );
}

pub inline fn readCr0() usize {
    return asm volatile ("mov %%cr0, %[result]"
        : [result] "=r" (-> usize),
    );
}

pub inline fn writeCr0(value: usize) void {
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

pub inline fn readCr4() usize {
    return asm volatile ("mov %%cr4, %[result]"
        : [result] "=r" (-> usize),
    );
}

pub inline fn writeCr4(value: usize) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

const CR0_MP: usize = 1 << 1;
const CR0_EM: usize = 1 << 2;
const CR4_OSFXSR: usize = 1 << 9;
const CR4_OSXMMEXCPT: usize = 1 << 10;

/// Enable the architectural SSE/SSE2 baseline required by the x86_64 SysV
/// userspace ABI. The cooperative scheduler currently runs one userspace
/// context at a time; Phase 18 must add per-thread FXSAVE/XSAVE ownership.
pub fn enableUserSimd() void {
    writeCr0((readCr0() | CR0_MP) & ~CR0_EM);
    writeCr4(readCr4() | CR4_OSFXSR | CR4_OSXMMEXCPT);
    asm volatile ("fninit");
}

pub fn userSimdEnabled() bool {
    const cr0 = readCr0();
    const cr4 = readCr4();
    return (cr0 & CR0_MP) != 0 and
        (cr0 & CR0_EM) == 0 and
        (cr4 & (CR4_OSFXSR | CR4_OSXMMEXCPT)) == (CR4_OSFXSR | CR4_OSXMMEXCPT);
}

pub inline fn writeCr3(value: usize) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

pub inline fn readCr2() usize {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> usize),
    );
}

pub inline fn halt() noreturn {
    while (true) asm volatile ("hlt");
}
