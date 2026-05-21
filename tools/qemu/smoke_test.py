#!/usr/bin/env python3
"""Parse a Zigix QEMU serial log and decide pass/fail.

Single source of truth for "did the kernel pass." Designed to run in CI and
locally with no third-party dependencies.

Pass rules:
  * No `[ZIGIX:PANIC:...]` markers.
  * No `[ZIGIX:TEST:FAIL:...]` markers.
  * Every `--expect` marker appears in the log.

Fail rules (any one trips it):
  * A panic marker.
  * A test-fail marker.
  * A missing expected marker.
  * The log file does not exist or is empty.

Examples:
  smoke_test.py zig-out/serial.log --phase phase1
  smoke_test.py zig-out/serial.log --expect '[ZIGIX:BOOT:OK]'
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

PANIC_RE = re.compile(r"\[ZIGIX:PANIC:([^\]]*)\]")
TEST_FAIL_RE = re.compile(r"\[ZIGIX:TEST:FAIL:([^:]+):([^\]]*)\]")
TEST_PASS_RE = re.compile(r"\[ZIGIX:TEST:PASS:([^\]]+)\]")
TOOLCHAIN_RE = re.compile(r"\[ZIGIX:TOOLCHAIN:([^\]]+)\]")

PHASES: dict[str, list[str]] = {
    "phase0": [],  # no kernel; the harness itself decides
    "phase1": ["[ZIGIX:BOOT:START]", "[ZIGIX:BOOT:OK]"],
    "phase2": [
        "[ZIGIX:BOOT:START]",
        "[ZIGIX:BOOT:OK]",
        "[ZIGIX:TEST:PASS:kernel_smoke]",
    ],
    "phase3": ["[ZIGIX:BOOT:OK]", "[ZIGIX:MM:OK]"],
    "phase4": ["[ZIGIX:BOOT:OK]", "[ZIGIX:TEST:PASS:exception_caught]"],
    "phase5": ["[ZIGIX:BOOT:OK]", "[ZIGIX:VFS:OK]"],
    "phase6": ["[ZIGIX:BOOT:OK]", "[ZIGIX:SYSCALL:OK]"],
    "phase7": ["[ZIGIX:BOOT:OK]", "[ZIGIX:ELF:OK]"],
    "phase8": ["[ZIGIX:BOOT:OK]", "[ZIGIX:INIT:START]", "[ZIGIX:INIT:OK]"],
    "phase9": [
        "[ZIGIX:BOOT:OK]",
        "[ZIGIX:TEST:PASS:syscall_fd_table]",
        "[ZIGIX:TEST:PASS:syscall_pipe]",
    ],
    "phase10": [
        "[ZIGIX:BOOT:OK]",
        "[ZIGIX:TEST:PASS:syscall_pipe_blocking]",
        "[ZIGIX:TEST:PASS:process_lifecycle]",
        "[ZIGIX:TEST:PASS:process_wait_nohang]",
        "[ZIGIX:TEST:PASS:process_wait_blocking]",
        "[ZIGIX:TEST:PASS:process_address_space]",
        "[ZIGIX:TEST:PASS:process_page_tables]",
        "[ZIGIX:TEST:PASS:process_scheduler_groundwork]",
        "[ZIGIX:TEST:PASS:process_run_queue]",
        "[ZIGIX:TEST:PASS:process_fd_tables]",
        "[ZIGIX:TEST:PASS:process_spawn_resume]",
        "[ZIGIX:TEST:PASS:spawn_child_image]",
        "[ZIGIX:TEST:PASS:posix_spawn_handoff]",
        "[ZIGIX:TEST:PASS:execve_load]",
        "[ZIGIX:TEST:PASS:execve_argv_stack]",
        "[ZIGIX:INIT:START]",
        "[ZIGIX:INIT:OK]",
    ],
    "phase11": [
        "[ZIGIX:BOOT:OK]",
        "[ZIGIX:TEST:PASS:tinysh_smoke]",
        "[ZIGIX:INIT:START]",
        "[ZIGIX:INIT:OK]",
    ],
    "phase12": [
        "[ZIGIX:BOOT:OK]",
        "[ZIGIX:TEST:PASS:syscall_stdin_console]",
        "[ZIGIX:TEST:PASS:tinysh_interactive]",
        "[ZIGIX:INIT:START]",
        "[ZIGIX:INIT:OK]",
    ],
    "phase13": [
        "[ZIGIX:BOOT:OK]",
        "[ZIGIX:TEST:PASS:tinysh_smoke]",
        "[ZIGIX:TEST:PASS:libc_shim_newlib]",
        "[ZIGIX:INIT:START]",
        "[ZIGIX:INIT:OK]",
    ],
    "phase14": [
        "[ZIGIX:BOOT:OK]",
        "[ZIGIX:TEST:PASS:syscall_dup2]",
        "[ZIGIX:TEST:PASS:syscall_chdir]",
        "[ZIGIX:TEST:PASS:syscall_getpid]",
        "[ZIGIX:TEST:PASS:syscall_getdents64]",
        "[ZIGIX:TEST:PASS:syscall_writable_memfs]",
        "[ZIGIX:TEST:PASS:tinysh_smoke]",
        "[ZIGIX:TEST:PASS:tinysh_redirection]",
        "[ZIGIX:TEST:PASS:cat]",
        "[ZIGIX:TEST:PASS:libc_shim_newlib]",
        "[ZIGIX:INIT:START]",
        "[ZIGIX:INIT:OK]",
    ],
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("log", help="path to QEMU serial log")
    ap.add_argument(
        "--phase",
        default=None,
        help=f"named expectation set; one of {sorted(PHASES)}",
    )
    ap.add_argument(
        "--expect",
        action="append",
        default=[],
        help="literal marker that must appear; may be passed multiple times",
    )
    args = ap.parse_args()

    log_path = Path(args.log)
    if not log_path.exists():
        print(f"FAIL: log file does not exist: {log_path}", file=sys.stderr)
        return 2
    text = log_path.read_text(errors="replace")
    if not text.strip():
        print(f"FAIL: log file is empty: {log_path}", file=sys.stderr)
        return 2

    expected: list[str] = list(args.expect)
    if args.phase:
        if args.phase not in PHASES:
            print(
                f"FAIL: unknown --phase {args.phase!r}; known: {sorted(PHASES)}",
                file=sys.stderr,
            )
            return 2
        expected.extend(PHASES[args.phase])

    # Always surface toolchain identity for reproducibility.
    for m in TOOLCHAIN_RE.findall(text):
        print(f"toolchain: {m}", file=sys.stderr)

    # Hard fails.
    panic_match = PANIC_RE.search(text)
    if panic_match:
        print(f"FAIL: kernel panic: {panic_match.group(1)}", file=sys.stderr)
        return 2

    fail_match = TEST_FAIL_RE.search(text)
    if fail_match:
        print(
            f"FAIL: kernel test failed: {fail_match.group(1)}: {fail_match.group(2)}",
            file=sys.stderr,
        )
        return 2

    # Missing expected markers.
    missing = [marker for marker in expected if marker not in text]
    if missing:
        for marker in missing:
            print(f"FAIL: missing expected marker: {marker}", file=sys.stderr)
        return 1

    passes = TEST_PASS_RE.findall(text)
    for name in passes:
        print(f"pass: {name}", file=sys.stderr)

    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
