#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

for lock in ports/newlib/REVISION ports/toybox/REVISION; do
  revision="$(tr -d '[:space:]' < "$lock")"
  if [[ ! "$revision" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s must contain one full lowercase Git revision\n' "$lock" >&2
    exit 1
  fi
done

grep -qx 'CONFIG_ECHO=y' ports/toybox/miniconfig
printf '[ZIGIX:TEST:PASS:port_source_locks]\n'
