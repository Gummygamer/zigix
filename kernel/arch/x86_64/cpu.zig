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

pub inline fn readCr2() usize {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> usize),
    );
}

pub inline fn halt() noreturn {
    while (true) asm volatile ("hlt");
}
