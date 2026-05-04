/*
 * Zigix x86_64 boot stub.
 *
 * Multiboot1 entry. QEMU's `-kernel` loads us at physical 0x100000 in
 * 32-bit protected mode with paging off, eflags.IF off, and EAX=multiboot
 * magic, EBX=multiboot info pointer.
 *
 * We:
 *   1. Set up an early stack.
 *   2. Build identity-mapped paging covering 0..1 GiB using one PML4 +
 *      one PDPT entry pointing at a single 1 GiB huge page.
 *   3. Enable PAE (CR4.PAE), set EFER.LME, enable paging (CR0.PG).
 *   4. Load a 64-bit GDT and far-jump to long mode.
 *   5. Reload data segments and call kmain.
 *
 * Anything more (higher-half mapping, SMP, GDT/IDT for traps, larger heap)
 * is for later phases. This file deliberately does the minimum for
 * Phase 1's two-marker boot test.
 *
 * AT&T syntax (GAS default).
 */

/* ─── Multiboot1 header ─────────────────────────────────────────────────
 * The bootloader scans the first 8 KiB of the ELF for these three dwords
 * at 4-byte alignment.
 *
 *   magic    = 0x1BADB002
 *   flags    = 0x00000000  (no extra requests; no aout kludge — we're ELF)
 *   checksum = -(magic + flags)
 */
.section .multiboot, "a"
.align 4
.long 0x1BADB002
.long 0x00000000
.long -(0x1BADB002 + 0x00000000)

/* ─── BSS: stack + early page tables ─────────────────────────────────── */
.section .bss
.align 16
.global stack_bottom
.global stack_top
stack_bottom:
    .skip 16384                 /* 16 KiB stack — plenty for Phase 1 */
stack_top:

.align 4096
pml4:
    .skip 4096
pdpt:
    .skip 4096

/* ─── 64-bit GDT (rodata) ─────────────────────────────────────────────
 * Three entries: null, 64-bit code, 64-bit data. In long mode the limit
 * and base of code/data segments are ignored — what matters is the
 * access byte and the L bit. These values are the OSDev-wiki canonical
 * 64-bit code/data descriptors.
 */
.section .rodata
.align 8
.global gdt64
gdt64:
    .quad 0                                     /* 0x00: null */
    .quad 0x00AF9A000000FFFF                    /* 0x08: code64, P|S|Type=A|L */
    .quad 0x00AF92000000FFFF                    /* 0x10: data64, P|S|Type=2 */
gdt64_end:
.global gdt64_pointer
gdt64_pointer:
    .word gdt64_end - gdt64 - 1
    .quad gdt64

/* ─── 32-bit entry ────────────────────────────────────────────────────── */
.section .text
.code32
.global _start
.type   _start, @function
_start:
    /* Establish a stack so we can call back into anything that needs one. */
    movl    $stack_top, %esp

    /* Save the multiboot info pointer (EBX) and magic (EAX) for kmain.
     * They go on the stack in reverse so the SysV AMD64 calling convention
     * picks them up via RDI / RSI after we transition. We re-fetch them
     * once we are in 64-bit mode. */
    pushl   %ebx                /* multiboot info ptr */
    pushl   %eax                /* multiboot magic */

    /* ── Build identity paging: PML4[0] -> PDPT, PDPT[0] -> 1 GiB huge ── */
    movl    $pdpt, %eax
    orl     $0x3, %eax          /* present + writable */
    movl    %eax, pml4

    /* PDPT[0] = 0x00000000 | P | RW | PS  (1 GiB huge page at 0) */
    movl    $0x83, pdpt
    movl    $0x00, pdpt+4

    /* CR3 = PML4 */
    movl    $pml4, %eax
    movl    %eax, %cr3

    /* CR4.PAE = 1  (bit 5) */
    movl    %cr4, %eax
    orl     $(1 << 5), %eax
    movl    %eax, %cr4

    /* EFER.LME = 1  (MSR 0xC0000080, bit 8) */
    movl    $0xC0000080, %ecx
    rdmsr
    orl     $(1 << 8), %eax
    wrmsr

    /* CR0.PG = 1  (bit 31) — and ensure PE stays on (bit 0) */
    movl    %cr0, %eax
    orl     $(1 << 31), %eax
    movl    %eax, %cr0

    /* Now in long mode in 32-bit compatibility mode. Load 64-bit GDT and
     * far-jump into a true 64-bit code segment. */
    lgdt    gdt64_pointer
    ljmp    $0x08, $long_mode_start

.size _start, . - _start

/* ─── 64-bit entry ────────────────────────────────────────────────────── */
.code64
.global long_mode_start
.type   long_mode_start, @function
long_mode_start:
    /* Long mode largely ignores segment selectors, but ds/es/fs/gs/ss must
     * still be loaded with non-null selectors for some instructions. We
     * use the null selector for ds/es/fs/gs (long mode permits this),
     * and the 64-bit data segment for ss. */
    xorl    %eax, %eax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %fs
    movw    %ax, %gs
    movw    $0x10, %ax
    movw    %ax, %ss

    /* Re-establish the stack pointer in 64-bit mode. The 32-bit pushes
     * we did earlier are still on the stack (now interpreted as 64-bit),
     * but we don't need them yet — we just need a valid RSP. */
    movabsq $stack_top, %rsp

    /* Argument pass: kmain(magic: u32, info_ptr: u32) -> noreturn.
     * The Multiboot info we saved earlier was 32-bit; re-read it from
     * the original physical addresses by re-executing the convention.
     * For Phase 1 we don't actually consume them, so pass zero/zero
     * via the SysV AMD64 calling convention (RDI, RSI). */
    xorq    %rdi, %rdi
    xorq    %rsi, %rsi

    /* Tail-call into the Zig kernel. */
    callq   kmain

    /* If kmain ever returns, hang. */
.Lhang:
    cli
    hlt
    jmp     .Lhang

.size long_mode_start, . - long_mode_start

/* Reject executable stack on Linux toolchains. Harmless on bare metal. */
.section .note.GNU-stack, "", @progbits
