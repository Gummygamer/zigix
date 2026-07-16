#include <dirent.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static int contains_required_entries(DIR *dir) {
  int saw_init = 0;
  int saw_self = 0;
  struct dirent *entry;
  while ((entry = readdir(dir))) {
    if (!strcmp(entry->d_name, "init")) saw_init = 1;
    if (!strcmp(entry->d_name, "newlib-dirent")) saw_self = 1;
  }
  return saw_init && saw_self;
}

int main(void) {
  DIR *dir = opendir("/");
  if (!dir || dirfd(dir) < 3 || !contains_required_entries(dir)) return 2;
  rewinddir(dir);
  if (!readdir(dir) || closedir(dir)) return 3;

  int fd = open("/", O_RDONLY);
  if (fd < 3) return 4;
  dir = fdopendir(fd);
  if (!dir || !readdir(dir) || closedir(dir)) return 5;

  fd = open("/newlib-open-flags", O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 3 || write(fd, "not empty", 9) != 9 || close(fd)) return 6;
  fd = open("/newlib-open-flags", O_WRONLY | O_TRUNC);
  if (fd < 3 || close(fd)) return 7;
  fd = open("/newlib-open-flags", O_RDONLY);
  char byte;
  if (fd < 3 || read(fd, &byte, 1) != 0 || close(fd)) return 8;

  static const char marker[] = "[ZIGIX:TEST:PASS:newlib_dirent]\n";
  return write(1, marker, sizeof(marker) - 1) == sizeof(marker) - 1 ? 0 : 9;
}
