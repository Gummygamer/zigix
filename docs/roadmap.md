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
| 6     | Syscall ABI v0                       | done         | `[ZIGIX:SYSCALL:OK]` |
| 7     | ELF64 static loader                  | done         | `[ZIGIX:ELF:OK]` |
| 8     | User mode + init                     | done         | `[ZIGIX:INIT:START]` + `[ZIGIX:INIT:OK]` |
| 9     | File descriptors and basic Unix I/O  | done         | `[ZIGIX:TEST:PASS:syscall_fd_table]`, `[ZIGIX:TEST:PASS:syscall_pipe]` |
| 10    | `exec` and process lifecycle         | in progress  | `[ZIGIX:TEST:PASS:syscall_pipe_blocking]`, `[ZIGIX:TEST:PASS:process_lifecycle]`, `[ZIGIX:TEST:PASS:process_wait_nohang]`, `[ZIGIX:TEST:PASS:process_wait_blocking]`, `[ZIGIX:TEST:PASS:process_address_space]`, `[ZIGIX:TEST:PASS:process_page_tables]`, `[ZIGIX:TEST:PASS:process_scheduler_groundwork]`, `[ZIGIX:TEST:PASS:process_run_queue]`, `[ZIGIX:TEST:PASS:process_fd_tables]`, `[ZIGIX:TEST:PASS:process_spawn_resume]`, `[ZIGIX:TEST:PASS:spawn_child_image]`, `[ZIGIX:TEST:PASS:posix_spawn_handoff]`, `[ZIGIX:TEST:PASS:execve_load]`, `[ZIGIX:TEST:PASS:execve_argv_stack]`, `[ZIGIX:INIT:START]` + `[ZIGIX:INIT:OK]` |
| 11–16 | Userspace expansion                  | pending      | per-phase markers TBD |

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

- [x] Choose Linux x86_64 numbers and register layout (RAX = num, RDI/RSI/
  RDX/R10/R8/R9 = args, returns in RAX, errors as `-errno`). Document in
  `docs/syscall-abi.md`.
- [x] Syscall entry via `int 0x80` for the Phase 6 self-test. The ABI uses
  the Linux x86_64 `syscall` register layout; `syscall`/`sysret` and
  `swapgs` remain a later entry-path upgrade.
- [x] Dispatcher (`kernel/syscall/dispatch.zig`) and number registry
  (`kernel/syscall/numbers.zig`).
- [x] Handlers, in this order: `write` (so userspace can speak markers),
  `exit`, `read`, `open`, `close`, `lseek`, `stat`/`fstat`. Anything
  more is Phase 9.
- [x] Errno mapping shared with future libc.
- [x] Marker: `[ZIGIX:SYSCALL:OK]` from a kernel self-test that issues
  `int 0x80`/`syscall` against itself.

## Phase 7 — ELF64 static loader

- [x] Pure parser in `kernel/elf/parse.zig` with malformed-input fuzz tests
  on the host (random bytes, truncated headers, overlapping segments,
  PT_LOAD past EOF). These run under `host-test`.
- [x] Static load-plan validation checks PT_LOAD segments and verifies the
  entry point lands inside an executable segment.
- [x] Marker: `[ZIGIX:ELF:OK]` after loading a hand-crafted hello-world ELF
  in-kernel and validating its entry pointer.

Actual ring-3 mappings, stack construction, `argv`/`envp`, and auxv become
active in Phase 8 when user mode exists.

## Phase 8 — User mode and init

- [x] Ring 3 transition via `iretq`. Kernel and user mappings coexist;
  consider switching to a higher-half kernel in a later memory-management pass.
- [x] A trivial first-init: writes `[ZIGIX:INIT:START]`, then
  `[ZIGIX:INIT:OK]`, then `exit(0)`. Source lives in `userspace/init/`.
- [x] Build it as a separate Zig executable targeting freestanding x86_64
  with the syscall stub from Phase 6.
- [x] Markers (in order): `[ZIGIX:INIT:START]`, `[ZIGIX:INIT:OK]`.

Notes: Phase 8 still uses `int 0x80`; `syscall/sysret`, proper copy-in /
copy-out, process tables, and per-process file descriptors move to later
userspace phases.

## Phase 9 — File descriptors and basic Unix I/O

- [x] Per-process file table, `dup`, close-on-exec metadata.
- [x] `pipe`, descriptor endpoint plumbing, and basic read/write self-test.
- [x] Blocking pipe semantics once scheduling/process lifecycle exists.
- [ ] Writable inode-backed files beyond read-only memfs / initramfs.

