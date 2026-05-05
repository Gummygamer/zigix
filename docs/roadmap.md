# Zigix Roadmap

Each phase ships a vertical slice and must be boot-tested or host-tested before
the next one starts. Tests come first; broad unfinished architecture is
rejected.

> **Reading this from a cold start?** Jump to
> [§ Where to pick up](#where-to-pick-up). Every "phase" section below has
> three parts: what it must produce, the marker(s) the smoke parser expects,
> and any tactical hints from the previous phase that affect it.

## Status at a glance

| Phase | Title                                | State        | Verified by |
| :---- | :----------------------------------- | :----------- | :---------- |
| 0     | Toolchain + smoke-test skeleton      | done         | `ci/local.sh` |
| 1     | First boot                           | done         | QEMU smoke: `[ZIGIX:BOOT:START]` + `[ZIGIX:BOOT:OK]`, exit 33 |
| 2     | Kernel logging, panic, test runner   | done         | `[ZIGIX:TEST:PASS:kernel_smoke]` |
| 3     | Memory management                    | done         | `[ZIGIX:MM:OK]` |
| 4     | Interrupts and timer                 | done         | `[ZIGIX:TEST:PASS:exception_caught]` |
| 5     | VFS and initramfs                    | done         | `[ZIGIX:VFS:OK]` |
| 6     | Syscall ABI v0                       | next         | `[ZIGIX:SYSCALL:OK]` |
| 7     | ELF64 static loader                  | pending      | `[ZIGIX:ELF:OK]` |
| 8     | User mode + init                     | pending      | `[ZIGIX:INIT:START]` + `[ZIGIX:INIT:OK]` |
| 9–15  | Userspace expansion                  | pending      | per-phase markers TBD |

## Phase 0 — Toolchain and smoke-test skeleton ✅

- [x] Repo skeleton.
- [x] `tools/toolchain/zig-bun` wrapper that refuses unset / system Zig.
- [x] `tools/toolchain/check-bun-zig.sh`.
- [x] `docs/bun-zig-toolchain.md` with the real pin (commit
      `04e7f6ac1e009525bc00934f20199c68f04e0a24`, version `0.15.2`).
- [x] `docs/roadmap.md`, `docs/testing.md`, `docs/architecture.md`.
- [x] `build.zig` + `build.zig.zon`.
- [x] QEMU runner (`tools/qemu/run.sh`) that fails clearly when no kernel
      is built, isa-debug-exit-aware.
- [x] Serial-marker parser (`tools/qemu/smoke_test.py`).
- [x] `ci/local.sh` (16 checks; positive and negative).
- [x] GitHub Actions: host-checks job + qemu-smoke job that downloads
      Bun Zig and runs the full pipeline.

## Phase 1 — First boot ✅

- [x] Multiboot1 boot stub in `kernel/arch/x86_64/boot/start.S`: identity
      paging for first 1 GiB, PAE → EFER.LME → CR0.PG, far-jump to long mode.
- [x] Linker script (`kernel/arch/x86_64/linker.ld`) at `0x100000`.
- [x] 16550 UART driver (`kernel/arch/x86_64/serial.zig`).
- [x] `kmain` (`kernel/core/main.zig`) emits the two boot markers and
      `[ZIGIX:TOOLCHAIN:bun-zig=<v>]`.
- [x] Panic override (`kernel/core/panic.zig`) emits `[ZIGIX:PANIC:<msg>]`.
- [x] `build.zig` `kernel` step (LLVM backend forced; objcopy → elf32-i386
      so QEMU's `-kernel` accepts it).
- [x] `validate-kernel-elf` step verifies multiboot1 magic in first 8 KiB.
- [x] QEMU smoke test sees both markers; isa-debug-exit (port `0xF4`,
      value `0x10`) makes QEMU exit status 33.

ADR: see `docs/architecture-decisions/0001-bootloader-choice.md`.

## Phase 2 — Kernel logging, panic, in-kernel test runner ✅

**Goal:** make later phases observable. Phase 1 prints fixed strings; Phase 2
introduces a logger and a test registry so later milestones can report
`[ZIGIX:TEST:PASS:<name>]` without each one rebuilding the plumbing.

Concrete deliverables:

- `kernel/core/log.zig`: leveled `print`/`println` wrapping `serial.write`,
  with a small `std.fmt`-style formatter (the freestanding subset — no
  allocator). Levels: `info`, `warn`, `err`. All output is line-buffered
  and ends with `\n`.
- Panic enrichment: include source location and a short hex dump of saved
  registers (we don't have backtraces yet — that's Phase 4 territory).
- `kernel/core/testing.zig`: a comptime test registry. Each test is
  `pub const TEST_<name> = Test{...};`; the runner walks declarations of
  a known marker module and emits `[ZIGIX:TEST:PASS:<name>]` /
  `[ZIGIX:TEST:FAIL:<name>:<reason>]`.
- One canonical kernel-side smoke test, `kernel_smoke`, that checks
  trivially-true things (port I/O round-trip, `serial.writeLine` doesn't
  truncate). Its purpose is to prove the registry works, not to find bugs.
- New phase entry in `tools/qemu/smoke_test.py` `PHASES` (already there:
  `phase2`).

Acceptance: `tools/toolchain/zig-bun build qemu-smoke` sees both Phase 1
markers plus `[ZIGIX:TEST:PASS:kernel_smoke]`.

Hints from Phase 1 you should keep in mind:

- Don't drop the `isa-debug-exit` write — Phase 2 still needs CI to
  finish in milliseconds.
- Don't introduce dynamic allocation here. The test runner runs before
  Phase 3 ships an allocator.

## Phase 3 — Memory management ✅

**Goal:** the kernel knows what physical memory exists and can hand out
pages and small heap allocations.

- [x] Parse the multiboot1 memory map (`mbi->mmap_*`). The boot stub
  preserves the bootloader's `EAX/EBX` handoff values and passes them to
  `kmain` as the multiboot magic + info pointer.
- [x] Physical-page allocator: bitmap or stack of free 4 KiB frames over
  usable regions. Must reserve the kernel's own image and the multiboot
  info structure.
- [x] Page-table abstraction: replace the boot 1 GiB huge page with proper
  4 KiB / 2 MiB mappings; introduce `kernel/mm/paging.zig` with
  `mapPage`, `unmapPage`, `walk`. Identity map for now; high-half is
  Phase 8 territory.
- [x] Kernel heap: simple bump or freelist allocator on top of the page
  allocator. Wire as the Zig allocator interface so future code can use
  `std.ArrayList` etc.
- [x] Marker: `[ZIGIX:MM:OK]` after self-test allocates and frees a page,
  walks a virtual address, and round-trips a heap allocation.

## Phase 4 — Interrupts and timer

**Goal:** the kernel can take an exception without rebooting, and a
periodic tick is incrementing.

- [x] GDT (replace the boot one with a kernel-owned GDT in writable memory),
  TSS for ring transitions later.
- [x] IDT with handlers for the architectural exceptions (DE, UD, GP, PF,
  DF). Page-fault handler at minimum prints CR2 + error code and panics
  cleanly; later it will populate on-demand.
- [x] PIC remap (or APIC/IO-APIC if we want to skip the legacy PIC) and a
  timer (PIT or HPET) firing at a known rate. Tick counter visible to
  the rest of the kernel.
- [x] Self-test: deliberately trigger a `#UD` from a test entry, catch it,
  emit `[ZIGIX:TEST:PASS:exception_caught]`, then return.

No new top-level marker — the goal is "Phase 5+ can rely on traps not
being triple-faults."

## Phase 5 — VFS and initramfs

- [x] VFS interface: `Inode`, `Dir`, `File`, `mount`, `lookup`, `read`,
  `readdir`. Memory-only for now; no disk driver yet.
- [x] `memfs` backing the root.
- [x] `initramfs` format: keep it dirt-simple (cpio newc or a custom TLV
  with a 1-page header); a host-side packer in `tools/mkinitramfs/`.
- [x] Path normalization with host-side unit tests in `tests/host/` that
  exercise edge cases (`..` past root, trailing slash, double slash,
  empty component). These run via `host-test` and don't require QEMU.
- [x] Boot-time mount of the initramfs blob shipped via multiboot1 modules.
- [x] Marker: `[ZIGIX:VFS:OK]` after `lookup("/init")` succeeds.

## Phase 6 — Syscall ABI v0

- Choose Linux x86_64 numbers and register layout (RAX = num, RDI/RSI/
  RDX/R10/R8/R9 = args, returns in RAX, errors as `-errno`). Document in
  `docs/syscall-abi.md`.
- Syscall entry via `syscall`/`sysret` MSR setup; user→kernel stack
  swap via `swapgs` + per-CPU TSS RSP0.
- Dispatcher (`kernel/syscall/dispatch.zig`) and number registry
  (`kernel/syscall/numbers.zig`).
- Handlers, in this order: `write` (so userspace can speak markers),
  `exit`, `read`, `open`, `close`, `lseek`, `stat`/`fstat`. Anything
  more is Phase 9.
- Errno mapping shared with future libc.
- Marker: `[ZIGIX:SYSCALL:OK]` from a kernel self-test that issues
  `int 0x80`/`syscall` against itself.

## Phase 7 — ELF64 static loader

- Pure parser in `kernel/elf/parse.zig` with malformed-input fuzz tests
  on the host (random bytes, truncated headers, overlapping segments,
  PT_LOAD past EOF). These run under `host-test`.
- Loader maps PT_LOAD segments into a fresh address space, builds a
  user stack, places `argv`/`envp`/auxv.
- Marker: `[ZIGIX:ELF:OK]` after loading a hand-crafted hello-world ELF
  in-kernel and validating its entry pointer.

## Phase 8 — User mode and init

- Ring 3 transition via `iretq`/`sysret`. Kernel and user mappings
  coexist; consider switching to higher-half kernel here if not earlier.
- A trivial first-init: writes `[ZIGIX:INIT:START]`, then
  `[ZIGIX:INIT:OK]`, then `exit(0)`. Source lives in `userspace/init/`.
- Build it as a separate Zig executable targeting freestanding x86_64
  with the syscall stub from Phase 6.
- Markers (in order): `[ZIGIX:INIT:START]`, `[ZIGIX:INIT:OK]`.

## Phase 9 — File descriptors and basic Unix I/O

- Per-process file table, dup, close-on-exec.
- Pipes (`pipe`, blocking semantics), basic read/write to inodes
  served by memfs / initramfs.

## Phase 10 — `exec` and process lifecycle

- `fork` (or just `posix_spawn` if `fork` proves too painful for the
  current paging design), `execve`, `waitpid`, `_exit`.
- Process table, pid allocator.

## Phase 11 — Tiny shell

- `userspace/tinysh/`: argv split, builtin `cd` / `exit`, run external
  commands via `execve`.

## Phase 12 — libc strategy

- Decide newlib first (smaller surface) vs musl (closer to Linux ABI).
  Adapt in `userspace/libc_shim/` until then.

## Phase 13 — POSIX expansion

- `dup2`, `chdir`, signals (subset: `SIGINT`, `SIGTERM`, `SIGCHLD`),
  more file ops (`unlink`, `rename`, `mkdir`).

## Phase 14 — BusyBox or Toybox port

- First serious userspace beyond hand-written stubs. Port the smaller
  one first.

## Phase 15 — GNU tools later

- Only after BusyBox/Toybox runs cleanly on the kernel. coreutils,
  bash, etc.

## Hard rules

- **Never bypass `tools/toolchain/zig-bun`.** Calling system `zig`
  silently breaks the toolchain pin. CI proves the wrapper refuses to
  run with `ZIGIX_BUN_ZIG` unset.
- **No phase ships without a marker the smoke parser checks.** If a
  phase produces no observable serial output, it produced nothing.
- **Every milestone records compiler identity** via the
  `[ZIGIX:TOOLCHAIN:...]` line in its smoke log.
- **Don't ship plumbing without a user.** A logger ships with the test
  that uses it; an allocator ships with the code that allocates.

## Where to pick up

The next thing to do, concretely:

1. Source `.env`, then run `ci/local.sh` to confirm the Phase 4 baseline
   and Phase 5 VFS smoke still pass.
2. Read `docs/syscall-abi.md` and the Phase 6 notes above.
3. Specify syscall numbers/registers in `docs/syscall-abi.md`.
4. Add the syscall entry/dispatcher skeleton and emit `[ZIGIX:SYSCALL:OK]`
   from a kernel self-test.

Operational reminders for a fresh session:

- The Bun-Zig binary path is in `.env` (`ZIGIX_BUN_ZIG=...`); source it
  before running any build (`set -a; . .env; set +a`).
- The smoke parser's `PHASES` table already encodes Phase 2-8 marker
  expectations — extend it, don't rewrite it.
- `use_llvm = true` on the kernel executable is non-negotiable at Zig
  0.15.2; the self-hosted x86_64 backend miscompiles freestanding code.
- `objcopy -O elf32-i386` is non-negotiable too; QEMU's `-kernel`
  rejects ELF64.
