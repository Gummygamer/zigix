typedef unsigned long size_t;

static long syscall1(long number, long arg0) {
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0)
                   : "rcx", "r11", "memory");
  return number;
}

static long syscall3(long number, long arg0, long arg1, long arg2) {
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0), "S"(arg1), "d"(arg2)
                   : "rcx", "r11", "memory");
  return number;
}

static long syscall4(long number, long arg0, long arg1, long arg2, long arg3) {
  register long r10 __asm__("r10") = arg3;
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0), "S"(arg1), "d"(arg2), "r"(r10)
                   : "rcx", "r11", "memory");
  return number;
}

static size_t length(const char *text) {
  size_t count = 0;
  while (text[count]) ++count;
  return count;
}

static void say(const char *text) {
  syscall3(1, 1, (long)text, length(text));
}

static void quit(int status) {
  syscall1(231, status);
  for (;;) __asm__ volatile("pause");
}

void _start(void) {
  static const char *argv[] = {
      "/toybox-echo",
      "[ZIGIX:TEST:PASS:toybox]",
      0,
  };

  say("[ZIGIX:INIT:START]\n");
  long pid = syscall3(4000, (long)argv[0], (long)argv, 0);
  if (pid <= 0) {
    say("[ZIGIX:TEST:FAIL:toybox:spawn]\n");
    quit(1);
  }

  int status = -1;
  long waited = syscall4(61, pid, (long)&status, 0, 0);
  if (waited != pid || status != 0) {
    say("[ZIGIX:TEST:FAIL:toybox:wait]\n");
    quit(1);
  }

  say("[ZIGIX:INIT:OK]\n");
  quit(0);
}
