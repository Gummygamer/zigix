/* Bootstrap runtime for upstream Toybox id.c's numeric id applet path. */

#define FOR_id
#include "toys.h"

#include <stdarg.h>

struct zigix_toy_context toys;
struct zigix_id_globals TT;
char toybuf[4096];

static char root_name[] = "root";
static struct passwd root_passwd = {
    .pw_name = root_name,
    .pw_uid = 0,
    .pw_gid = 0,
};
static char *root_members[] = {root_name, NULL};
static struct group root_group = {
    .gr_name = root_name,
    .gr_gid = 0,
    .gr_mem = root_members,
};

void xputc(char value) {
  putchar((unsigned char)value);
}

void xexit(void) {
  fflush(stdout);
  exit(0);
}

struct passwd *xgetpwuid(uid_t uid) {
  return uid == 0 ? &root_passwd : NULL;
}

struct passwd *bufgetpwuid(uid_t uid) {
  return xgetpwuid(uid);
}

struct passwd *getpwnam(const char *name) {
  return name && !strcmp(name, root_name) ? &root_passwd : NULL;
}

struct group *xgetgrgid(gid_t gid) {
  return gid == 0 ? &root_group : NULL;
}

struct group *getgrgid(gid_t gid) {
  return xgetgrgid(gid);
}

long atolx_range(char *text, long low, long high) {
  char *end;
  long value = strtol(text, &end, 10);
  if (*end || value < low || value > high) exit(2);
  return value;
}

static void fail(void) {
  exit(2);
}

void error_exit(char *format, ...) {
  (void)format;
  fail();
}

void perror_exit(char *format, ...) {
  (void)format;
  fail();
}

int getgroups(int count, gid_t groups[]) {
  (void)count;
  (void)groups;
  return 0;
}

int getgrouplist(const char *user, gid_t group, gid_t *groups, int *count) {
  (void)user;
  (void)group;
  (void)groups;
  (void)count;
  return 0;
}

int lsm_enabled(void) { return 0; }
char *lsm_context(void) { return NULL; }
char *lsm_name(void) { return "none"; }

void id_main(void);

int main(void) {
  toys.optflags = FLAG_u;
  id_main();
  return 0;
}
