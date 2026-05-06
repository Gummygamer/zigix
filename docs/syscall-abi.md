# Syscall ABI

Phase 6 defines Zigix syscall ABI v0 for x86_64. The registry deliberately
uses Linux x86_64 syscall numbers for the initial subset so early userspace can
share conventional syscall stubs.

## Calling Convention

- Entry registers: `RAX = syscall number`.
- Arguments: `RDI`, `RSI`, `RDX`, `R10`, `R8`, `R9`.
- Return: `RAX`.
- Success returns a non-negative integer.
- Failure returns `-errno` in `RAX`.
- Syscalls clobber `RCX` and `R11`.
- `int 0x80` is wired for Phase 6 kernel self-tests and the Phase 8 first
  userspace process. The ABI register layout is already the Linux x86_64
  `syscall` layout; `syscall/sysret` is a later entry-path upgrade.

Userspace pointers are virtual addresses in the caller address space. Phase 8
maps the first init into user-accessible pages, but pointer validation is still
limited to null and bounded-length checks. Real copy-in/copy-out validation is
required before untrusted userspace expands beyond the fixed first init.

## Errno

The syscall layer uses Linux errno numbers for the exposed set:

| Name | Value |
| :--- | ----: |
| `EPERM` | 1 |
| `ENOENT` | 2 |
| `EIO` | 5 |
| `E2BIG` | 7 |
| `ENOEXEC` | 8 |
| `EBADF` | 9 |
| `ECHILD` | 10 |
| `EAGAIN` | 11 |
| `EFAULT` | 14 |
| `ENOTDIR` | 20 |
| `EISDIR` | 21 |
| `EINVAL` | 22 |
| `ENFILE` | 23 |
| `EPIPE` | 32 |
| `ENAMETOOLONG` | 36 |
| `ENOSYS` | 38 |

## Syscalls

| Number | Name | Signature |
| ----: | :--- | :--- |
| 0 | `read` | `ssize_t read(int fd, void *buf, size_t count)` |
| 1 | `write` | `ssize_t write(int fd, const void *buf, size_t count)` |
| 2 | `open` | `int open(const char *path, int flags, mode_t mode)` |
| 3 | `close` | `int close(int fd)` |
| 4 | `stat` | `int stat(const char *path, struct zigix_stat *st)` |
| 5 | `fstat` | `int fstat(int fd, struct zigix_stat *st)` |
| 8 | `lseek` | `off_t lseek(int fd, off_t offset, int whence)` |
| 22 | `pipe` | `int pipe(int pipefd[2])` |
| 32 | `dup` | `int dup(int oldfd)` |
| 59 | `execve` | `int execve(const char *path, char *const argv[], char *const envp[])` |
| 60 | `exit` | `void exit(int status)` |
| 61 | `wait4` | `pid_t wait4(pid_t pid, int *wstatus, int options, void *rusage)` |
| 231 | `exit_group` | `void exit_group(int status)` |

### `read`

Reads from a VFS-backed descriptor opened by `open`, or from a pipe read end.
`fd == 0` returns EOF for now; `fd == 1`, `fd == 2`, and pipe write ends fail
with `EBADF`.

Errors: `EBADF`, `EFAULT`, VFS-mapped errors.

### `write`

Writes bytes to the serial console for `fd == 1` or `fd == 2`, or to a pipe
write end. VFS-backed descriptors and pipe read ends are not writable yet.
Writing a pipe with no read endpoints fails with `EPIPE`.

Errors: `EBADF`, `EFAULT`, `EPIPE`.

### `open`

Opens an absolute VFS path read-only. `flags` may be `0` or `O_CLOEXEC`
(`02000000`); `mode` is ignored. Returned descriptors use the process file
table and start at `3` while standard descriptors are still open.

Errors: `EINVAL`, `EFAULT`, `ENFILE`, VFS-mapped errors.

### `close`

Closes a descriptor in the current process file table. This includes standard
descriptors `0`, `1`, and `2`; later opens reuse the lowest available slot.

Errors: `EBADF`.

### `lseek`

Supports `SEEK_SET = 0`, `SEEK_CUR = 1`, and `SEEK_END = 2` on VFS-backed
descriptors. Negative resulting offsets fail.

Errors: `EBADF`, `EINVAL`.

### `pipe`

Creates a read descriptor in `pipefd[0]` and a write descriptor in `pipefd[1]`.
Pipe descriptors are process-owned fd table entries and may be duplicated with
`dup`; duplicated endpoints share one bounded 4096-byte kernel buffer.

