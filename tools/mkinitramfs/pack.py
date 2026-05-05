#!/usr/bin/env python3
"""Pack a tiny Zigix initramfs image.

Usage:
  pack.py OUT PATH=SOURCE [PATH=SOURCE ...]
  pack.py OUT --entry PATH SOURCE [--entry PATH SOURCE ...]
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

MAGIC = b"ZIXR"
VERSION = 1
KIND_FILE = 1


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    out = Path(sys.argv[1])
    entries: list[tuple[str, bytes]] = []

    args = sys.argv[2:]
    index = 0
    while index < len(args):
        if args[index] == "--entry":
            if index + 2 >= len(args):
                print("--entry requires PATH and SOURCE", file=sys.stderr)
                return 2
            image_path = args[index + 1]
            source = args[index + 2]
            index += 3
        else:
            spec = args[index]
            if "=" not in spec:
                print(f"entry must be PATH=SOURCE or --entry PATH SOURCE: {spec}", file=sys.stderr)
                return 2
            image_path, source = spec.split("=", 1)
            index += 1

        if not image_path.startswith("/"):
            image_path = "/" + image_path
        data = Path(source).read_bytes()
        entries.append((image_path, data))

    body = bytearray()
    for image_path, data in entries:
        encoded_path = image_path.encode("utf-8")
        if len(encoded_path) > 0xFFFF:
            print(f"path too long: {image_path}", file=sys.stderr)
            return 2
        if len(data) > 0xFFFFFFFF:
            print(f"file too large: {source}", file=sys.stderr)
            return 2
        body += struct.pack("<BBHI", KIND_FILE, 0, len(encoded_path), len(data))
        body += encoded_path
        body += data

    total_size = 16 + len(body)
    header = MAGIC + struct.pack("<HHII", VERSION, len(entries), total_size, 0)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(header + body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