## Phase 10 — `exec` and process lifecycle

- [x] Process table, pid allocator.
- [x] `wait4` reaps exited children in the process table.
- [x] Initial `execve(path, NULL, NULL)` syscall wiring around the static ELF
  loader, with close-on-exec descriptor handling. This is intentionally
  partial: it replaces the current user image and stack pages, but explicit
  process address-space ownership remains future work. The QEMU smoke path now
  proves the success case by having `/init` exec `/exec-ok`, which emits
  `[ZIGIX:INIT:OK]`.
- [x] Bounded `execve` argv/envp copy-in and initial userspace stack
  construction. Phase 10 caps each vector at eight strings and each string at
  256 bytes until real copy-in validation and larger userspace workloads exist.
  The `/init` smoke path now execs `/exec-ok` with non-null argv/envp, and the
  kernel test `execve_argv_stack` validates the initial stack shape.
- [x] Shared userspace syscall wrappers for the Phase 10 smoke binaries,
  including `_exit` via the Linux `exit_group` number and `waitpid` as a
  wrapper over `wait4(pid, status, options, NULL)`.
- [x] Initial `wait4` semantics distinguished no child from a live child,
  supported `WNOHANG`, and returned `EAGAIN` for waits that would block before
  the blocking spawned-child wait path landed.
- [x] Per-process address-space ownership: each process tracks the user
  regions it owns (PT_LOAD segments + stack) in its process-table entry.
  `execve` drains the current process's region list and unmaps each contained
  page instead of scanning the fixed `USER_IMAGE_BASE..USER_IMAGE_LIMIT`
  range. `MAX_PROCESS_REGIONS = 16` is enough for the current smoke binaries
  but will need a real VMA structure before posix_spawn can give a child its
  own pages independently of the parent.
- [x] Child-targeted user image ownership: the process table now exposes
  explicit-PID region registration/draining in addition to the current-process
  wrappers, and the ELF loader can map a static user image while registering
  PT_LOAD + stack pages against a child PID. The `spawn_child_image` kernel
  test verifies the parent region list stays empty, the child owns the loaded
  regions, and child release drains/unmaps those regions. This started as a
  preparation path and is now backed by separate page-table roots in the next
  item.
- [x] Per-process page-table roots: child processes now get their own PML4
  with the low 1 GiB kernel identity mapping shared and userspace mappings
  isolated. The ELF loader switches to the target process address space while
  mapping and copying a child image, then restores the caller's address space.
  The `process_page_tables` and expanded `spawn_child_image` tests prove child
  user pages are visible in the child address space but absent from the
  parent. This removes the previous single-active-address-space blocker for a
  narrow spawn handoff; runnable concurrent processes still need scheduler
  context switching and kernel stack ownership.
- [x] Narrow `posix_spawn` handoff prototype: a Zigix extension syscall creates a child
  PID, loads a static image and initial stack into the child's page-table root,
  switches the current process to that child, and enters ring 3. This proved
  the one-way handoff before parent resumption and blocking wait support
  landed.
- [x] Scheduler groundwork: process entries now distinguish `runnable`,
  `running`, `blocked`, and `exited`, spawned children own a kernel stack, and
  `switchTo` moves CR3 while making the previous current process runnable
  again. The `process_scheduler_groundwork` test locks down the parent
  resumption state model that the next `posix_spawn` slice will use.
- [x] Minimal spawn resume path: the spawn path saved the parent's kernel
  continuation, switches the TSS kernel stack and CR3 to the child, runs the
  child image, and resumes the parent when the child exits so the syscall can
  return the child PID. This was still cooperative and child-completion driven:
  the parent resumes after the spawned child exits, then reaps it with `wait4`.
  `process_spawn_resume` covers the process-table/TSS state transition, and
  the userspace smoke path now waits for `/exec-ok` before `/init` exits.
- [x] Blocking `wait4` for spawned children: `posix_spawn` now prepares a
  runnable child and returns its PID before the child runs. A blocking
  `wait4`/`waitpid` saves the parent's kernel continuation, parks it, switches
  to the child's page-table root and TSS stack, enters the child image, then
  wakes and resumes the parent when the child exits so `wait4` can reap it.
  `WNOHANG` still returns `0` for live children. The
  `process_wait_blocking` test and `/init` smoke path cover the handoff.
- [x] First blocking pipe waiter path: empty pipe reads with live writers and
  full pipe writes now park the current process in a pipe wait queue and wake
  waiters on the opposite endpoint when data or space becomes available. The
  syscall still returns `EAGAIN` after parking until blocked syscalls can save
  enough continuation state to resume transparently. The
  `syscall_pipe_blocking` test covers reader and writer park/wake behavior.
