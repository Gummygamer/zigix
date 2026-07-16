typedef unsigned long size_t;

static long syscall1(long number, long arg0) {
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0)
                   : "rcx", "r11", "memory");
  return number;
}

static long syscall2(long number, long arg0, long arg1) {
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0), "S"(arg1)
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
  static const char *echo_argv[] = {
      "/toybox-echo",
      "[ZIGIX:TEST:PASS:toybox]",
      0,
  };
  static const char *cat_argv[] = {
      "/toybox-cat",
      "/toybox-cat-input",
      0,
  };

  say("[ZIGIX:INIT:START]\n");
  long pid = syscall3(4000, (long)echo_argv[0], (long)echo_argv, 0);
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

  status = -1;
  pid = syscall3(4000, (long)cat_argv[0], (long)cat_argv, 0);
  if (pid <= 0) {
    say("[ZIGIX:TEST:FAIL:toybox_cat:spawn]\n");
    quit(1);
  }
  waited = syscall4(61, pid, (long)&status, 0, 0);
  if (waited != pid || status != 0) {
    say("[ZIGIX:TEST:FAIL:toybox_cat:wait]\n");
    quit(1);
  }

  long saved_stdout = syscall1(32, 1);
  long capture = syscall3(2, (long)"/nproc-output", 02 | 0100 | 01000, 0);
  if (saved_stdout < 3 || capture < 3 || syscall2(33, capture, 1) != 1) {
    say("[ZIGIX:TEST:FAIL:toybox_nproc:redirect]\n");
    quit(1);
  }
  syscall1(3, capture);

  pid = syscall3(4000, (long)"/toybox-nproc", 0, 0);
  if (pid <= 0) {
    syscall2(33, saved_stdout, 1);
    say("[ZIGIX:TEST:FAIL:toybox_nproc:spawn]\n");
    quit(1);
  }
  status = -1;
  waited = syscall4(61, pid, (long)&status, 0, 0);
  syscall2(33, saved_stdout, 1);
  syscall1(3, saved_stdout);
  if (waited != pid || status != 0) {
    say("[ZIGIX:TEST:FAIL:toybox_nproc:wait]\n");
    quit(1);
  }

  capture = syscall3(2, (long)"/nproc-output", 0, 0);
  char output[4] = {0};
  long amount = capture < 3 ? -1 : syscall3(0, capture, (long)output, sizeof(output));
  if (capture >= 3) syscall1(3, capture);
  if (amount != 2 || output[0] != '2' || output[1] != '\n') {
    say("[ZIGIX:TEST:FAIL:toybox_nproc:output]\n");
    quit(1);
  }
  say("[ZIGIX:TEST:PASS:toybox_nproc]\n");

  saved_stdout = syscall1(32, 1);
  capture = syscall3(2, (long)"/id-output", 02 | 0100 | 01000, 0);
  if (saved_stdout < 3 || capture < 3 || syscall2(33, capture, 1) != 1) {
    say("[ZIGIX:TEST:FAIL:toybox_id:redirect]\n");
    quit(1);
  }
  syscall1(3, capture);

  pid = syscall3(4000, (long)"/toybox-id", 0, 0);
  if (pid <= 0) {
    syscall2(33, saved_stdout, 1);
    say("[ZIGIX:TEST:FAIL:toybox_id:spawn]\n");
    quit(1);
  }
  status = -1;
  waited = syscall4(61, pid, (long)&status, 0, 0);
  syscall2(33, saved_stdout, 1);
  syscall1(3, saved_stdout);
  if (waited != pid || status != 0) {
    say("[ZIGIX:TEST:FAIL:toybox_id:wait]\n");
    quit(1);
  }

  capture = syscall3(2, (long)"/id-output", 0, 0);
  output[0] = output[1] = output[2] = output[3] = 0;
  amount = capture < 3 ? -1 : syscall3(0, capture, (long)output, sizeof(output));
  if (capture >= 3) syscall1(3, capture);
  if (amount != 2 || output[0] != '0' || output[1] != '\n') {
    say("[ZIGIX:TEST:FAIL:toybox_id:output]\n");
    quit(1);
  }
  say("[ZIGIX:TEST:PASS:toybox_id]\n");

  say("[ZIGIX:INIT:OK]\n");
  quit(0);
}
