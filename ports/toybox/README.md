# Toybox port

The first third-party userspace target is Toybox `echo`, pinned by `REVISION`
and configured by `miniconfig`. Upstream is ISC licensed; keep its `LICENSE`
with any redistributed source or binary.

The initial freestanding probe first failed at missing `regex.h`, which
established that Zigix needs a real newlib headers/archive build. The pinned
newlib build supplies it. The broader Toybox headers then exposed Linux's
nonstandard `byteswap.h`; `patches/` carries the builtins-based Zigix
adaptation rather than adding Linux headers to newlib.

The first bootable slice compiles upstream `toys/posix/echo.c` unchanged. The
local `toys.h` overlay and `runtime.c` provide only the small Toybox context,
option bits, formatting wrapper, and escape parser that this one applet uses.
Build and boot it with:

```sh
tools/ports/run-toybox-echo.sh \
  /path/to/toybox \
  zig-out/ports/newlib/sysroot/x86_64-elf
```

The guest init passes the success marker as an argv element, so the marker is
printed by upstream `echo_main`; the harness does not print it on the applet's
behalf. This overlay is a bootstrap boundary, not a claim that the complete
Toybox support library is ported. Newlib directory streams are the next
concrete blocker for broadening the applet set.

`[ZIGIX:TEST:PASS:toybox]` now proves the first upstream applet boots in QEMU.
