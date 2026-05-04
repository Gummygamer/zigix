/*
 * Zigix x86_64 kernel linker script.
 *
 * Phase 1 layout: identity-mapped at 1 MiB (0x100000), no higher-half.
 * The multiboot1 header lives in the first 8 KiB so QEMU can find it.
 */

ENTRY(_start)
OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

SECTIONS
{
    . = 0x100000;
    __kernel_start = .;

    /* Multiboot header MUST be in the first 8 KiB of the file at 4-byte
     * alignment. Putting it first guarantees that. */
    .multiboot ALIGN(4) : ALIGN(4)
    {
        KEEP(*(.multiboot))
    }

    .text ALIGN(4K) :
    {
        *(.text .text.*)
    }

    .rodata ALIGN(4K) :
    {
        *(.rodata .rodata.*)
    }

    .data ALIGN(4K) :
    {
        *(.data .data.*)
    }

    .bss ALIGN(4K) :
    {
        *(COMMON)
        *(.bss .bss.*)
    }
    __kernel_end = .;

    /DISCARD/ :
    {
        *(.note .note.*)
        *(.comment)
        *(.eh_frame .eh_frame.*)
        *(.gnu.build.attributes .gnu.build.attributes.*)
    }
}
