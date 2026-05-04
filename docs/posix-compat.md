# POSIX compatibility matrix

This table tracks **source-compatibility** with POSIX / musl / newlib. We do
not chase Linux binary compatibility.

Update this file whenever syscall or POSIX semantics change.

| API      | Status  | Notes                          | Tests |
| -------- | ------- | ------------------------------ | ----- |
| `read`   | missing | planned for Phase 6            | none  |
| `write`  | missing | planned for Phase 6            | none  |
| `open`   | missing | planned for Phase 6            | none  |
| `close`  | missing | planned for Phase 6            | none  |
| `lseek`  | missing | planned for Phase 6            | none  |
| `stat`   | missing | planned for Phase 6            | none  |
| `exit`   | missing | planned for Phase 6            | none  |
| `execve` | missing | planned for Phase 10           | none  |
| `fork`   | missing | decision pending (Phase 13)    | none  |
| `mmap`   | missing | planned for Phase 13+          | none  |
| signals  | missing | planned for Phase 13+          | none  |
| sockets  | missing | future                         | none  |

Status values:

- **missing** — not implemented.
- **partial** — implemented for at least one valid use case; gaps documented.
- **working** — passes all the tests in the rightmost column.

A "missing" row that grows tests before it grows status is a feature, not a
bug.
