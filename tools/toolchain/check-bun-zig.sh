#!/usr/bin/env bash
# Verify the Bun Zig toolchain is configured and report its identity.
#
# Exits 0 on success, non-zero with a clear message on failure.
# Designed to work even when no Zig is installed on the host (it only requires
# that ZIGIX_BUN_ZIG point at the binary, then runs `--version` on it).
#
# See docs/bun-zig-toolchain.md.

set -euo pipefail

fail() { printf '[check-bun-zig] FAIL: %s\n' "$*" >&2; exit 1; }
note() { printf '[check-bun-zig] %s\n' "$*"; }

if [[ -z "${ZIGIX_BUN_ZIG:-}" ]]; then
  fail "ZIGIX_BUN_ZIG is not set. See docs/bun-zig-toolchain.md."
fi

if [[ ! -e "$ZIGIX_BUN_ZIG" ]]; then
  fail "ZIGIX_BUN_ZIG=$ZIGIX_BUN_ZIG does not exist."
fi

if [[ ! -x "$ZIGIX_BUN_ZIG" ]]; then
  fail "ZIGIX_BUN_ZIG=$ZIGIX_BUN_ZIG is not executable."
fi

# Refuse to silently approve a system-Zig path.
case "$ZIGIX_BUN_ZIG" in
  /usr/bin/zig|/usr/local/bin/zig|"$HOME"/.local/bin/zig)
    if [[ "${ZIGIX_ALLOW_SYSTEM_ZIG:-0}" != "1" ]]; then
      fail "ZIGIX_BUN_ZIG points to a system-zig path: $ZIGIX_BUN_ZIG (set ZIGIX_ALLOW_SYSTEM_ZIG=1 to override)"
    fi
    note "system-looking path acknowledged via ZIGIX_ALLOW_SYSTEM_ZIG=1"
    ;;
esac

if ! ver="$("$ZIGIX_BUN_ZIG" version 2>&1)"; then
  fail "could not run '$ZIGIX_BUN_ZIG version': $ver"
fi

note "compiler: $ZIGIX_BUN_ZIG"
note "version : $ver"
note "[ZIGIX:TOOLCHAIN:zig-bun=$ZIGIX_BUN_ZIG version=$ver]"

# Optional pin: the user supplies a substring that must appear in the version
# string. This is the only fork-identity check we can do without external
# attestations; it is opt-in by design (see docs/bun-zig-toolchain.md).
if [[ -n "${ZIGIX_BUN_ZIG_PINNED_VERSION:-}" ]]; then
  if [[ "$ver" != *"${ZIGIX_BUN_ZIG_PINNED_VERSION}"* ]]; then
    fail "version '$ver' does not contain pinned token '${ZIGIX_BUN_ZIG_PINNED_VERSION}'"
  fi
  note "matches pinned version token: ${ZIGIX_BUN_ZIG_PINNED_VERSION}"
fi