- [ ] `fork` is deferred. Unix fork semantics are still misleading without
  copy-on-write and a scheduler that can run separate address spaces; prefer
  `posix_spawn` as the next process-creation slice.
- [x] General scheduler run queues. Runnable processes now enter a FIFO
  scheduler queue on spawn/wake, leave it when blocked/exited/selected, and
  direct switches requeue the previous runner when it remains runnable. The
  `process_run_queue` test covers ordering, wake enqueueing, and switch
  dequeue behavior. The scheduler is still cooperative; timer-driven
  preemption and full syscall blocking/resume remain later work.
- [x] Per-process descriptor table isolation for spawned children. The syscall
  layer now keeps fd tables keyed by PID, lazily inherits a child table from
  its parent on first syscall use, and applies close-on-exec to the child table
  without mutating the parent. The `process_fd_tables` test covers inherited
  descriptors, child-only close, and parent descriptor survival.

### Phase 10 dependency map

Phase 10 grew because several Unix process concepts depend on each other. Do
not start Phase 11 by adding shell code until the Phase 10 closeout gate below
is true.

Completed dependency chain:

1. Process identity: PID allocation, process table slots, parent/child
   relationships, exit state, and `wait4` reaping.
2. User image replacement: static ELF load planning, `execve`, close-on-exec,
   bounded argv/envp copy-in, and initial stack construction.
3. Address-space ownership: per-process user-region tracking, child-targeted
   image loading, and per-process page-table roots.
4. Cooperative switching base: kernel stack ownership, TSS stack switching,
   CR3 switching, process run states, saved parent continuations, and FIFO
   runnable queues.
5. Spawn/wait handoff: `posix_spawn` prepares a runnable child; blocking
   `wait4` enters the child image, resumes the parent on child exit, and then
   reaps the child.
6. Descriptor isolation: spawned children lazily inherit per-PID fd tables,
   close-on-exec is applied to the child table, and child close operations do
   not mutate the parent.
7. Pipe waiter groundwork: empty reads and full writes can park and wake
   processes through pipe wait queues and the run queue, but the syscall still
   returns `EAGAIN` instead of transparently resuming the original call.

Remaining Phase 10 closeout gates:

- [ ] Record an explicit deferral decision for transparent pipe syscall
  resume. The current `int 0x80` dispatcher only receives syscall arguments
  and returns a value; transparent retry needs saved syscall continuation state
  across scheduler handoff. This should not block a tiny shell unless Phase 11
  includes pipelines or blocking stdin.
- [ ] Record an explicit deferral decision for `fork`. `fork` depends on
  copy-on-write or eager address-space cloning plus scheduler support for
  independently runnable address spaces. Phase 11 should keep using
  `posix_spawn`/`waitpid`.
- [ ] Decide whether `cd` in Phase 11 is shell-local path resolution or a real
  `chdir` syscall. Real `chdir` pulls Phase 14 cwd semantics forward; a
  shell-local cwd lets Phase 11 run commands without expanding the kernel ABI.
- [ ] Add a Phase 11 smoke marker plan before writing `tinysh`, so the first
  shell slice has a concrete acceptance test.
- [ ] Run `ci/local.sh` after the closeout documentation and marker changes,
  then mark Phase 10 as done only if the Phase 10 smoke still passes.

Intentional deferrals after Phase 10:

- Timer-driven preemption.
- Transparent blocking syscall resume for pipes and later devices.
- `fork`.
- `dup2`, `chdir`, signals, unlink/rename/mkdir, and writable inode-backed
  files unless Phase 11 or Phase 12 deliberately pulls one forward with a
  marker.
- Auxv and libc-scale process startup details.

## Phase 11 — Tiny shell

Phase 11 is not an interactive shell. It is the first userspace program that
depends on the Phase 10 process work and proves foreground command execution
without requiring console input yet.

Dependencies from Phase 10:

- `posix_spawn` + `waitpid` for external command execution.
- Per-process fd tables so child descriptor cleanup does not corrupt the shell.
- Bounded argv stack construction so the shell can pass split arguments to a
  command.
- Cooperative wait handoff so the shell can launch one foreground command and
  regain control after it exits.

Concrete first slice:

- [ ] `userspace/tinysh/`: non-interactive `-c` mode first.
- [ ] Parse one command line into whitespace-separated argv. No quoting,
  escaping, variables, pipes, or redirection in the first slice.
