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

run "smoke-parser-accepts-phase6" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:SYSCALL:OK]\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase6
'

run "smoke-parser-accepts-phase7" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:ELF:OK]\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase7
'

run "smoke-parser-accepts-phase8" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:BOOT:OK]\n[ZIGIX:INIT:START]\n[ZIGIX:INIT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase8
'

run "smoke-parser-accepts-phase9" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:TEST:PASS:syscall_fd_table]\n[ZIGIX:TEST:PASS:syscall_pipe]\n[ZIGIX:BOOT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase9
'

run "smoke-parser-accepts-phase10" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:TEST:PASS:syscall_pipe_blocking]\n[ZIGIX:TEST:PASS:process_lifecycle]\n[ZIGIX:TEST:PASS:process_wait_nohang]\n[ZIGIX:TEST:PASS:process_wait_blocking]\n[ZIGIX:TEST:PASS:process_address_space]\n[ZIGIX:TEST:PASS:process_page_tables]\n[ZIGIX:TEST:PASS:process_scheduler_groundwork]\n[ZIGIX:TEST:PASS:process_run_queue]\n[ZIGIX:TEST:PASS:process_fd_tables]\n[ZIGIX:TEST:PASS:process_spawn_resume]\n[ZIGIX:TEST:PASS:spawn_child_image]\n[ZIGIX:TEST:PASS:posix_spawn_handoff]\n[ZIGIX:TEST:PASS:execve_load]\n[ZIGIX:TEST:PASS:execve_argv_stack]\n[ZIGIX:BOOT:OK]\n[ZIGIX:INIT:START]\n[ZIGIX:INIT:OK]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase10
'

run "smoke-parser-accepts-phase11" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:BOOT:OK]\n[ZIGIX:INIT:START]\n[ZIGIX:INIT:OK]\n[ZIGIX:TEST:PASS:tinysh_smoke]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase11
'

run "smoke-parser-accepts-phase12" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:TEST:PASS:syscall_stdin_console]\n[ZIGIX:BOOT:OK]\n[ZIGIX:INIT:START]\n[ZIGIX:INIT:OK]\n[ZIGIX:TEST:PASS:tinysh_interactive]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase12
'

run "smoke-parser-accepts-phase13" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:BOOT:OK]\n[ZIGIX:INIT:START]\n[ZIGIX:INIT:OK]\n[ZIGIX:TEST:PASS:tinysh_smoke]\n[ZIGIX:TEST:PASS:libc_shim_newlib]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase13
'

run "smoke-parser-accepts-phase14" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "[ZIGIX:BOOT:START]\n[ZIGIX:TOOLCHAIN:bun-zig=0.15.2]\n[ZIGIX:BOOT:OK]\n[ZIGIX:TEST:PASS:syscall_dup2]\n[ZIGIX:TEST:PASS:syscall_chdir]\n[ZIGIX:TEST:PASS:syscall_getpid]\n[ZIGIX:TEST:PASS:syscall_getdents64]\n[ZIGIX:TEST:PASS:syscall_writable_memfs]\n[ZIGIX:INIT:START]\n[ZIGIX:INIT:OK]\n[ZIGIX:TEST:PASS:tinysh_smoke]\n[ZIGIX:TEST:PASS:libc_shim_newlib]\n" > "$tmp"
  tools/qemu/smoke_test.py "$tmp" --phase phase14
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

run "qemu-runner-fails-on-missing-serial-input" bash -c '
  tmp=$(mktemp)
  trap "rm -f $tmp" EXIT
  printf "kernel placeholder\n" > "$tmp"
  out=$(tools/qemu/run.sh "$tmp" "" /nonexistent/zigix-serial-input 2>&1) && {
    echo "qemu runner accepted a missing serial input file: $out" >&2
    exit 1
  }
  rc=$?
  case "$rc" in 6|4) ;;  # 6 = input missing, 4 = qemu missing before launch
    *) echo "unexpected exit code $rc; output: $out" >&2; exit 1 ;;
  esac
  exit 0
'

# 8. If ZIGIX_BUN_ZIG is set, run toolchain check + host tests + the full
#    kernel build + qemu smoke. This is the real Phase 14 acceptance gate.
if [[ -n "${ZIGIX_BUN_ZIG:-}" ]]; then
  run "check-toolchain" tools/toolchain/check-bun-zig.sh
  run "host-test" tools/toolchain/zig-bun build host-test
  run "build-kernel" tools/toolchain/zig-bun build kernel
  run "validate-kernel-elf" tools/toolchain/zig-bun build validate-kernel-elf
  if command -v qemu-system-x86_64 >/dev/null 2>&1; then
    run "qemu-smoke-phase14" tools/toolchain/zig-bun build qemu-smoke
    run "qemu-smoke-scripted-phase12-interactive" tools/toolchain/zig-bun build qemu-smoke-scripted
  else
    skip "qemu-smoke-phase14" "qemu-system-x86_64 not installed"
    skip "qemu-smoke-scripted-phase12-interactive" "qemu-system-x86_64 not installed"
  fi
else
  skip "check-toolchain" "ZIGIX_BUN_ZIG is not set"
  skip "host-test" "ZIGIX_BUN_ZIG is not set"
  skip "build-kernel" "ZIGIX_BUN_ZIG is not set"
  skip "validate-kernel-elf" "ZIGIX_BUN_ZIG is not set"
  skip "qemu-smoke-phase14" "ZIGIX_BUN_ZIG is not set"
  skip "qemu-smoke-scripted-phase12-interactive" "ZIGIX_BUN_ZIG is not set"
fi

printf '\n=== summary ===\n'
printf 'pass: %d  fail: %d  skip: %d\n' "$ok" "$fail" "$skip"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
exit 0
