#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>
#include <sys/times.h>
#include <sys/time.h>
#include <sys/types.h>

static long syscall0(long number) {
  __asm__ volatile("int $0x80" : "+a"(number) : : "rcx", "r11", "memory");
  return number;
}

static long syscall1(long number, long arg0) {
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0)
                   : "rcx", "r11", "memory");
  return number;
}

static long syscall3(long number, long arg0, long arg1, long arg2) {
  __asm__ volatile("int $0x80"
                   : "+a"(number)
                   : "D"(arg0), "S"(arg1), "d"(arg2)
                   : "rcx", "r11", "memory");
  return number;
}

static long result(long value) {
  if (value < 0) {
    errno = (int)-value;
    return -1;
  }
  return value;
}

ssize_t _read(int fd, void *buffer, size_t length) {
  return result(syscall3(0, fd, (long)buffer, length));
}

ssize_t _write(int fd, const void *buffer, size_t length) {
  return result(syscall3(1, fd, (long)buffer, length));
}

ssize_t read(int fd, void *buffer, size_t length) {
  return _read(fd, buffer, length);
}

ssize_t write(int fd, const void *buffer, size_t length) {
  return _write(fd, buffer, length);
}

int _close(int fd) {
  return (int)result(syscall1(3, fd));
}

int close(int fd) {
  return _close(fd);
}

off_t _lseek(int fd, off_t offset, int whence) {
  return result(syscall3(8, fd, offset, whence));
}

off_t lseek(int fd, off_t offset, int whence) {
  return _lseek(fd, offset, whence);
}

int _getpid(void) {
  return (int)result(syscall0(39));
}

int _kill(int pid, int signal) {
  (void)pid;
  (void)signal;
  errno = ENOSYS;
  return -1;
}

int _gettimeofday(struct timeval *tv, void *tz) {
  (void)tv;
  (void)tz;
  errno = ENOSYS;
  return -1;
}

clock_t _times(struct tms *times) {
  (void)times;
  errno = ENOSYS;
  return (clock_t)-1;
}

int _isatty(int fd) {
  if (fd >= 0 && fd <= 2) return 1;
  errno = ENOTTY;
  return 0;
}

int isatty(int fd) {
  return _isatty(fd);
}

int _fstat(int fd, struct stat *out) {
  if (!out) {
    errno = EFAULT;
    return -1;
  }

  unsigned char *bytes = (unsigned char *)out;
  for (size_t i = 0; i < sizeof(*out); ++i) bytes[i] = 0;
  if (fd >= 0 && fd <= 2) {
    out->st_mode = S_IFCHR;
    return 0;
  }

  errno = ENOSYS;
  return -1;
}

int fstat(int fd, struct stat *out) {
  return _fstat(fd, out);
}

static unsigned char heap[64 * 1024] __attribute__((aligned(16)));
static size_t heap_used;

void *_sbrk(ptrdiff_t increment) {
  if (increment < 0 || (size_t)increment > sizeof(heap) - heap_used) {
    errno = ENOMEM;
    return (void *)-1;
  }

  void *previous = heap + heap_used;
  heap_used += (size_t)increment;
  return previous;
}

void *sbrk(ptrdiff_t increment) {
  return _sbrk(increment);
}

void _exit(int status) {
  syscall1(231, status < 0 ? 1 : status);
  for (;;) __asm__ volatile("pause");
}
