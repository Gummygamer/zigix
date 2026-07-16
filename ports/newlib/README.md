# newlib bootstrap port

Zigix builds newlib from the exact commit in `REVISION`. Upstream source is
not vendored; clone it from `https://sourceware.org/git/newlib-cygwin.git` and
pass that checkout to:

```sh
set -a; . .env; set +a
tools/ports/build-newlib.sh /path/to/newlib-cygwin
```

The build disables newlib's supplied syscall implementations so Zigix can
provide its own hooks. Bun Zig 0.15.2 does not currently predefine the GCC
compatibility macros `__SCHAR_WIDTH__` and `__LONG_LONG_WIDTH__`; the build
driver supplies their x86_64 values explicitly. Removing those flags requires
a clean build and a successful archive test.

The generated sysroot is deliberately ignored. It contains newlib headers,
including `regex.h`, and `libc.a`; later port steps link it with Zigix startup
and syscall objects.
