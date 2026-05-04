# Architecture

This is a stub. It will grow with the kernel.

## Directory layout

```
zigix/
  build.zig              # build orchestration (run via tools/toolchain/zig-bun)
  build.zig.zon          # package manifest
  kernel/
    arch/x86_64/         # arch-specific code (boot, paging, idt, gdt, serial)
    core/                # arch-independent kernel: main, panic, log, errors
    mm/                  # physical/virtual memory, heap, user mappings
    sched/               # task, scheduler, process, thread
    fs/                  # vfs, initramfs, devfs, memfs, path
    syscall/             # table, numbers, dispatch, handlers
    elf/                 # elf64 parser and loader
    drivers/             # serial, timer, keyboard
  userspace/
    libc_shim/           # tiny libc syscall stubs for now
    init/                # first userspace program
    tinysh/              # minimal shell
    tests/               # userspace test programs
  tools/
    toolchain/           # zig-bun wrapper, check, measure
    qemu/                # run.sh, smoke_test.py
    mkinitramfs/         # initramfs packager
  tests/                 # unit, integration, qemu, fixtures
  ci/                    # local CI script
  docs/                  # this and friends
```

## Architecture-independent vs architecture-specific

| Independent                              | x86_64-specific                                  |
| ---------------------------------------- | ------------------------------------------------ |
| `kernel/core/*`                          | `kernel/arch/x86_64/{boot,gdt,idt,paging,...}.zig` |
| `kernel/mm/{physical,virtual,heap}.zig`  | page-table layout, MMU details, port I/O         |
| `kernel/fs/*`                            | nothing — fs is portable                         |
| `kernel/syscall/{table,numbers}.zig`     | calling-convention dispatcher in `arch/x86_64`   |
| `kernel/elf/*`                           | only the ELF machine-type check is arch-aware    |

The rule: **arch-specific code is reachable only through interfaces declared
in arch-independent code.** When in doubt, push the abstraction barrier
upward.

## Boot flow (Phase 1, verified end-to-end in QEMU)

The Phase 1 boot path is **Multiboot1 + manual long-mode bringup**. See
[`architecture-decisions/0001-bootloader-choice.md`](architecture-decisions/0001-bootloader-choice.md)
for the rationale.

1. QEMU's built-in multiboot1 loader is handed `zig-out/bin/zigix-kernel.mb`
   (the elf32-i386 form — see "ELF format quirk" below).
2. The loader places the LOAD segments at their linker-script addresses
   (text starts at `0x100000`) and jumps to `_start` in 32-bit protected
   mode with `EAX = 0x2BADB002`, `EBX = mbi-ptr`, `IF = 0`, paging off.
3. `kernel/arch/x86_64/boot/start.S` builds identity paging for the first
   1 GiB (`PML4[0] -> PDPT[0]`, where `PDPT[0]` is a single 1 GiB huge
   page), enables `CR4.PAE`, sets `EFER.LME`, enables `CR0.PG`, loads a
   64-bit GDT, and far-jumps to `long_mode_start`.
4. `long_mode_start` reloads segment selectors and calls `kmain` (Zig).
5. `kmain` initializes COM1 and prints `[ZIGIX:BOOT:START]`,
   `[ZIGIX:TOOLCHAIN:bun-zig=<v>]`, `[ZIGIX:BOOT:OK]`.
6. `kmain` writes `0x10` to the `isa-debug-exit` device on port `0xF4`,
   causing QEMU to exit with status `33` so CI finishes in milliseconds
   instead of waiting for the harness timeout.

### ELF format quirk

QEMU's `-kernel` multiboot loader rejects ELF64 outright ("Cannot load
x86-64 image, give a 32bit one."). We work around this by post-processing
the Zig-produced ELF64 with `objcopy -O elf32-i386` to produce
`zigix-kernel.mb`. The byte layout is unchanged; only the ELF header's
class/machine fields differ. All load addresses fit comfortably in 32
bits, so the conversion is loss-free for the loader's purposes. The
64-bit instructions inside the file are only executed after `start.S`
has set `EFER.LME` and enabled paging, by which point the CPU is in long
mode and accepts them.

## Boot flow (later phases — not yet implemented)

7. Kernel installs GDT/IDT and basic exception handlers.
8. Kernel parses the bootloader's memory map.
9. Kernel initializes the physical-page allocator and the heap, prints
   `[ZIGIX:MM:OK]`.
10. Kernel mounts the initramfs and prints `[ZIGIX:VFS:OK]`.
11. Kernel sets up the syscall table and prints `[ZIGIX:SYSCALL:OK]`.
12. Kernel loads `/init` from initramfs and drops to user mode.
13. Init prints `[ZIGIX:INIT:OK]`.

Each step is a phase in the roadmap.
