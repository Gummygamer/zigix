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

Phase 10 is in progress: Zigix boots under QEMU, initializes memory management
and interrupts, mounts a Multiboot-loaded initramfs on a small VFS/memfs root,
installs syscall ABI v0, validates a static ELF64 load plan, maps and enters a
freestanding ring-3 `/init`, emits `[ZIGIX:INIT:START]` and
`[ZIGIX:INIT:OK]` through syscalls, and has per-process descriptor tables,
`dup`, close-on-exec metadata, basic pipe read/write coverage, and the first
process-table/PID lifecycle slice with `wait4` reaping coverage. The initial
`execve` slice replaces the current static ELF image, applies close-on-exec
descriptor cleanup, builds a bounded argv/envp initial stack, and is exercised
by `/init` execing `/exec-ok`. Each process now owns its user address space
explicitly via a per-PID region registry; `execve` drains the calling
process's regions and unmaps them instead of scanning a fixed range. The first
posix_spawn-style preparation slice can allocate a separate child page-table
root, load a static child image in that target address space, and register
PT_LOAD + stack regions against the child PID, with QEMU coverage via
`process_page_tables` and `spawn_child_image`; runnable child processes still
need scheduler context switching and kernel stack ownership rules before two
userspaces can coexist. auxv is still future work.

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
| `tools/toolchain/zig-bun build qemu-smoke`      | Boot the kernel in QEMU and verify Phase 10 serial markers.     |
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
