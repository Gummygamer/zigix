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
- `int 0x80` is wired for Phase 6 kernel self-tests. The ABI register layout
  is already the Linux x86_64 `syscall` layout; user-mode `syscall/sysret`
  entry becomes active with the ring-3 transition in Phase 8.

Userspace pointers are virtual addresses in the caller address space. Phase 6
only has kernel-mode self-tests, so pointer validation is limited to null and
bounded-length checks. Phase 8 must replace this with real user mapping and
copy-in/copy-out validation.

## Errno

The syscall layer uses Linux errno numbers for the exposed set:

| Name | Value |
| :--- | ----: |
| `EPERM` | 1 |
| `ENOENT` | 2 |
| `EIO` | 5 |
| `EBADF` | 9 |
| `EFAULT` | 14 |
| `ENOTDIR` | 20 |
| `EISDIR` | 21 |
| `EINVAL` | 22 |
| `ENFILE` | 23 |
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
| 60 | `exit` | `void exit(int status)` |

### `read`

Reads from a VFS-backed descriptor opened by `open`. `fd == 0` returns EOF for
now; `fd == 1` and `fd == 2` fail with `EBADF`.

Errors: `EBADF`, `EFAULT`, VFS-mapped errors.

### `write`

Writes bytes to the serial console for `fd == 1` or `fd == 2`. Other
descriptors are not writable in v0.

Errors: `EBADF`, `EFAULT`.

### `open`

Opens an absolute VFS path read-only. `flags` must be `0`; `mode` is ignored.
Returned descriptors start at `3`.

Errors: `EINVAL`, `EFAULT`, `ENFILE`, VFS-mapped errors.

### `close`

Closes descriptors `>= 3`. Closing `0`, `1`, or `2` is accepted as a no-op in
v0 because there is no process file table yet.

Errors: `EBADF`.

### `lseek`

Supports `SEEK_SET = 0`, `SEEK_CUR = 1`, and `SEEK_END = 2` on VFS-backed
descriptors. Negative resulting offsets fail.

Errors: `EBADF`, `EINVAL`.

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

`mode` uses Linux file type bits for regular files, directories, and character
devices.

Errors: `EBADF`, `EFAULT`, VFS-mapped errors.

## Tests

The Phase 6 smoke path installs `int 0x80`, invokes `write(1, marker, len)` via
the trap path from a kernel self-test, and expects:

```text
[ZIGIX:SYSCALL:OK]
```
