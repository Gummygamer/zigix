# Toybox port

The first third-party userspace target is a narrow Toybox `echo` and `cat`
slice, pinned by `REVISION` and configured by `miniconfig`. Upstream is ISC
licensed; keep its `LICENSE` with any redistributed source or binary.

The initial freestanding probe first failed at missing `regex.h`, which
established that Zigix needs a real newlib headers/archive build. The pinned
newlib build supplies it. The broader Toybox headers then exposed Linux's
nonstandard `byteswap.h`; `patches/` carries the builtins-based Zigix
adaptation rather than adding Linux headers to newlib.

The first bootable slices compile upstream `toys/posix/echo.c` and
`toys/posix/cat.c` unchanged. The local `toys.h` overlay plus the two bootstrap
runtime files provide only the small Toybox context, option bits, and helpers
these applets use. Build and boot them with:

```sh
tools/ports/run-toybox-echo.sh \
  /path/to/toybox \
  zig-out/ports/newlib/sysroot/x86_64-elf
```

The guest init passes the first success marker as an argv element, so upstream
`echo_main` prints it. It then runs upstream `cat_main` against an initramfs
file containing the second marker. The harness prints neither marker on an
applet's behalf. This overlay is a bootstrap boundary, not a claim that the
complete Toybox support library is ported. Zigix now supplies newlib directory
streams, so the next applet should expose the smallest concrete Toybox
support-library gap above that boundary.

`[ZIGIX:TEST:PASS:toybox]` and `[ZIGIX:TEST:PASS:toybox_cat]` prove both
upstream applets boot, receive argv, use newlib, and exit successfully in QEMU.
