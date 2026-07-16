/* Bootstrap runtime for upstream Toybox pwd.c. */

#define FOR_pwd
#include "toys.h"

struct zigix_toy_context toys;

int stat(const char *path, struct stat *out) {
  (void)path;
  (void)out;
  errno = ENOSYS;
  return -1;
}

int same_file(struct stat *left, struct stat *right) {
  return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

void perror_exit(char *format, ...) {
  (void)format;
  exit(2);
}

void pwd_main(void);

int main(void) {
  toys.optflags = FLAG_P;
  pwd_main();
  return fflush(stdout) == 0 ? 0 : 2;
}
