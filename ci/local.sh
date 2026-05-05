#!/usr/bin/env bash
# Local CI: run every check that does not require Bun Zig to be installed,
# plus the toolchain check itself when ZIGIX_BUN_ZIG is set.
#
# Exit code 0: every check that ran passed.
# Exit code 1: at least one check failed.

set -uo pipefail

cd "$(dirname "$0")/.."

ok=0
fail=0
skip=0

run() {
  local name="$1"; shift
  printf '\n--- %s ---\n' "$name"
  if "$@"; then
    printf 'PASS: %s\n' "$name"
    ok=$((ok+1))
  else
    printf 'FAIL: %s\n' "$name"
    fail=$((fail+1))
  fi
}

skip() {
  local name="$1"; shift
  printf '\n--- %s ---\n' "$name"
  printf 'SKIP: %s (%s)\n' "$name" "$*"
  skip=$((skip+1))
}

# 1. Wrapper and check scripts must be executable.
run "wrapper-exists" test -x tools/toolchain/zig-bun
run "check-script-exists" test -x tools/toolchain/check-bun-zig.sh
run "qemu-runner-exists" test -x tools/qemu/run.sh
run "smoke-parser-exists" test -x tools/qemu/smoke_test.py

# 2. The check script must FAIL when ZIGIX_BUN_ZIG is unset. This is a
#    negative test that proves the project does not silently fall back to
#    system Zig.
run "check-fails-without-env" bash -c '
  unset ZIGIX_BUN_ZIG
  if tools/toolchain/check-bun-zig.sh >/dev/null 2>&1; then
    echo "check-bun-zig.sh passed without ZIGIX_BUN_ZIG; expected failure" >&2
    exit 1
  fi
  exit 0
'

# 3. The smoke parser must reject an obviously-failing log.
run "smoke-parser-rejects-panic" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:PANIC:test_only]\n" > "$tmp"
  if tools/qemu/smoke_test.py "$tmp" --phase phase1 >/dev/null 2>&1; then
    echo "smoke parser missed a panic line" >&2
    exit 1
  fi
  exit 0
'

# 4. The smoke parser must reject a log missing required markers.
run "smoke-parser-rejects-missing" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "nothing useful here\n" > "$tmp"
  if tools/qemu/smoke_test.py "$tmp" --phase phase1 >/dev/null 2>&1; then
    echo "smoke parser passed an empty-of-markers log" >&2
    exit 1
  fi
  exit 0
'

# 5. The smoke parser must accept a log that contains every Phase-1 marker.
run "smoke-parser-accepts-phase1" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\nhello\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase1
'

run "smoke-parser-accepts-phase2" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:TEST:PASS:kernel_smoke]\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase2
'

run "smoke-parser-accepts-phase3" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:TEST:PASS:kernel_smoke]\n[ZIGIX:MM:OK]\n[ZIGIX:TEST:PASS:memory_smoke]\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase3
'

run "smoke-parser-accepts-phase4" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:TEST:PASS:exception_caught]\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase4
'

run "smoke-parser-accepts-phase5" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:VFS:OK]\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase5
'

# 6. The validate-elf script must reject a non-ELF file (negative test).
run "validate-elf-rejects-non-elf" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "not an elf file at all\n" > "$tmp"
  if tools/kernel/validate-elf.sh "$tmp" >/dev/null 2>&1; then
    echo "validate-elf accepted non-ELF input" >&2
    exit 1
  fi
  exit 0
'

# 7. The QEMU runner must fail clearly when handed a missing kernel path.
run "qemu-runner-fails-on-missing-kernel" bash -c '
  out=$(tools/qemu/run.sh /nonexistent/zigix-kernel 2>&1) && {
    echo "qemu runner accepted a missing kernel: $out" >&2
    exit 1
  }
  rc=$?
  case "$rc" in 3|4) ;;  # 3 = kernel not built, 4 = qemu missing
    *) echo "unexpected exit code $rc; output: $out" >&2; exit 1 ;;
  esac
  exit 0
'

# 8. If ZIGIX_BUN_ZIG is set, run toolchain check + host tests + the full
#    kernel build + qemu smoke. This is the real Phase 5 acceptance gate.
if [[ -n "${ZIGIX_BUN_ZIG:-}" ]]; then
  run "check-toolchain" tools/toolchain/check-bun-zig.sh
  run "host-test" tools/toolchain/zig-bun build host-test
  run "build-kernel" tools/toolchain/zig-bun build kernel
  run "validate-kernel-elf" tools/toolchain/zig-bun build validate-kernel-elf
  if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    run "qemu-smoke-phase5" tools/toolchain/zig-bun build qemu-smoke
  else
    skip "qemu-smoke-phase5" "qemu-system-x86_64 not installed"
  fi
else
  skip "check-toolchain" "ZIGIX_BUN_ZIG is not set"
  skip "host-test" "ZIGIX_BUN_ZIG is not set"
  skip "build-kernel" "ZIGIX_BUN_ZIG is not set"
  skip "validate-kernel-elf" "ZIGIX_BUN_ZIG is not set"
  skip "qemu-smoke-phase5" "ZIGIX_BUN_ZIG is not set"
fi

printf '\n=== summary ===\n'
printf 'pass: %d  fail: %d  skip: %d\n' "$ok" "$fail" "$skip"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
