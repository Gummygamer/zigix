# ADR 0001 — Bootloader choice for Phase 1

Date: 2026-05-03
Status: accepted (will be revisited if/when blockers appear)

## Context

The project spec lists two preferred boot paths for x86_64 Phase 1:
"UEFI or Limine boot protocol, whichever is simpler and more reliable for
the first bootable milestone."

Phase 1's only hard acceptance test is "boots in QEMU and prints
`[ZIGIX:BOOT:START]` and `[ZIGIX:BOOT:OK]` on the serial port." Anything
heavier than what that requires is overbuild for this phase.

## Options considered

| Option | Pros | Cons |
| --- | --- | --- |
| **Multiboot1** + `qemu-system-x86_64 -kernel` | Magic numbers fully published in the [Multiboot 1 spec](https://www.gnu.org/software/grub/manual/multiboot/multiboot.html). No external bootloader binaries. No ISO. Boots a single ELF directly. | Bootloader hands control in 32-bit protected mode; we have to do the long-mode transition ourselves (~150 lines of hand-checked asm). |
| **Limine** + ISO | Lands in 64-bit long mode for free. Cleaner kernel-side code. Active hobby ecosystem. | Requires external Limine binaries pinned to a protocol revision. The boot-protocol request structures use multi-word magic-number IDs that must be sourced from the Limine repository — fabricating any byte produces a kernel that silently fails to boot with no diagnostic. Also requires `xorriso` and an ISO build pipeline. |
| **UEFI** | Modern, no real-mode legacy. | Far more boilerplate (PE32+ image, UEFI services, exit-boot-services dance). Not "simpler" by any reasonable read. |

## Decision

**Use Multiboot1 with manual long-mode bringup for Phase 1.**

The deciding factor is *honesty under untested conditions*. The first cycles
of this project happen on a host with no Bun Zig and no QEMU, so kernel code
ships before it is verifiable. With Multiboot1, every constant in the boot
header (`0x1BADB002`, the flags word, the negated-sum checksum) is taken from
a published spec; with Limine, the request-struct magic IDs would have to be
copied from the Limine repository at the exact protocol revision we target,
and a single wrong word produces a silently-non-booting kernel.

Trading "more asm we can read line by line" for "fewer magic-number lookups
we cannot validate today" matches the project's stated preference for
*explicit low-level code* and *measurable engineering benefits over
speculative claims*.

## Consequences

- `kernel/arch/x86_64/boot/start.S` carries the multiboot header, a 32-bit
  protected-mode entry, an identity-mapped 1 GiB page table, the EFER/CR4/CR0
  bits to enter long mode, and the far jump into 64-bit code. Each step is
  commented in-line.
- The `qemu-smoke` step boots the produced ELF directly via
  `qemu-system-x86_64 -kernel`; no ISO, no external bootloader files.
- Higher-half mapping is **not** in Phase 1. We boot identity-mapped at
  `0x100000` and stay that way until Phase 3 sets up real paging.
- GDT/IDT beyond the bare minimum the long-mode transition requires is
  **not** in Phase 1. Phase 4 owns them.
- If multiboot1 turns out to block something we want (full-color framebuffer,
  ACPI, large memory maps), we revisit and adopt Limine. That's a Phase 1.5
  or Phase 3 conversation, not a Phase 1 one.

## Revisit triggers

- We need bootloader-provided framebuffer info → Limine wins.
- We need UEFI variables / EFI runtime services → UEFI wins.
- The 32→64-bit transition asm has a bug we cannot diagnose → cheaper to
  switch than to keep debugging.
