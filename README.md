# Zigix

A small, test-driven, Unix-compatible experimental operating system written
primarily in [Zig](https://ziglang.org), compiled with the **Bun fork of the
Zig compiler**.

Zigix is **not** a Linux replacement. The goal is a clean, hackable, Zig-native
OS with:

- fast iteration;
- explicit low-level code;
- strong automated testing;
- a small but real Unix compatibility layer;
- static ELF support first;
- musl/newlib compatibility as the first ecosystem bridge;
- BusyBox/Toybox as the first realistic userspace target;
- GNU tools later;
- explicit investigation of whether Bun's Zig fork improves the OS development
  loop.

## Status

Phase 14 has started: Zigix boots under QEMU, initializes memory management
and interrupts, mounts a Multiboot-loaded initramfs on a small VFS/memfs root,
installs syscall ABI v0, validates a static ELF64 load plan, maps and enters a
freestanding ring-3 `/init`, runs `/tinysh -c /exec-ok` for the Phase 11
non-interactive shell smoke path, and runs an interactive scripted
`/tinysh` session for Phase 12. Phase 13 chooses newlib as the first libc
target and adds a minimal `userspace/libc_shim/` syscall hook layer. The
first Phase 14 shell/POSIX usability slices add `dup2`, `chdir`, and process
identity syscalls, directory reads, writable memfs, and shell redirection with the markers `[ZIGIX:TEST:PASS:syscall_dup2]`,
`[ZIGIX:TEST:PASS:syscall_chdir]`, and
`[ZIGIX:TEST:PASS:syscall_getpid]`,
`[ZIGIX:TEST:PASS:syscall_getdents64]`,
`[ZIGIX:TEST:PASS:syscall_writable_memfs]`, and
`[ZIGIX:TEST:PASS:tinysh_redirection]`. Relative `open`, `stat`, `execve`, and
`posix_spawn` paths now resolve against per-process cwd, and `tinysh` has a
`cd` builtin. The Phase 13 marker remains
`[ZIGIX:TEST:PASS:libc_shim_newlib]`, emitted by `/init` through the newlib
`_write` hook. The Phase 12 interactive marker remains
`[ZIGIX:TEST:PASS:tinysh_interactive]`, emitted after `tinysh` reads
`cd /`, runs relative `exec-ok` from serial stdin, starts it with
`posix_spawn`, waits for it with `waitpid`, reads `exit`, and terminates
cleanly.

The kernel has per-process descriptor tables, `dup`, close-on-exec metadata,
basic pipe read/write coverage, process-table/PID lifecycle coverage,
per-process address-space roots, bounded argv/envp stack construction, a
cooperative `posix_spawn`/blocking-`wait4` handoff, process-aware pipe
park/wake queues, a FIFO runnable queue, and a polled serial stdin path for
`read(0, ...)`. Timer-driven preemption, transparent blocking syscall resume,
`fork`, auxv, and richer shell behavior are future work.

See [`docs/roadmap.md`](docs/roadmap.md) for the phased plan and
[`docs/bun-zig-toolchain.md`](docs/bun-zig-toolchain.md) for the toolchain
contract.

## Toolchain

Zigix uses the **Bun fork of the Zig compiler** as its primary toolchain. The
project refuses to silently fall back to system Zig.

```sh
# Point ZIGIX_BUN_ZIG at the absolute path of the Bun-fork Zig binary.
export ZIGIX_BUN_ZIG=/absolute/path/to/bun-zig
tools/toolchain/check-bun-zig.sh
```

The canonical Zig invocation for the project is the wrapper
[`tools/toolchain/zig-bun`](tools/toolchain/zig-bun). Use it instead of `zig`
directly.

## Building and testing

The build entry points are intentionally thin:

| Command                                | What it does                                                     |
| -------------------------------------- | ---------------------------------------------------------------- |
| `tools/toolchain/check-bun-zig.sh`     | Verify the Bun Zig toolchain is configured. Logs identity.       |
| `tools/toolchain/zig-bun build check-toolchain` | Same check, via `build.zig`. Requires Bun Zig to run.   |
| `tools/toolchain/zig-bun build host-test`       | Run host-side unit tests.                                       |
| `tools/toolchain/zig-bun build qemu-smoke`      | Boot the kernel in QEMU and verify Phase 14 serial markers.     |
| `tools/toolchain/zig-bun build qemu-smoke-scripted` | Boot QEMU with scripted COM1 input and verify Phase 12 interactive shell markers. |
| `ci/local.sh`                          | Run all host-side checks.                                        |

QEMU smoke runs are headless and machine-readable. See
[`docs/testing.md`](docs/testing.md) for the serial-log marker protocol.

## Layout

See [`docs/architecture.md`](docs/architecture.md) for the directory layout
and the architecture-independent / architecture-specific boundary.

## Contributing

Read [`docs/roadmap.md`](docs/roadmap.md) before starting work. Every milestone
must boot or run under automation, and every subsystem is tested before it is
expanded.
