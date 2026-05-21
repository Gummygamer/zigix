# Syscall ABI

Phase 6 defines Zigix syscall ABI v0 for x86_64. The registry deliberately
uses Linux x86_64 syscall numbers for the initial subset so early userspace can
share conventional syscall stubs. Zigix-only extension numbers start at 4000
until a compatibility layer decides how to present them to libc.

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
| 33 | `dup2` | `int dup2(int oldfd, int newfd)` |
| 39 | `getpid` | `pid_t getpid(void)` |
| 59 | `execve` | `int execve(const char *path, char *const argv[], char *const envp[])` |
| 60 | `exit` | `void exit(int status)` |
| 61 | `wait4` | `pid_t wait4(pid_t pid, int *wstatus, int options, void *rusage)` |
| 76 | `truncate` | `int truncate(const char *path, off_t length)` |
| 77 | `ftruncate` | `int ftruncate(int fd, off_t length)` |
| 80 | `chdir` | `int chdir(const char *path)` |
| 82 | `rename` | `int rename(const char *oldpath, const char *newpath)` |
| 83 | `mkdir` | `int mkdir(const char *path, mode_t mode)` |
| 87 | `unlink` | `int unlink(const char *path)` |
| 110 | `getppid` | `pid_t getppid(void)` |
| 217 | `getdents64` | `int getdents64(int fd, void *dirp, unsigned int count)` |
| 231 | `exit_group` | `void exit_group(int status)` |
| 4000 | `posix_spawn` | `int posix_spawn(const char *path, char *const argv[], char *const envp[])` |

### `read`

Reads from serial-backed stdin (`fd == 0`), a VFS-backed descriptor opened by
`open`, or a pipe read end. Empty serial reads return `EAGAIN`; `fd == 1`,
`fd == 2`, and pipe write ends fail with `EBADF`.

Errors: `EBADF`, `EFAULT`, VFS-mapped errors.

### `write`

Writes bytes to the serial console for `fd == 1` or `fd == 2`, to a writable
memfs file descriptor, or to a pipe write end. Pipe read ends and read-only
file descriptors are not writable. Writing a pipe with no read endpoints fails
with `EPIPE`.

Errors: `EBADF`, `EFAULT`, `EPIPE`.

### `open`

Opens a VFS path. Relative paths resolve against the caller's current working
directory. `flags` may combine `O_WRONLY` (`01`), `O_RDWR` (`02`), `O_CREAT`
(`0100`), `O_TRUNC` (`01000`), and `O_CLOEXEC` (`02000000`); `mode` is ignored.
Returned descriptors use the process file table and start at `3` while
standard descriptors are still open.

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
pipe with no write endpoints return `0`. Empty reads with live writers and
full writes park the current process in a pipe wait queue and wake on the
opposite endpoint when data or space becomes available. Until general
scheduler run queues exist, these parked syscalls return `EAGAIN` so kernel
tests can drive the state transition explicitly. Writes larger than remaining
capacity may still return a short count.

Errors: `EFAULT`, `ENFILE`, `EAGAIN`, `EPIPE` on later writes after all read
ends close.

### `dup`

Duplicates an existing descriptor into the lowest free descriptor slot. VFS
descriptors share one open-file state, so file offsets move together across the
original and duplicate. Pipe duplicates share endpoint state and the pipe
buffer. The duplicate's close-on-exec flag is cleared, matching Unix `dup`
semantics.

Errors: `EBADF`, `ENFILE`.

### `dup2`

Duplicates an existing descriptor onto a requested descriptor slot. If `newfd`
is already open, Zigix closes it before installing the duplicate. If `oldfd`
equals `newfd`, the call validates the descriptor and returns without changing
close-on-exec state. New duplicates share VFS open-file offsets or pipe
endpoint state with `oldfd`, and their close-on-exec flag is cleared.

Errors: `EBADF`.

### `truncate` / `ftruncate`

Resizes memfs files. Extending a file zero-fills the new range. The current
fixed-capacity memfs stores at most 4096 bytes per file.

Errors: `EBADF`, `EFAULT`, `EFBIG`, `EISDIR`, VFS-mapped errors.

### `getpid` / `getppid`

Returns the caller's process ID or its parent's process ID. The bootstrap
process has no parent, so `getppid` returns `0` for PID 1.

Errors: none.

### `getdents64`

Reads directory entries from a directory descriptor opened with `open`. Records
use the Linux `linux_dirent64` byte layout: `d_ino`, `d_off`, `d_reclen`,
`d_type`, then a NUL-terminated name. Zigix currently reports `DT_REG` and
`DT_DIR`; inode numbers are stable hashes of entry names until the VFS grows
real inode IDs.

