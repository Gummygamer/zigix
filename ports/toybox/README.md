# Toybox port

The first third-party userspace target is Toybox `echo`, pinned by `REVISION`
and configured by `miniconfig`. Upstream is ISC licensed; keep its `LICENSE`
with any redistributed source or binary.

The initial freestanding probe was run with the Bun-Zig C driver. It first
failed at missing `regex.h`, which established that Zigix needs a real newlib
headers/archive build instead of more standalone Zig hook probes. The pinned
newlib build now supplies that header. The next Toybox-specific portability
gap is Linux's nonstandard `byteswap.h`; carry the eventual Zigix adaptation
as a small reviewed patch in this directory rather than adding Linux headers
to newlib.

Do not emit `[ZIGIX:TEST:PASS:toybox]` until the upstream applet itself boots
in QEMU and its output is checked.
