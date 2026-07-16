#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct __zigix_dir_stream {
  int fd;
  size_t offset;
  size_t length;
  unsigned char buffer[512];
  struct dirent entry;
};

static long syscall3(long number, long arg0, long arg1, long arg2) {
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0), "S"(arg1), "d"(arg2)
                   : "rcx", "r11", "memory");
  return number;
}

static uint64_t load_u64(const unsigned char *source) {
  uint64_t value;
  memcpy(&value, source, sizeof(value));
  return value;
}

static uint16_t load_u16(const unsigned char *source) {
  uint16_t value;
  memcpy(&value, source, sizeof(value));
  return value;
}

DIR *fdopendir(int fd) {
  if (fd < 0) {
    errno = EBADF;
    return NULL;
  }
  DIR *stream = malloc(sizeof(*stream));
  if (!stream) return NULL;
  stream->fd = fd;
  stream->offset = 0;
  stream->length = 0;
  return stream;
}

DIR *opendir(const char *path) {
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  if (fd < 0) return NULL;
  DIR *stream = fdopendir(fd);
  if (!stream) close(fd);
  return stream;
}

struct dirent *readdir(DIR *stream) {
  if (!stream) {
    errno = EINVAL;
    return NULL;
  }
  for (;;) {
    if (stream->offset == stream->length) {
      long amount = syscall3(217, stream->fd, (long)stream->buffer,
                             sizeof(stream->buffer));
      if (amount < 0) {
        errno = (int)-amount;
        return NULL;
      }
      if (!amount) return NULL;
      stream->offset = 0;
      stream->length = (size_t)amount;
    }

    size_t available = stream->length - stream->offset;
    unsigned char *record = stream->buffer + stream->offset;
    if (available < 20) {
      errno = EIO;
      return NULL;
    }
    uint16_t record_length = load_u16(record + 16);
    if (record_length < 20 || record_length > available) {
      errno = EIO;
      return NULL;
    }

    size_t name_space = record_length - 19;
    size_t name_length = 0;
    while (name_length < name_space && record[19 + name_length]) ++name_length;
    if (name_length == name_space || name_length >= sizeof(stream->entry.d_name)) {
      errno = ENAMETOOLONG;
      return NULL;
    }

    stream->entry.d_ino = (ino_t)load_u64(record);
    stream->entry.d_off = (off_t)load_u64(record + 8);
    stream->entry.d_reclen = (unsigned short)sizeof(stream->entry);
    stream->entry.d_type = record[18];
    memcpy(stream->entry.d_name, record + 19, name_length);
    stream->entry.d_name[name_length] = '\0';
    stream->offset += record_length;
    return &stream->entry;
  }
}

int closedir(DIR *stream) {
  if (!stream) {
    errno = EINVAL;
    return -1;
  }
  int fd = stream->fd;
  free(stream);
  return close(fd);
}

void rewinddir(DIR *stream) {
  if (!stream) {
    errno = EINVAL;
    return;
  }
  if (lseek(stream->fd, 0, SEEK_SET) == 0) {
    stream->offset = 0;
    stream->length = 0;
  }
}

int dirfd(DIR *stream) {
  if (!stream) {
    errno = EINVAL;
    return -1;
  }
  return stream->fd;
}
