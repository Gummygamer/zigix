#!/usr/bin/env bash
# Build the pinned newlib archive and headers with Bun Zig.

set -euo pipefail

usage() {
  printf 'usage: %s NEWLIB_SOURCE [OUTPUT_ROOT]\n' "$0" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
source_root="$(cd "$1" && pwd)"
output_root="${2:-$repo_root/zig-out/ports/newlib}"
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd)"

expected_revision="$(tr -d '[:space:]' < "$repo_root/ports/newlib/REVISION")"
actual_revision="$(git -C "$source_root" rev-parse HEAD)"
if [[ "$actual_revision" != "$expected_revision" ]]; then
  printf '[newlib] expected revision %s, got %s\n' \
    "$expected_revision" "$actual_revision" >&2
  exit 3
fi

"$repo_root/tools/toolchain/check-bun-zig.sh"

build_root="$output_root/build"
sysroot="$output_root/sysroot"
mkdir -p "$build_root" "$sysroot"

cc="$repo_root/tools/toolchain/zigix-cc"
ar="$repo_root/tools/toolchain/zigix-ar"
ranlib="$repo_root/tools/toolchain/zigix-ranlib"
target_cflags='-g -O2 -D__SCHAR_WIDTH__=8 -D__LONG_LONG_WIDTH__=64'

if [[ ! -f "$build_root/Makefile" ]]; then
  (
    cd "$build_root"
    "$source_root/configure" \
      --target=x86_64-elf \
      --prefix="$sysroot" \
      --disable-multilib \
      --disable-nls \
      --disable-newlib-supplied-syscalls \
      --disable-newlib-io-float \
      CC_FOR_TARGET="$cc" \
      AR_FOR_TARGET="$ar" \
      RANLIB_FOR_TARGET="$ranlib" \
      AS_FOR_TARGET=as \
      LD_FOR_TARGET=ld \
      NM_FOR_TARGET=nm \
      OBJCOPY_FOR_TARGET=objcopy \
      OBJDUMP_FOR_TARGET=objdump \
      READELF_FOR_TARGET=readelf \
      STRIP_FOR_TARGET=strip \
      CFLAGS_FOR_TARGET="$target_cflags"
  )
fi

jobs="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')}"
make -C "$build_root" -j"$jobs" \
  CFLAGS_FOR_TARGET="$target_cflags" all-target-newlib
make -C "$build_root" \
  CFLAGS_FOR_TARGET="$target_cflags" install-target-newlib

test -f "$sysroot/x86_64-elf/include/regex.h"
test -f "$sysroot/x86_64-elf/lib/libc.a"
printf '[ZIGIX:TEST:PASS:newlib_archive]\n'
printf '[newlib] sysroot: %s/x86_64-elf\n' "$sysroot"
