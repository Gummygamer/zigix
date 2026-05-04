# Syscall ABI

Stub. This document is owned by Phase 6.

When Phase 6 lands it must specify, at minimum:

- syscall number registry (and stability rules);
- argument-passing convention on x86_64;
- return / errno convention;
- per-syscall:
  - number
  - signature
  - errno set
  - userspace-pointer validation rules
  - tests that cover it.

Until then, do not invent syscall numbers.
