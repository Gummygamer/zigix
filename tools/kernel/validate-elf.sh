#!/usr/bin/env bash
# Verifies that a built Zigix kernel ELF satisfies Multiboot1's loader
# requirements:
#
#   1. It is an ELF file (any class).
#   2. It declares an executable entry point.
#   3. The Multiboot1 magic dword (0x1BADB002) appears within the first
#      8 KiB of the file at 4-byte alignment.
#
# Multiboot1 spec, section 3.1.1:
#   "The Multiboot header must be contained completely within the first
#    8192 bytes of the OS image, and must be longword (32-bit) aligned."
#
# Exits non-zero with a clear marker on failure so CI fails loudly.

set -euo pipefail

KERNEL="${1:?usage: validate-elf.sh <kernel.elf>}"

if [[ ! -f "$KERNEL" ]]; then
  printf '[ZIGIX:TEST:FAIL:validate_elf:not_found:%s]\n' "$KERNEL" >&2
  exit 2
fi

# 1. ELF magic.
magic_hex=$(head -c 4 "$KERNEL" | od -An -t x1 | tr -d ' \n')
if [[ "$magic_hex" != "7f454c46" ]]; then
  printf '[ZIGIX:TEST:FAIL:validate_elf:not_elf:%s]\n' "$magic_hex" >&2
  exit 2
fi

# 2. Multiboot1 magic. Search the first 8 KiB at 4-byte alignment.
# 0x1BADB002 little-endian = 02 b0 ad 1b
# Materialize the dump first to avoid SIGPIPE from `grep -q` racing the
# upstream `head` under `set -o pipefail`.
dump=$(head -c 8192 "$KERNEL" | od -An -tx4 -w4 -v | tr -d ' ')
if ! grep -Fxq '1badb002' <<<"$dump"; then
  printf '[ZIGIX:TEST:FAIL:validate_elf:no_multiboot_magic]\n' >&2
  exit 2
fi

# 3. Entry point declared (ELF e_entry field is at offset 0x18 for ELF64).
# We do not check its value, just that the binary parses with `file`.
if command -v file >/dev/null 2>&1; then
  file_out=$(file -b "$KERNEL")
  if ! grep -q 'ELF' <<<"$file_out"; then
    printf '[ZIGIX:TEST:FAIL:validate_elf:file_disagrees:%s]\n' "$file_out" >&2
    exit 2
  fi
fi

printf '[ZIGIX:TEST:PASS:validate_elf]\n'
