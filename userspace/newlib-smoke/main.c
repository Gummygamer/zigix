#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

void _exit(int status);

int main(void) {
  char *buffer = malloc(128);
  if (!buffer) return 2;

  int length = snprintf(buffer, 128, "newlib:%s:%d\n", "malloc", 64);
  if (length != 17 || strcmp(buffer, "newlib:malloc:64\n")) return 3;
  if (write(1, buffer, (size_t)length) != length) return 4;

  static const char marker[] = "[ZIGIX:TEST:PASS:newlib_c_runtime]\n";
  if (write(1, marker, sizeof(marker) - 1) != sizeof(marker) - 1) return 5;

  free(buffer);
  return 0;
}

void _start(void) {
  _exit(main());
}
