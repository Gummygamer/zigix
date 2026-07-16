# Toybox port

The first third-party userspace target is a narrow Toybox `echo`, `cat`,
`nproc`, `id`, and `pwd` slice, pinned by `REVISION` and configured by `miniconfig`.
Upstream is ISC licensed; keep its `LICENSE` with redistributed source or
binary.

The initial freestanding probe first failed at missing `regex.h`, which
established that Zigix needs a real newlib headers/archive build. The pinned
newlib build supplies it. The broader Toybox headers then exposed Linux's
nonstandard `byteswap.h`; `patches/` carries the builtins-based Zigix
adaptation rather than adding Linux headers to newlib.

The first bootable slices compile upstream `toys/posix/echo.c`,
`toys/posix/cat.c`, `toys/other/taskset.c`, `toys/posix/id.c`, and
`toys/posix/pwd.c` unchanged.
The local `toys.h` overlay plus bootstrap runtime files provide only the small
Toybox context, option bits, and helpers these applets use. Build and boot them
with:

```sh
tools/ports/run-toybox-echo.sh \
  /path/to/toybox \
  zig-out/ports/newlib/sysroot/x86_64-elf
```

The guest init passes the first success marker as an argv element, so upstream
`echo_main` prints it. It then runs upstream `cat_main` against an initramfs
file containing the second marker. The harness prints neither marker on an
applet's behalf. This overlay is a bootstrap boundary, not a claim that the
complete Toybox support library is ported. For `nproc --all`, the runtime
deliberately skips the unsupported affinity syscall, and upstream code counts
the `cpu0` and `cpu1` entries in a deterministic initramfs sysfs fixture via
`opendir`/`readdir`. Init captures its stdout and accepts only `2\n` before
emitting `[ZIGIX:TEST:PASS:toybox_nproc]`.

The numeric `id -u` slice uses Zigix's explicit single-user-root UID/GID
syscalls. Init captures and validates `0\n` before emitting
`[ZIGIX:TEST:PASS:toybox_id]`; named-user databases and multi-user permissions
are intentionally not implied.

The `pwd -P` slice calls Zigix `getcwd` through newlib. Init accepts only the
root path output `/\n` before emitting `[ZIGIX:TEST:PASS:toybox_pwd]`.

The `toybox`, `toybox_cat`, `toybox_nproc`, `toybox_id`, and `toybox_pwd`
markers prove all five upstream implementations boot, use newlib, and exit
successfully in QEMU.
