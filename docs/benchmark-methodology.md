# Benchmark methodology

The point of measuring is to test the project's hypothesis about Bun Zig:
**does it improve the OS development loop?** It is not to make Zigix faster
at runtime.

## What we measure

| Metric                                           | Why                                       |
| ------------------------------------------------ | ----------------------------------------- |
| Bun Zig clean kernel build time                  | First-touch developer feedback            |
| Bun Zig incremental kernel build time            | Steady-state developer feedback           |
| Bun Zig `qemu-smoke` total wall time             | End-to-end iteration cost                 |
| Upstream Zig clean kernel build time (if avail)  | Baseline for the comparison               |
| Upstream Zig incremental build time (if avail)   | Baseline for the comparison               |
| Upstream Zig `qemu-smoke` total wall time        | Baseline for the comparison               |

If upstream Zig is not configured, write **"not measured"** instead of
guessing. Do not fabricate baselines.

## How we measure

A future `tools/toolchain/measure-compile.sh` will:

1. Record host info: `uname -a`, CPU model, memory, filesystem, whether the
   build directory is on a hot cache.
2. Record compiler identity: path + `zig version` output.
3. Run a defined sequence: clean build, incremental no-op, incremental
   trivial-edit, full `qemu-smoke`.
4. Repeat each measurement N times (N >= 3) and report median + spread.
5. Write the results into `docs/benchmark-results/<date>-<host>-<compiler>.md`.

## What we do **not** do

- Do not optimize the kernel for benchmark numbers.
- Do not claim a speedup without recorded measurements.
- Do not suppress noisy results — document them.
- Do not switch toolchains for "vibes." Switch for measured wins.

## Status

No measurements yet. Phase 1 is the earliest meaningful target.
