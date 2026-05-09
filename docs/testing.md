# Testing strategy

Zigix has five test layers. Every phase must add or extend tests in at least
one of them.

## Layer 0 — Toolchain tests

- The Bun Zig compiler exists at `$ZIGIX_BUN_ZIG`.
- Compiler identity is logged on every build/test run.
- Compiler path is explicit; accidental system Zig is rejected.
- All build commands go through `tools/toolchain/zig-bun`.
- Compile-time measurement script (`tools/toolchain/measure-compile.sh`)
  exists once there is something meaningful to measure.

Run with:

```sh
tools/toolchain/check-bun-zig.sh
```

## Layer 1 — Pure Zig unit tests

Run on the host with `tools/toolchain/zig-bun build host-test`. Targets:

- Data structures.
- Path normalization.
- ELF parser.
- Syscall table generation.
- VFS logic.
- Allocator metadata where possible.
- ABI encoding/decoding.

## Layer 2 — Host-side integration tests

- Build initramfs image.
- Validate ELF fixtures.
- Validate syscall-number generation.
- Validate userspace-program packaging.
- Validate toolchain-wrapper behavior.
- Validate the QEMU serial-log parser.

## Layer 3 — QEMU smoke tests

QEMU runs headless and writes the guest's serial port to a file. The default
`qemu-smoke` path is output-only and keeps the Phase 11 `/tinysh -c` gate.
Phase 12 also has `qemu-smoke-scripted`, which boots an alternate initramfs
whose `/init` launches interactive `/tinysh`, attaches COM1 to stdio, feeds
`tests/qemu/phase12-serial-input.txt` to the guest, captures the serial output
back to `zig-out/serial-scripted.log`, and parses the same **machine-readable
markers** out of that file.

### Serial-log marker protocol

```
[ZIGIX:TOOLCHAIN:<identity>]
[ZIGIX:INFO] <message>
[ZIGIX:WARN] <message>
[ZIGIX:ERR] <message>
[ZIGIX:BOOT:START]
[ZIGIX:BOOT:OK]
[ZIGIX:MM:OK]
[ZIGIX:VFS:OK]
[ZIGIX:SYSCALL:OK]
[ZIGIX:ELF:OK]
[ZIGIX:INIT:START]
[ZIGIX:INIT:OK]
[ZIGIX:TEST:PASS:<name>]
[ZIGIX:TEST:FAIL:<name>:<reason>]
[ZIGIX:PANIC:<message>]
```

Rules:

- A `[ZIGIX:PANIC:*]` line **always** fails the run.
- A `[ZIGIX:TEST:FAIL:*]` line **always** fails the run.
- Missing an expected marker fails the run.
- Timeout fails the run.
- The parser is `tools/qemu/smoke_test.py`. It is the single source of truth
  for "did the kernel pass."

## Layer 4 — Compatibility tests

- Compile tiny C programs against the libc shim / newlib / musl.
- Run statically-linked programs in QEMU.
- Later: BusyBox / Toybox applets.
- Later: GNU tools subsets.

The compatibility status table lives in `docs/posix-compat.md`.

## Layer 5 — Build-loop measurements

See `docs/benchmark-methodology.md`. Tracks clean and incremental kernel build
time and total `qemu-smoke` time, optionally compared against upstream Zig
when both are available.

## Reproducibility

Tests must:

- record the active compiler identity in their log;
- be runnable from a clean checkout with one documented command;
- not depend on machine-specific absolute paths committed to the repo.
