#!/usr/bin/env bash
# Link a C program with the generated newlib archive and boot it in QEMU.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s NEWLIB_SYSROOT\n' "$0" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
sysroot="$(cd "$1" && pwd)"
include_dir="$sysroot/include"
libc="$sysroot/lib/libc.a"

test -f "$include_dir/stdio.h"
test -f "$libc"

cd "$repo_root"
tools/toolchain/check-bun-zig.sh
tools/toolchain/zig-bun build kernel

out=zig-out/ports/newlib-smoke
mkdir -p "$out"
common=(
  -nostdlib
  -ffunction-sections
  -fdata-sections
  -Wl,-T,userspace/init/linker.ld
  -Wl,--gc-sections
)

tools/toolchain/zigix-cc "${common[@]}" \
  -isystem "$include_dir" \
  userspace/newlib-smoke/main.c \
  userspace/newlib-smoke/syscalls.c \
  "$libc" \
  -o "$out/newlib-smoke"

tools/toolchain/zigix-cc "${common[@]}" \
  -isystem "$include_dir" \
  ports/toybox/start.S \
  userspace/newlib-dirent/main.c \
  ports/newlib/dirent.c \
  userspace/newlib-smoke/syscalls.c \
  "$libc" \
  -o "$out/newlib-dirent"

tools/toolchain/zigix-cc "${common[@]}" \
  userspace/newlib-smoke/init.c \
  -o "$out/init"

python3 tools/mkinitramfs/pack.py "$out/initramfs.zixr" \
  --entry init "$out/init" \
  --entry newlib-smoke "$out/newlib-smoke" \
  --entry newlib-dirent "$out/newlib-dirent" \
  --entry libc-compat zig-out/bin/libc-compat \
  --entry exec-ok zig-out/bin/exec-ok \
  --entry cat zig-out/bin/cat \
  --entry tinysh zig-out/bin/tinysh \
  --entry ls zig-out/bin/ls

tools/qemu/run.sh \
  zig-out/bin/zigix-kernel.mb \
  "$out/initramfs.zixr" \
  "" \
  "$out/serial.log"
tools/qemu/smoke_test.py "$out/serial.log" --phase phase16-newlib-dirent
