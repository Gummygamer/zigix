# POSIX compatibility matrix

This table tracks **source-compatibility** with POSIX / musl / newlib. We do
not chase Linux binary compatibility.

Update this file whenever syscall or POSIX semantics change.

| API      | Status  | Notes                                      | Tests |
| -------- | ------- | ------------------------------------------ | ----- |
| `read`   | partial | VFS files, stdin EOF, pipe read ends       | `syscall_vfs`, `syscall_fd_table`, `syscall_pipe` |
| `write`  | partial | stdout/stderr serial output, pipe write ends | `syscall_write`, `syscall_pipe` |
| `open`   | partial | read-only absolute VFS paths               | `syscall_vfs`, `syscall_fd_table` |
| `close`  | partial | current process fd table only              | `syscall_vfs`, `syscall_fd_table`, `syscall_pipe` |
| `lseek`  | partial | VFS files only                             | `syscall_vfs`, `syscall_fd_table` |
| `stat`   | partial | compact Zigix stat layout                  | `syscall_vfs` |
| `pipe`   | partial | bounded buffer; blocking deferred          | `syscall_pipe` |
| `dup`    | partial | lowest free fd; clears close-on-exec       | `syscall_fd_table`, `syscall_pipe` |
| `exit`   | partial | exits QEMU through debug port              | userspace init smoke |
| `execve` | partial | static ELF path only; `argv`/`envp` must be `NULL` | `execve_load` |
| `fork`   | missing | deferred; prefer `posix_spawn` until per-process address spaces exist | none  |
| `mmap`   | missing | planned for Phase 13+                      | none  |
| signals  | missing | planned for Phase 13+                      | none  |
| sockets  | missing | future                                     | none  |

Status values:

- **missing** — not implemented.
- **partial** — implemented for at least one valid use case; gaps documented.
- **working** — passes all the tests in the rightmost column.

A "missing" row that grows tests before it grows status is a feature, not a
bug.
