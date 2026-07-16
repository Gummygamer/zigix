#ifndef ZIGIX_TOYBOX_ECHO_BOOTSTRAP_H
#define ZIGIX_TOYBOX_ECHO_BOOTSTRAP_H

/*
 * Minimal Toybox header overlay for the first externally sourced applet.
 * The upstream echo.c is compiled unchanged; later applets replace this
 * bootstrap surface with the regular Toybox headers plus portability patches.
 */

#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

struct zigix_toy_context {
  char **optargs;
  uint64_t optflags;
};

extern struct zigix_toy_context toys;

#define FLAG_n (1ULL << 0)
#define FLAG_e (1ULL << 1)
#define FLAG_E (1ULL << 2)
#define FLAG(name) (!!(toys.optflags & FLAG_##name))

void xprintf(char *format, ...);
int unescape2(char **cursor, int echo);

#endif
