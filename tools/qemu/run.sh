#!/usr/bin/env bash
# QEMU runner for Zigix.
#
# Phase 0: there is no kernel yet, so this script exits with a clear marker
# rather than silently doing nothing.
#
# Phase 1+: boots the kernel headlessly, captures the serial port to a file,
# and lets tools/qemu/smoke_test.py decide pass/fail.

set -euo pipefail

KERNEL="${1:-zig-out/bin/zigix-kernel}"
INITRD="${2:-}"
SERIAL_INPUT="${3:-${ZIGIX_SERIAL_INPUT:-}}"
LOG="${4:-${ZIGIX_SERIAL_LOG:-zig-out/serial.log}}"
TIMEOUT_SEC="${ZIGIX_QEMU_TIMEOUT:-30}"
SERIAL_INPUT_DELAY_SEC="${ZIGIX_SERIAL_INPUT_DELAY:-0.2}"

mkdir -p "$(dirname "$LOG")"

if [[ ! -f "$KERNEL" ]]; then
  printf '[zigix-qemu] kernel not built yet: %s\n' "$KERNEL" >&2
  printf '[ZIGIX:TEST:FAIL:qemu_smoke:kernel_not_built]\n' | tee "$LOG" >&2
  exit 3
fi

if [[ -n "$INITRD" && ! -f "$INITRD" ]]; then
  printf '[zigix-qemu] initramfs not built yet: %s\n' "$INITRD" >&2
  printf '[ZIGIX:TEST:FAIL:qemu_smoke:initramfs_not_built]\n' | tee "$LOG" >&2
  exit 5
fi

if [[ -n "$SERIAL_INPUT" && ! -f "$SERIAL_INPUT" ]]; then
  printf '[zigix-qemu] serial input file not found: %s\n' "$SERIAL_INPUT" >&2
  printf '[ZIGIX:TEST:FAIL:qemu_smoke:serial_input_not_found]\n' | tee "$LOG" >&2
  exit 6
fi

if ! command -v qemu-system-x86_64 >/dev/null; then
  printf '[zigix-qemu] qemu-system-x86_64 not installed\n' >&2
  printf '[ZIGIX:TEST:FAIL:qemu_smoke:qemu_missing]\n' | tee "$LOG" >&2
  exit 4
fi

# Headless run with serial captured to file. `-no-reboot` so a triple
# fault exits instead of looping. When a serial input script is provided,
# COM1 is attached to stdio and stdout is redirected to the serial log;
# otherwise QEMU writes COM1 directly to the log file.
#
# `isa-debug-exit` lets the kernel
# terminate QEMU cleanly: writing N to port 0xF4 makes QEMU exit with
# status `(N << 1) | 1`. We rely on the smoke parser, not the exit code,
# to decide pass/fail — but a clean exit lets CI finish in milliseconds
# instead of waiting for the timeout.
QEMU_ARGS=(
  -no-reboot
  -m 128M
  -display none
  -device isa-debug-exit,iobase=0xf4,iosize=0x04
  -kernel "$KERNEL"
)

if [[ -n "$SERIAL_INPUT" ]]; then
  QEMU_ARGS+=(-monitor none -serial stdio)
else
  QEMU_ARGS+=(-nographic -serial "file:$LOG")
fi

if [[ -n "$INITRD" ]]; then
  QEMU_ARGS+=(-initrd "$INITRD")
fi

printf '[zigix-qemu] running: qemu-system-x86_64 %s\n' "${QEMU_ARGS[*]}" >&2
if [[ -n "$SERIAL_INPUT" ]]; then
  printf '[zigix-qemu] serial input: %s\n' "$SERIAL_INPUT" >&2
fi

set +e
if [[ -n "$SERIAL_INPUT" ]]; then
  { sleep "${SERIAL_INPUT_DELAY_SEC}"; cat "$SERIAL_INPUT"; } | timeout --foreground "${TIMEOUT_SEC}" qemu-system-x86_64 "${QEMU_ARGS[@]}" >"$LOG"
  rc=${PIPESTATUS[1]}
else
  timeout --foreground "${TIMEOUT_SEC}" qemu-system-x86_64 "${QEMU_ARGS[@]}"
  rc=$?
fi
set -e

# Exit codes we consider "the run finished, defer to the parser":
#   0   — QEMU exited cleanly (e.g. host quit signal).
#   33  — kernel wrote 0x10 to isa-debug-exit (Phase 1 happy path).
#   124 — host-side timeout (kernel got stuck before clean exit).
# Anything else is QEMU itself failing (kernel didn't load, etc.) and we
# surface it so CI fails loudly.
case "$rc" in
  0|33|124)
    printf '[zigix-qemu] qemu exit=%d (deferring to serial-marker parser)\n' "$rc" >&2
    exit 0
    ;;
  *)
    printf '[zigix-qemu] qemu exited with unexpected code %d\n' "$rc" >&2
    exit "$rc"
    ;;
esac
