#!/usr/bin/env bash
# Compile upstream Toybox echo.c, cat.c, nproc, id, and pwd with the bootstrap.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'usage: %s TOYBOX_SOURCE NEWLIB_SYSROOT\n' "$0" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
toybox_source="$(cd "$1" && pwd)"
sysroot="$(cd "$2" && pwd)"
include_dir="$sysroot/include"
libc="$sysroot/lib/libc.a"

expected_revision="$(tr -d '[:space:]' < "$repo_root/ports/toybox/REVISION")"
actual_revision="$(git -C "$toybox_source" rev-parse HEAD)"
if [[ "$actual_revision" != "$expected_revision" ]]; then
  printf '[toybox] expected revision %s, got %s\n' \
    "$expected_revision" "$actual_revision" >&2
  exit 3
fi

test -f "$toybox_source/toys/posix/echo.c"
test -f "$include_dir/stdio.h"
test -f "$libc"

cd "$repo_root"
tools/toolchain/check-bun-zig.sh
tools/toolchain/zig-bun build kernel

out=zig-out/ports/toybox-echo
mkdir -p "$out"
common=(
  -nostdlib
  -ffunction-sections
  -fdata-sections
  -Wl,-T,userspace/init/linker.ld
  -Wl,--gc-sections
)

tools/toolchain/zigix-cc "${common[@]}" \
  -D__ZIGIX__ \
  -I ports/toybox \
  -isystem "$include_dir" \
  ports/toybox/start.S \
  ports/toybox/runtime.c \
  "$toybox_source/toys/posix/echo.c" \
  userspace/newlib-smoke/syscalls.c \
  "$libc" \
  -o "$out/toybox-echo"

tools/toolchain/zigix-cc "${common[@]}" \
  -D__ZIGIX__ \
  -I ports/toybox \
  -isystem "$include_dir" \
  ports/toybox/start.S \
  ports/toybox/runtime-cat.c \
  "$toybox_source/toys/posix/cat.c" \
  userspace/newlib-smoke/syscalls.c \
  "$libc" \
  -o "$out/toybox-cat"

tools/toolchain/zigix-cc "${common[@]}" \
  -D__ZIGIX__ \
  -I ports/toybox \
  -isystem "$include_dir" \
  ports/toybox/start.S \
  ports/toybox/runtime-nproc.c \
  "$toybox_source/toys/other/taskset.c" \
  ports/newlib/dirent.c \
  userspace/newlib-smoke/syscalls.c \
  "$libc" \
  -o "$out/toybox-nproc"

tools/toolchain/zigix-cc "${common[@]}" \
  -D__ZIGIX__ \
  -I ports/toybox \
  -isystem "$include_dir" \
  ports/toybox/start.S \
  ports/toybox/runtime-id.c \
  "$toybox_source/toys/posix/id.c" \
  userspace/newlib-smoke/syscalls.c \
  "$libc" \
  -o "$out/toybox-id"

tools/toolchain/zigix-cc "${common[@]}" \
  -D__ZIGIX__ \
  -I ports/toybox \
  -isystem "$include_dir" \
  ports/toybox/start.S \
  ports/toybox/runtime-pwd.c \
  "$toybox_source/toys/posix/pwd.c" \
  userspace/newlib-smoke/syscalls.c \
  "$libc" \
  -o "$out/toybox-pwd"

tools/toolchain/zigix-cc "${common[@]}" \
  ports/toybox/init.c \
  -o "$out/init"

python3 tools/mkinitramfs/pack.py "$out/initramfs.zixr" \
  --entry init "$out/init" \
  --entry libc-compat zig-out/bin/libc-compat \
  --entry exec-ok zig-out/bin/exec-ok \
  --entry cat zig-out/bin/cat \
  --entry tinysh zig-out/bin/tinysh \
  --entry ls zig-out/bin/ls \
  --entry toybox-echo "$out/toybox-echo" \
  --entry toybox-cat "$out/toybox-cat" \
  --entry toybox-nproc "$out/toybox-nproc" \
  --entry toybox-id "$out/toybox-id" \
  --entry toybox-pwd "$out/toybox-pwd" \
  --entry toybox-cat-input ports/toybox/cat-marker.txt \
  --entry sys/devices/system/cpu/cpu0 ports/toybox/cat-marker.txt \
  --entry sys/devices/system/cpu/cpu1 ports/toybox/cat-marker.txt

tools/qemu/run.sh \
  zig-out/bin/zigix-kernel.mb \
  "$out/initramfs.zixr" \
  "" \
  "$out/serial.log"
tools/qemu/smoke_test.py "$out/serial.log" --phase phase16-toybox