Phase 9 implements immediate read/write behavior only. Reads from an empty
pipe return `0`, and writes to a full pipe may return a short count. Blocking
and wakeups require scheduler/process lifecycle work and remain future work.

Errors: `EFAULT`, `ENFILE`, `EPIPE` on later writes after all read ends close.

### `dup`

Duplicates an existing descriptor into the lowest free descriptor slot. VFS
descriptors share one open-file state, so file offsets move together across the
original and duplicate. Pipe duplicates share endpoint state and the pipe
buffer. The duplicate's close-on-exec flag is cleared, matching Unix `dup`
semantics.

Errors: `EBADF`, `ENFILE`.

### `execve`

Loads a static ELF64 executable from an absolute VFS path and enters it in ring
3. Phase 10 replaces the current user image and stack pages, accepts null or
bounded `argv`/`envp` vectors, and builds the initial stack as:

```text
argc
argv[0] ... argv[n - 1]
NULL
envp[0] ... envp[n - 1]
NULL
NUL-terminated argument and environment strings
```

The current implementation caps each vector at eight strings and each string at
256 bytes. Larger vectors or strings fail with `E2BIG`. Auxv remains future
work. Descriptors marked `O_CLOEXEC` are closed only after the image has loaded
successfully.

Errors: `E2BIG`, `EFAULT`, `EINVAL`, `ENOENT`, `ENOEXEC`, VFS-mapped errors.

### `wait4`

Reaps an already-exited child process. Phase 10 supports `pid > 0` and
`pid == -1`, `options == 0` or `WNOHANG = 1`, and `rusage == NULL`. The status
word uses the normal Unix exited-process layout: low eight bits of the exit
code shifted left by eight.

If a matching child exists but has not exited, `WNOHANG` returns `0` and leaves
the status word untouched. A blocking wait that would need to park the caller
returns `EAGAIN` until scheduler wakeups exist.

Errors: `EAGAIN`, `ECHILD`, `EINVAL`, `EFAULT`.

The shared Zig userspace syscall module also exposes `waitpid(pid, status,
options)` as a wrapper over `wait4(pid, status, options, NULL)`.

### `exit` / `exit_group`

Both numbers currently terminate the only running user process and end the QEMU
smoke run through the debug-exit port. `exit_group` exists as a compatibility
alias for libc-style `_exit` wrappers before real thread groups exist.

### `stat` / `fstat`

Fills `struct zigix_stat`, a small fixed layout used until libc work decides
whether to match Linux `struct stat` byte-for-byte:

```c
struct zigix_stat {
    uint64_t dev;
    uint64_t ino;
    uint64_t nlink;
    uint32_t mode;
    uint32_t uid;
    uint32_t gid;
    uint64_t rdev;
    int64_t size;
    int64_t blksize;
    int64_t blocks;
};
```

`mode` uses Linux file type bits for regular files, directories, character
devices, and FIFO/pipe descriptors.

Errors: `EBADF`, `EFAULT`, VFS-mapped errors.

## Tests

The Phase 6 smoke path installs `int 0x80`, invokes `write(1, marker, len)` via
the trap path from a kernel self-test, and expects:

```text
[ZIGIX:SYSCALL:OK]
```

The first Phase 9 file-descriptor slice adds an in-kernel syscall test named
`syscall_fd_table`. It covers process-owned descriptor slots, `dup` sharing
file offsets, duplicate lifetime after closing the original descriptor, and
close-on-exec metadata.

The pipe slice adds `syscall_pipe`, covering `pipe`, read/write round-trips,
endpoint access checks, duplicated write endpoints, EOF after writers close,
and `EPIPE` after all read endpoints close.

The first Phase 10 lifecycle slice adds `process_lifecycle`, covering PID
allocation, child exit state, `wait4` status reporting, and one-shot reaping.
`process_wait_nohang` covers live-child waits, `WNOHANG`, and the temporary
`EAGAIN` behavior for waits that would block.

The exec slice adds `execve_load`, covering side-effect-free validation of the
initramfs `/exec-ok` ELF image through the exec loader path and close-on-exec
descriptor cleanup. `execve_argv_stack` covers bounded argv/envp copy-in and
the initial stack shape. The QEMU init path also exercises the successful
user-mode transition with non-null argv/envp: `/init` emits
`[ZIGIX:INIT:START]`, execs `/exec-ok`, and the replacement image emits
`[ZIGIX:INIT:OK]`. The same userspace smoke binaries compile against
`userspace/lib/sys.zig`, which provides the current `_exit` and `waitpid`
compatibility wrappers.
