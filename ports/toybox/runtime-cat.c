/* Bootstrap runtime for upstream Toybox cat.c. */

#include "toys.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

struct zigix_toy_context toys;
char toybuf[4096];

void perror_msg_raw(char *message) {
  fprintf(stderr, "%s: errno %d\n", message, errno);
}

void xputc(char value) {
  putchar((unsigned char)value);
}

void xwrite(int fd, void *buffer, size_t length) {
  unsigned char *cursor = buffer;
  while (length) {
    ssize_t written = write(fd, cursor, length);
    if (written <= 0) return;
    cursor += written;
    length -= (size_t)written;
  }
}

void loopfiles(char **paths, void (*callback)(int fd, char *name)) {
  if (!paths || !*paths) {
    callback(0, "-");
    return;
  }

  for (; *paths; ++paths) {
    int fd = !strcmp(*paths, "-") ? 0 : open(*paths, O_RDONLY);
    if (fd < 0) {
      perror_msg_raw(*paths);
      continue;
    }
    callback(fd, *paths);
    if (fd) close(fd);
  }
}

void cat_main(void);

int main(int argc, char **argv) {
  if (argc < 1 || !argv || !argv[0]) return 2;
  toys.optargs = argv + 1;
  cat_main();
  return fflush(stdout) == 0 ? 0 : 3;
}