Errors: `EBADF`, `EFAULT`, `EINVAL`, `ENOTDIR`, VFS-mapped errors.

### `mkdir` / `unlink` / `rename`

Creates directories, removes files or empty directories, and renames an entry
within the memfs namespace. `rename` currently fails with `EEXIST` if the
target already exists; replacement semantics are deferred until a caller needs
them.

Errors: `EEXIST`, `EFAULT`, `EINVAL`, `ENOENT`, `ENOTDIR`, `ENOTEMPTY`,
VFS-mapped errors.

### `execve`

Loads a static ELF64 executable from a VFS path and enters it in ring
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

### `chdir`

Updates the current process working directory. Relative paths are resolved
against the existing current directory and normalized before the target is
validated. Spawned children inherit the parent's current directory through the
per-process descriptor-table state.

Errors: `EFAULT`, `EINVAL`, `ENAMETOOLONG`, `ENOENT`, `ENOTDIR`.

### `posix_spawn`

Zigix exposes a temporary extension syscall for the Phase 10 spawn handoff. It
creates a child PID, loads a static ELF64 executable from a VFS path
into the child's page-table root, builds the same bounded `argv`/`envp` stack
shape as `execve`, records the child's initial entry/stack in the process
table, and returns the child PID. The child runs when the parent performs a
blocking `wait4`/`waitpid` for it.

This is intentionally narrower than POSIX `posix_spawn`: there is no pid-out
argument, file actions, spawn attributes, or independent parent/child
scheduling yet. Descriptors marked `O_CLOEXEC` are closed before entering the
child image from blocking `wait4`.

Errors: `E2BIG`, `EFAULT`, `EINVAL`, `ENOENT`, `ENOEXEC`, `ENFILE`,
VFS-mapped errors.

### `wait4`

Reaps an already-exited child process. Phase 10 supports `pid > 0` and
`pid == -1`, `options == 0` or `WNOHANG = 1`, and `rusage == NULL`. The status
word uses the normal Unix exited-process layout: low eight bits of the exit
code shifted left by eight.

If a matching child exists but has not exited, `WNOHANG` returns `0` and leaves
the status word untouched. A blocking wait for a spawned child saves the
parent's kernel continuation, parks the parent, switches to the child's address
space and kernel stack, enters the child image, and resumes the parent when the
child exits so the syscall can reap it and return the child PID.

Errors: `EAGAIN` for internal live children without an executable image,
`ECHILD`, `EINVAL`, `EFAULT`.

The shared Zig userspace syscall module also exposes `waitpid(pid, status,
options)` as a wrapper over `wait4(pid, status, options, NULL)`.

### `exit` / `exit_group`

Both numbers mark the current process exited. If the process is the active
blocking-wait child, exit resumes the saved parent continuation; otherwise the
kernel ends the QEMU smoke run through the debug-exit port. `exit_group` exists
as a compatibility alias for libc-style `_exit` wrappers before real thread
groups exist.

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
and `EPIPE` after all read endpoints close. `syscall_pipe_blocking` covers the
first process-aware pipe wait queues: empty reads and full writes park the
caller, then wake when the opposite endpoint writes or reads.

The first Phase 10 lifecycle slice adds `process_lifecycle`, covering PID
allocation, child exit state, `wait4` status reporting, and one-shot reaping.
`process_wait_nohang` covers live-child waits and `WNOHANG`.
`process_wait_blocking` covers parking the parent, entering a spawned child,
resuming on child exit, status reporting, and reaping.
`process_fd_tables` covers per-PID descriptor-table inheritance for spawned
children, child-only descriptor close, child-only close-on-exec cleanup, and
parent descriptor survival across child descriptor mutations.

The exec slice adds `execve_load`, covering side-effect-free validation of the
initramfs `/exec-ok` ELF image through the exec loader path and close-on-exec
descriptor cleanup. `execve_argv_stack` covers bounded argv/envp copy-in and
the initial stack shape. `spawn_child_image` covers the in-kernel preparation
path for future `posix_spawn`: loading `/exec-ok` for a child PID while keeping
the parent's region registry unchanged, then releasing the child's regions.
`posix_spawn_handoff` covers the syscall preparation path and child page-table
ownership. `process_spawn_resume` covers the saved parent continuation model
that lets child exit resume the parent-side syscall frame. The QEMU init path
also exercises the successful user-mode transition with non-null argv/envp:
`/init` emits `[ZIGIX:INIT:START]`, spawns `/exec-ok`, waits for the returned
PID, and the child image emits `[ZIGIX:INIT:OK]`. The same userspace smoke
binaries compile against
`userspace/lib/sys.zig`, which provides the current `_exit`, `waitpid`, and
`posixSpawn` compatibility wrappers.
