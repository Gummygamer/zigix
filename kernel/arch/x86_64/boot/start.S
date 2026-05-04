/*
 * Zigix x86_64 boot stub.
 *
 * Multiboot1 entry. QEMU's `-kernel` loads us at physical 0x100000 in
 * 32-bit protected mode with paging off, eflags.IF off, and EAX=multiboot
 * magic, EBX=multiboot info pointer.
 *
 * We:
 *   1. Set up an early stack.
 *   2. Build identity-mapped paging covering 0..1 GiB using one PML4, one
 *      PDPT, and 512 2 MiB page-directory entries.
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
 *   flags    = 0x00000002  (request memory info; no aout kludge — we're ELF)
 *   checksum = -(magic + flags)
 */
.section .multiboot, "a"
.align 4
.long 0x1BADB002
.long 0x00000002
.long -(0x1BADB002 + 0x00000002)

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
pd:
    .skip 4096

.align 4
multiboot_magic_saved:
    .skip 4
multiboot_info_saved:
    .skip 4

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

    /* Save the multiboot magic and info pointer before paging setup starts
     * clobbering general registers. Long mode reloads them into RDI / RSI. */
    movl    %eax, multiboot_magic_saved
    movl    %ebx, multiboot_info_saved

    /* ── Build identity paging: PML4[0] -> PDPT[0] -> 512 x 2 MiB ── */
    movl    $pdpt, %eax
    orl     $0x3, %eax          /* present + writable */
    movl    %eax, pml4

    movl    $pd, %eax
    orl     $0x3, %eax          /* present + writable */
    movl    %eax, pdpt

    xorl    %ecx, %ecx
    movl    $0x83, %eax         /* P | RW | PS */
.Lfill_pd:
    movl    %eax, pd(,%ecx,8)
    movl    $0x00, pd+4(,%ecx,8)
    addl    $0x200000, %eax
    incl    %ecx
    cmpl    $512, %ecx
    jne     .Lfill_pd

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

    /* Re-establish the stack pointer in 64-bit mode. */
    movabsq $stack_top, %rsp

    /* Argument pass: kmain(magic: u32, info_ptr: u32) -> noreturn.
     * The bootloader supplies 32-bit physical values; identity paging keeps
     * them directly addressable for early kernel code. */
    movl    multiboot_magic_saved, %edi
    movl    multiboot_info_saved, %esi

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
