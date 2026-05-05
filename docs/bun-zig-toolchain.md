# Bun Zig toolchain

Zigix uses the **Bun fork of the Zig compiler** as its primary toolchain. This
document is the contract for that decision and the place where measured
evidence is collected.

## Why the Bun fork

The expected benefits are **build-velocity / developer-loop benefits**, not
runtime-performance benefits. Specifically, we are investigating whether the
Bun fork helps with:

- faster compile/test cycles;
- faster QEMU smoke-test iteration;
- suitability for freestanding/kernel targets;
- compatibility with the normal Zig language features used in OS development;
- reproducibility when the compiler is pinned;
- friction (or lack of it) compared with upstream Zig.

We do **not** assume runtime speedups. If we find no measurable
developer-loop benefit, that is a result worth recording too.

## Pinning

The Bun Zig fork is pinned to the same commit Bun's own build uses, sourced
from [`oven-sh/bun:scripts/build/zig.ts`](https://github.com/oven-sh/bun/blob/main/scripts/build/zig.ts)
(`ZIG_COMMIT` constant).

| Field            | Value                                                         |
| ---------------- | ------------------------------------------------------------- |
| Repo             | https://github.com/oven-sh/zig                                |
| Commit           | `04e7f6ac1e009525bc00934f20199c68f04e0a24`                    |
| Release tag      | `autobuild-04e7f6ac1e009525bc00934f20199c68f04e0a24`          |
| Linux x86_64 asset | `bootstrap-x86_64-linux-musl-ReleaseSafe.zip`               |
| `zig version`    | `0.15.2` (the fork reports the upstream-compatible string)    |

The version string `0.15.2` is **not** sufficient to identify the fork —
upstream Zig 0.15.2 also exists. The real pin is the commit. The wrapper's
`ZIGIX_BUN_ZIG_PINNED_VERSION` env var is a *minimal* check, and the user is
expected to obtain the binary via the URL above (or by building the same
commit from source).

The pinning mechanism is **path + environment variable + optional version
token**:

| Variable                       | Purpose                                                       |
| ------------------------------ | ------------------------------------------------------------- |
| `ZIGIX_BUN_ZIG`                | **Required.** Absolute path to the Bun-fork Zig binary.       |
| `ZIGIX_BUN_ZIG_PINNED_VERSION` | Optional. Substring expected in `zig version` output.         |
| `ZIGIX_ALLOW_SYSTEM_ZIG`       | `1` to permit a system-looking path. Off by default.          |
| `ZIGIX_LOG_TOOLCHAIN`          | `0` silences the per-invocation identity log line.            |
| `ZIG_GLOBAL_CACHE_DIR`         | Optional. Zig global cache path. Defaults to `/tmp/zigix-zig-cache` through the wrapper. |

The repo never commits absolute paths or machine-specific values. Use
`.env.example` as a template.

## How to obtain the compiler

The Bun-fork Zig is published as a prebuilt binary on the
[`oven-sh/zig`](https://github.com/oven-sh/zig) releases page. Bun's own
build script (`scripts/build/zig.ts`) downloads the same artifact at runtime
and asserts a `<dest>/{zig, lib/}` layout — we mirror that exactly.

```sh
ZIG_COMMIT=04e7f6ac1e009525bc00934f20199c68f04e0a24
ZIG_DIR="$HOME/.local/share/bun-zig/$ZIG_COMMIT"
mkdir -p "$(dirname "$ZIG_DIR")"

curl -fL --progress-bar \
  -o /tmp/bun-zig.zip \
  "https://github.com/oven-sh/zig/releases/download/autobuild-${ZIG_COMMIT}/bootstrap-x86_64-linux-musl-ReleaseSafe.zip"

rm -rf /tmp/bun-zig-extract "$ZIG_DIR"
unzip -q /tmp/bun-zig.zip -d /tmp/bun-zig-extract
inner=$(find /tmp/bun-zig-extract -mindepth 1 -maxdepth 1 -type d | head -n1)
mv "$inner" "$ZIG_DIR"
rm -rf /tmp/bun-zig-extract /tmp/bun-zig.zip

export ZIGIX_BUN_ZIG="$ZIG_DIR/zig"
export ZIGIX_BUN_ZIG_PINNED_VERSION=0.15.2
```

Disk: ~128 MB compressed, ~520 MB extracted. The bundle includes the bundled
stdlib (`<dest>/lib/`) which Zig auto-detects when invoked from this layout.

For aarch64 / macOS / Windows hosts substitute the matching asset name from
the release page (e.g. `bootstrap-aarch64-linux-musl-ReleaseSafe.zip`).

## Verifying the active compiler

```sh
export ZIGIX_BUN_ZIG=/absolute/path/to/bun-zig
tools/toolchain/check-bun-zig.sh
```

This prints the compiler identity and emits a `[ZIGIX:TOOLCHAIN:...]` line
that the QEMU smoke parser recognizes. If `ZIGIX_BUN_ZIG` is unset, points to
a non-executable file, or points to a system-looking path without
`ZIGIX_ALLOW_SYSTEM_ZIG=1`, the script exits non-zero with a clear message.

You can also run, once Bun Zig is on the host:

```sh
tools/toolchain/zig-bun build check-toolchain
```

## How the wrapper prevents accidental system-Zig usage

`tools/toolchain/zig-bun` is the **only** Zig invocation the project uses in
build scripts and CI. It refuses to run when:

- `ZIGIX_BUN_ZIG` is unset;
- `ZIGIX_BUN_ZIG` is not an executable file;
- `ZIGIX_BUN_ZIG` resolves to a known system path
  (`/usr/bin/zig`, `/usr/local/bin/zig`, `~/.local/bin/zig`) without
  `ZIGIX_ALLOW_SYSTEM_ZIG=1`.

The wrapper logs `[ZIGIX:TOOLCHAIN:zig-bun=<path> version=<v>]` to stderr on
each invocation (silencable via `ZIGIX_LOG_TOOLCHAIN=0`) so build/test logs
always contain the identity.

When `ZIG_GLOBAL_CACHE_DIR` is unset, the wrapper sets it to
`${TMPDIR:-/tmp}/zigix-zig-cache`. This keeps Zigix builds isolated from a
host user's generic Zig cache while still allowing callers to override the
cache path explicitly.

## Does the fork compile freestanding kernel code?

**Yes — confirmed through Phase 10.** `tools/toolchain/zig-bun build qemu-smoke`
produces an ELF that boots in QEMU, parses the Multiboot1 memory map, runs the
kernel smoke registry, catches a deliberate `#UD`, advances the PIT tick, and
mounts the initramfs-backed VFS root, exercises syscall ABI v0, validates a
static ELF64 load plan, then runs a freestanding ring-3 init through
`int 0x80`. The Phase 9 gate also exercises process-owned file descriptors,
`dup`, and basic pipe read/write behavior. The Phase 10 gate adds the first
process-table/PID lifecycle and `wait4` reaping slice.

Caveats discovered:

- The Zig 0.15.2 self-hosted x86_64 backend tripped on
  `error(x86_64_encoder): no encoding found for: none movups xmm0 m128`
  even with `sse`, `sse2`, `avx` etc. subtracted from the CPU feature
  set. **Workaround**: pass `use_llvm = true` on the executable. LLVM
  honors the feature subtraction strictly, the self-hosted backend at
  this commit does not. This is a likely-shared issue with upstream
  Zig 0.15.x rather than a Bun-fork divergence.
- QEMU's `-kernel` multiboot1 loader requires an ELF32-i386 file; Zig
  emits ELF64. Worked around with `objcopy -O elf32-i386` as a build
  post-step. Not a toolchain issue.

## Known incompatibilities versus upstream Zig

**Unknown — to be discovered.** Each incompatibility found gets a section
here with: minimal reproduction, observed behavior, upstream-Zig behavior for
the same input, and the workaround (if any).

The Bun fork at this commit is based on upstream Zig 0.15.x. Bun's
documented additions include private fields (identifiers prefixed with `#`),
which the kernel does not use. If a future Zig refactor in this repo starts
to use `#`-prefixed identifiers, that becomes a fork lock-in we should call
out here.

## Compile-time measurements

Tracked in [`docs/benchmark-methodology.md`](benchmark-methodology.md). The
script `tools/toolchain/measure-compile.sh` is created the first time there is
something meaningful to measure (Phase 1 onward). Until then this section
reads "no measurements yet."

## Honesty section: what can and cannot be automatically verified

What the wrapper **can** verify automatically:

- The compiler binary exists and is executable.
- The compiler returns a parseable `zig version` string.
- That version string optionally matches a pin token.
- The path is not a known system Zig path (modulo opt-in).

What the wrapper **cannot** verify automatically:

- Whether the binary genuinely came from the Bun fork. A user who points
  `ZIGIX_BUN_ZIG` at upstream Zig will pass the executability and version
  checks. The pinning relies on the user supplying a `ZIGIX_BUN_ZIG_PINNED_VERSION`
  token they sourced from a known-good Bun-fork build, or on a checksum
  recorded out-of-band.
- Whether the compiler will succeed on a freestanding kernel target. That is
  a Phase 1 acceptance test, not a static check.

## Is Bun Zig actually useful for this OS project?

**Not yet measured.** Update this section after Phase 1 boots and Phase 0's
compile-time measurement script has produced a number worth comparing. State
the verdict here with the data, not with vibes.
