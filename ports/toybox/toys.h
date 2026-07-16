#ifndef ZIGIX_TOYBOX_ECHO_BOOTSTRAP_H
#define ZIGIX_TOYBOX_ECHO_BOOTSTRAP_H

/*
 * Minimal Toybox header overlay for the first externally sourced applets.
 * Upstream applet sources are compiled unchanged; later slices replace this
 * bootstrap surface with the regular Toybox headers plus portability patches.
 */

#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <wchar.h>

#if defined(FOR_taskset) || defined(FOR_id)
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#endif

#if defined(FOR_taskset)
#include <dirent.h>
#define __NR_sched_setaffinity 203
#define __NR_sched_getaffinity 204
#endif

struct zigix_toy_context {
  char **optargs;
  uint64_t optflags;
  int optc;
};

extern struct zigix_toy_context toys;

#if defined(FOR_id)
#define FLAG_n (1ULL << 0)
#define FLAG_G (1ULL << 1)
#define FLAG_g (1ULL << 2)
#define FLAG_r (1ULL << 3)
#define FLAG_u (1ULL << 4)
#define FLAG_Z (1ULL << 5)
#define CFG_TOYBOX_LSM_NONE 1
#define CFG_TOYBOX_FREE 0
struct zigix_id_globals { int is_groups; };
extern struct zigix_id_globals TT;
#define GLOBALS(...)
#elif defined(FOR_taskset)
#define FLAG_p (1ULL << 0)
#define FLAG_a (1ULL << 1)
#define FLAG_c (1ULL << 2)
#elif defined(FOR_cat)
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

#if defined(FOR_taskset)
struct dirtree {
  struct dirtree *parent;
  char *name;
};
#define DIRTREE_RECURSE 1
#define DIRTREE_SHUTUP 2
#define DIRTREE_PROC 4
long syscall(long number, ...);
void perror_exit(char *format, ...);
void error_exit(char *format, ...);
void xexec(char **argv);
struct dirtree *dirtree_read(char *path, int (*callback)(struct dirtree *));
int smemcmp(char *one, char *two, unsigned long length);
#endif

#if defined(FOR_id)
#include <grp.h>
#include <pwd.h>
void xexit(void) __attribute__((noreturn));
struct passwd *xgetpwuid(uid_t uid);
struct passwd *bufgetpwuid(uid_t uid);
struct group *xgetgrgid(gid_t gid);
long atolx_range(char *text, long low, long high);
void error_exit(char *format, ...);
void perror_exit(char *format, ...);
int getgrouplist(const char *user, gid_t group, gid_t *groups, int *count);
int lsm_enabled(void);
char *lsm_context(void);
char *lsm_name(void);
#endif

#endif
