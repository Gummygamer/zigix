/* Bootstrap runtime for upstream Toybox echo.c. */

#include "toys.h"

#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

struct zigix_toy_context toys;

void xprintf(char *format, ...) {
  va_list args;
  va_start(args, format);
  vprintf(format, args);
  va_end(args);
}

static int string_index(const char *text, char needle) {
  const char *found = strchr(text, needle);
  return found ? (int)(found - text) : -1;
}

/* Derived from Toybox lib/lib.c for the echo applet's -e behavior. */
int unescape2(char **cursor, int echo) {
  int value = *((*cursor)++), offset;

  if (value != '\\' || !**cursor) return value;
  if (**cursor == 'c') return 31 & *(++*cursor);

  const char *formats[] = {&"0%3o%n"[!echo], "x%2x%n", "u%4x%n", "U%6x%n"};
  for (int index = 0; index < 4; ++index) {
    if (sscanf(*cursor, formats[index], &value, &offset) > 0) {
      *cursor += offset;
      return value;
    }
  }

  int index = string_index("\\abeEfnrtv'\"?0", **cursor);
  if (index < 0) return '\\';
  ++*cursor;
  return "\\\a\b\e\e\f\n\r\t\v'\"?"[index];
}

void echo_main(void);

int main(int argc, char **argv) {
  if (argc < 1 || !argv || !argv[0]) return 2;

  int index = 1;
  for (; index < argc && argv[index] && argv[index][0] == '-'; ++index) {
    const char *option = argv[index] + 1;
    if (!*option) break;
    if (!strcmp(option, "-")) {
      ++index;
      break;
    }
    for (; *option; ++option) {
      if (*option == 'n') toys.optflags |= FLAG_n;
      else if (*option == 'e') toys.optflags = (toys.optflags | FLAG_e) & ~FLAG_E;
      else if (*option == 'E') toys.optflags = (toys.optflags | FLAG_E) & ~FLAG_e;
      else return 2;
    }
  }

  toys.optargs = argv + index;
  echo_main();
  return fflush(stdout) == 0 ? 0 : 3;
}