- [ ] Builtin `exit`.
- [ ] Builtin `cd` only after the cwd decision above is made.
- [ ] Run external commands through `posix_spawn` + `waitpid`; keep `execve`
  available for replacing the current image, not for the shell's normal
  foreground command path.
- [ ] Initramfs packaging for `/tinysh`.
- [ ] QEMU smoke path: `/init` runs `/tinysh -c /exec-ok`; expected markers
  include `[ZIGIX:TEST:PASS:tinysh_smoke]` plus the existing init markers.

## Phase 12 — Interactive console shell

Phase 12 is the first real interactive shell milestone. It should start only
after Phase 11 proves `tinysh -c` command execution, because interactive input
adds kernel console and test-harness dependencies that should not be mixed into
the first shell slice.

Dependency path:

1. Console input source: make serial input the first stdin backend because the
   existing QEMU path is already serial-oriented. PS/2 keyboard support can
   follow later, but it should not block the first interactive shell.
2. Stdin descriptor semantics: change fd `0` from permanent EOF to a console
   read endpoint backed by an input ring buffer.
3. Waitable console reads: when the input buffer is empty, `read(0, ...)`
   must either block/resume through the scheduler or return `EAGAIN` with a
   shell retry policy. Prefer fixing transparent syscall resume here if it has
   not been done earlier, because interactive input is the first user-visible
   consumer that truly needs it.
4. QEMU input harness: add a runner mode that can feed scripted serial input
   to the guest and still capture serial output for marker parsing. Keep the
   current output-only smoke path for non-interactive tests.
5. `tinysh` interactive mode: prompt, read one line, split argv using the
   Phase 11 parser, run one foreground command with `posix_spawn` + `waitpid`,
   then prompt again.
6. Shell-local cwd or kernel cwd: implement the `cd` decision recorded during
   Phase 10 closeout. If `cd` is shell-local, external command lookup must use
   normalized absolute paths. If `cd` is a kernel syscall, add `chdir`/cwd
   tests here and remove it from the Phase 14 backlog.

Concrete deliverables:

- [ ] Serial RX ring buffer and `read(0, ...)` path.
- [ ] Console-read blocking/resume behavior, or an explicitly tested
  nonblocking retry policy if transparent syscall resume remains deferred.
- [ ] Scriptable QEMU serial-input smoke runner.
- [ ] `tinysh` interactive loop with prompt and foreground command execution.
- [ ] QEMU smoke path feeds `/exec-ok\nexit\n` to `/tinysh` and expects
  `[ZIGIX:TEST:PASS:tinysh_interactive]` plus `[ZIGIX:INIT:OK]`.

Non-goals for the first interactive shell:

- Pipes, redirection, quoting, environment expansion, globbing, job control,
  signals, terminal modes, command history, and cursor editing.
- PS/2 keyboard input, unless serial input proves unsuitable.

## Phase 13 — libc strategy

- Decide newlib first (smaller surface) vs musl (closer to Linux ABI).
  Adapt in `userspace/libc_shim/` until then.

## Phase 14 — POSIX expansion

- `dup2`, `chdir`, signals (subset: `SIGINT`, `SIGTERM`, `SIGCHLD`),
  more file ops (`unlink`, `rename`, `mkdir`).

## Phase 15 — BusyBox or Toybox port

- First serious userspace beyond hand-written stubs. Port the smaller
  one first.

## Phase 16 — GNU tools later

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

1. Source `.env`, then run `ci/local.sh` to confirm the Phase 10 smoke
   still passes.
2. Read the Phase 10 notes above.
3. Work through the Phase 10 closeout gates in order: pipe resume deferral,
   `fork` deferral, Phase 11 `cd`/cwd decision, Phase 11 marker plan.
4. Update the status table only after those decisions are written down and
   `ci/local.sh` still passes.
5. Start Phase 11 with the non-interactive `tinysh -c /exec-ok` smoke path,
   not with an interactive shell.
6. Treat the interactive shell as Phase 12 work: serial stdin, console read
   semantics, a scriptable QEMU input harness, then the `tinysh` prompt loop.

Operational reminders for a fresh session:

- The Bun-Zig binary path is in `.env` (`ZIGIX_BUN_ZIG=...`); source it
  before running any build (`set -a; . .env; set +a`).
- The smoke parser's `PHASES` table already encodes Phase 2-8 marker
  expectations — extend it, don't rewrite it.
- `use_llvm = true` on the kernel executable is non-negotiable at Zig
  0.15.2; the self-hosted x86_64 backend miscompiles freestanding code.
- `objcopy -O elf32-i386` is non-negotiable too; QEMU's `-kernel`
  rejects ELF64.
