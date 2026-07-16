#ifndef ZIGIX_TOYBOX_ECHO_BOOTSTRAP_H
#define ZIGIX_TOYBOX_ECHO_BOOTSTRAP_H

/*
 * Minimal Toybox header overlay for the first externally sourced applet.
 * The upstream echo.c is compiled unchanged; later applets replace this
 * bootstrap surface with the regular Toybox headers plus portability patches.
 */

#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <wchar.h>

struct zigix_toy_context {
  char **optargs;
  uint64_t optflags;
};

extern struct zigix_toy_context toys;

#if defined(FOR_cat)
#define FLAG_e (1ULL << 0)
#define FLAG_t (1ULL << 1)
#define FLAG_v (1ULL << 2)
#define FLAG_u (1ULL << 3)
#else
#define FLAG_n (1ULL << 0)
#define FLAG_e (1ULL << 1)
#define FLAG_E (1ULL << 2)
#endif
#define FLAG(name) (!!(toys.optflags & FLAG_##name))

extern char toybuf[4096];

void xprintf(char *format, ...);
int unescape2(char **cursor, int echo);
void perror_msg_raw(char *message);
void xputc(char value);
void xwrite(int fd, void *buffer, size_t length);
void loopfiles(char **paths, void (*callback)(int fd, char *name));

#endif
