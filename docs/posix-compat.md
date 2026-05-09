# POSIX compatibility matrix

This table tracks **source-compatibility** with POSIX / musl / newlib. We do
not chase Linux binary compatibility.

Update this file whenever syscall or POSIX semantics change.

| API      | Status  | Notes                                      | Tests |
| -------- | ------- | ------------------------------------------ | ----- |
| `read`   | partial | VFS files, polled serial stdin with `EAGAIN` when empty, pipe read ends | `syscall_vfs`, `syscall_fd_table`, `syscall_pipe`, `syscall_stdin_console`, `tinysh_interactive` |
| `write`  | partial | stdout/stderr serial output, pipe write ends | `syscall_write`, `syscall_pipe` |
| `open`   | partial | read-only absolute VFS paths               | `syscall_vfs`, `syscall_fd_table` |
| `close`  | partial | per-process fd tables; spawned children inherit descriptors lazily | `syscall_vfs`, `syscall_fd_table`, `syscall_pipe`, `process_fd_tables` |
| `lseek`  | partial | VFS files only                             | `syscall_vfs`, `syscall_fd_table` |
| `stat`   | partial | compact Zigix stat layout                  | `syscall_vfs` |
| `pipe`   | partial | bounded buffer; first park/wake path for empty reads and full writes; cooperative run queues wake blocked endpoints | `syscall_pipe`, `syscall_pipe_blocking` |
| `dup`    | partial | lowest free fd; clears close-on-exec       | `syscall_fd_table`, `syscall_pipe` |
| `_exit`  | partial | userspace wrapper; `exit_group` aliases raw `exit` for now | userspace init smoke |
| `exit`   | partial | raw syscall exits QEMU through debug port  | userspace init smoke |
| `waitpid` | partial | userspace wrapper over `wait4`; blocks for spawned children | `process_lifecycle`, `process_wait_nohang`, `process_wait_blocking` |
| `wait4`  | partial | reaps exited children; `WNOHANG`; blocking wait runs spawned child | `process_lifecycle`, `process_wait_nohang`, `process_wait_blocking` |
| `execve` | partial | static ELF path; bounded `argv`/`envp`; auxv deferred | `execve_load`, `execve_argv_stack` |
| `posix_spawn` | partial | Zigix extension returns child PID; inherits fd table and applies close-on-exec in the child; no pid-out, file actions, attributes, or independent scheduling yet | `spawn_child_image`, `posix_spawn_handoff`, `process_wait_blocking`, `process_fd_tables` |
| `fork`   | missing | deferred; prefer `posix_spawn` until per-process address spaces exist | none  |
| `mmap`   | missing | planned for Phase 14+                      | none  |
| signals  | missing | planned for Phase 14+                      | none  |
| sockets  | missing | future                                     | none  |

Status values:

- **missing** — not implemented.
- **partial** — implemented for at least one valid use case; gaps documented.
- **working** — passes all the tests in the rightmost column.

A "missing" row that grows tests before it grows status is a feature, not a
bug.
