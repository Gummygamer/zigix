/* Bootstrap runtime for upstream Toybox taskset.c's nproc applet. */

#define FOR_taskset
#include "toys.h"

#include <stdarg.h>

struct zigix_toy_context toys;
char toybuf[4096];

void xprintf(char *format, ...) {
  va_list args;
  va_start(args, format);
  vprintf(format, args);
  va_end(args);
}

int smemcmp(char *one, char *two, unsigned long length) {
  if (one == two) return 0;
  if (!one) return 1;
  if (!two) return -1;
  while (length--) {
    int difference = *one++ - *two++;
    if (difference) return difference;
  }
  return 0;
}

long syscall(long number, ...) {
  (void)number;
  errno = ENOSYS;
  return -1;
}

void nproc_main(void);

int main(void) {
  /* --all skips the unavailable affinity syscall and selects sysfs. */
  toys.optflags = FLAG_a;
  nproc_main();
  return fflush(stdout) == 0 ? 0 : 2;
}
