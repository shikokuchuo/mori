#include <stdlib.h>
#include <stdio.h>
#include "mori.h"

// Platform-specific SHM implementations --------------------------------------

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static size_t mori_shm_name(char *name, size_t size) {
  static unsigned int counter = 0;
  int n = snprintf(name, size, MORI_PREFIX_LITERAL "%lx_%x",
                   (unsigned long) GetCurrentProcessId(), counter++);
  return (n > 0 && (size_t) n < size) ? (size_t) n : 0;
}

int mori_shm_create(mori_shm *shm, size_t size) {

  shm->addr = NULL;
  shm->size = 0;
  shm->handle = NULL;
  shm->name_len = (uint8_t) mori_shm_name(shm->name, sizeof(shm->name));

  DWORD hi = (DWORD) ((uint64_t) size >> 32);
  DWORD lo = (DWORD) (size & 0xFFFFFFFF);

  HANDLE h = CreateFileMappingA(
    INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, hi, lo, shm->name
  );
  if (h == NULL) return -1;

  void *addr = MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, size);
  if (addr == NULL) {
    CloseHandle(h);
    return -1;
  }

  shm->addr = addr;
  shm->size = size;
  shm->handle = h;
  return 0;
}

int mori_shm_open(mori_shm *shm, const char *name) {

  shm->addr = NULL;
  shm->size = 0;
  shm->handle = NULL;
  size_t nl = strlen(name);
  if (nl >= sizeof(shm->name)) nl = sizeof(shm->name) - 1;
  memcpy(shm->name, name, nl);
  shm->name[nl] = '\0';
  shm->name_len = (uint8_t) nl;

  HANDLE h = OpenFileMappingA(FILE_MAP_READ, FALSE, name);
  if (h == NULL) return -1;

  void *addr = MapViewOfFile(h, FILE_MAP_READ, 0, 0, 0);
  if (addr == NULL) {
    CloseHandle(h);
    return -1;
  }

  MEMORY_BASIC_INFORMATION mbi;
  VirtualQuery(addr, &mbi, sizeof(mbi));

  shm->addr = addr;
  shm->size = mbi.RegionSize;
  shm->handle = h;
  return 0;
}

void mori_shm_close(mori_shm *shm, int unlink) {
  (void) unlink;
  if (shm->addr != NULL) UnmapViewOfFile(shm->addr);
  if (shm->handle != NULL) CloseHandle(shm->handle);
  shm->addr = NULL;
  shm->handle = NULL;
}

#else /* POSIX */

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#ifndef MAP_POPULATE
#define MAP_POPULATE 0
#endif

/* Linux: go through /dev/shm directly to avoid the -lrt link dependency
   that shm_open/shm_unlink would introduce. macOS has them in libc. */

#ifdef __linux__

static int mori_shm_os_open(const char *name, int flags, mode_t mode) {
  char path[64];
  snprintf(path, sizeof(path), "/dev/shm%s", name);
  return open(path, flags, mode);
}

static int mori_shm_os_unlink(const char *name) {
  char path[64];
  snprintf(path, sizeof(path), "/dev/shm%s", name);
  return unlink(path);
}

#else /* macOS / other POSIX */

static int mori_shm_os_open(const char *name, int flags, mode_t mode) {
  return shm_open(name, flags, mode);
}

static int mori_shm_os_unlink(const char *name) {
  return shm_unlink(name);
}

#endif

static size_t mori_shm_name(char *name, size_t size) {
  static unsigned int counter = 0;
  int n = snprintf(name, size, MORI_PREFIX_LITERAL "%x_%x",
                   (unsigned) getpid(), counter++);
  return (n > 0 && (size_t) n < size) ? (size_t) n : 0;
}

int mori_shm_create(mori_shm *shm, size_t size) {

  shm->addr = NULL;
  shm->size = 0;
  shm->name_len = (uint8_t) mori_shm_name(shm->name, sizeof(shm->name));

  int fd = mori_shm_os_open(shm->name, O_CREAT | O_EXCL | O_RDWR, 0600);
  if (fd < 0) return -1;

  if (ftruncate(fd, (off_t) size) != 0) {
    close(fd);
    mori_shm_os_unlink(shm->name);
    return -1;
  }

#ifdef __linux__
  /* Reserve tmpfs pages now: ftruncate leaves the file sparse and tmpfs
     only allocates on write fault — SIGBUS if /dev/shm is full. (MAP_POPULATE
     alone won't help: read prefault on a hole resolves to the shared zero
     page without allocating.) posix_fallocate returns errno directly. */
  int err = posix_fallocate(fd, 0, (off_t) size);
  if (err != 0) {
    close(fd);
    mori_shm_os_unlink(shm->name);
    return err;
  }
#endif

  void *addr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_POPULATE, fd, 0);
  if (addr == MAP_FAILED) {
    close(fd);
    mori_shm_os_unlink(shm->name);
    return -1;
  }

  close(fd);

#ifdef MADV_HUGEPAGE
  if (size >= 2 * 1024 * 1024)
    madvise(addr, size, MADV_HUGEPAGE);
#elif defined(__APPLE__)
  madvise(addr, size, MADV_WILLNEED);
#endif

  shm->addr = addr;
  shm->size = size;
  return 0;
}

int mori_shm_open(mori_shm *shm, const char *name) {

  shm->addr = NULL;
  shm->size = 0;
  size_t nl = strlen(name);
  if (nl >= sizeof(shm->name)) nl = sizeof(shm->name) - 1;
  memcpy(shm->name, name, nl);
  shm->name[nl] = '\0';
  shm->name_len = (uint8_t) nl;

  int fd = mori_shm_os_open(name, O_RDONLY, 0);
  if (fd < 0) return -1;

  struct stat st;
  if (fstat(fd, &st) != 0) {
    close(fd);
    return -1;
  }
  size_t size = (size_t) st.st_size;

  /* No MAP_POPULATE on the consumer: pages already exist (host wrote them),
     so populating only installs PTEs eagerly across the whole region — which
     defeats lazy access (a worker reading 1 of 10 list elements would prefault
     the unread 9). Pages fault in on first touch instead. */
  void *addr = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
  if (addr == MAP_FAILED) {
    close(fd);
    return -1;
  }

  close(fd);

#ifdef MADV_HUGEPAGE
  if (size >= 2 * 1024 * 1024)
    madvise(addr, size, MADV_HUGEPAGE);
#elif defined(__APPLE__)
  madvise(addr, size, MADV_WILLNEED);
#endif

  shm->addr = addr;
  shm->size = size;
  return 0;
}

void mori_shm_close(mori_shm *shm, int unlink) {
  if (shm->addr != NULL) munmap(shm->addr, shm->size);
  if (unlink) mori_shm_os_unlink(shm->name);
  shm->addr = NULL;
}

#endif /* _WIN32 */

// Platform-independent heap-allocating variants ------------------------------

/* Malloc a mori_shm and create the SHM region into it. On success returns
   0 and writes the new region into *out; on failure leaks nothing, sets
   *out to NULL, and returns the create status: a positive errno from
   posix_fallocate (e.g. ENOSPC), or -1 for other failures. */
int mori_shm_create_heap(mori_shm **out, size_t size) {
  *out = NULL;
  mori_shm *shm = malloc(sizeof(mori_shm));
  if (shm == NULL) return -1;
  int rc = mori_shm_create(shm, size);
  if (rc != 0) {
    free(shm);
    return rc;
  }
  *out = shm;
  return 0;
}

/* Malloc a mori_shm and open an existing SHM region into it. */
mori_shm *mori_shm_open_heap(const char *name) {
  mori_shm *shm = malloc(sizeof(mori_shm));
  if (shm == NULL) return NULL;
  if (mori_shm_open(shm, name) != 0) {
    free(shm);
    return NULL;
  }
  return shm;
}

// Platform-independent finalizers --------------------------------------------

/* Mapping finalizer (both sides): releases this side's mapping only.
   The name (POSIX) / creator handle (Windows) is released independently
   by mori_host_finalizer on the chained host_tag extptr — so a consumer
   keeps reading after the host is GC'd. */
void mori_shm_finalizer(SEXP ptr) {
  mori_shm *shm = (mori_shm *) R_ExternalPtrAddr(ptr);
  if (shm != NULL) {
    mori_shm_close(shm, 0);
    free(shm);
    R_ClearExternalPtr(ptr);
  }
}

/* Host-side finalizer: releases the SHM name/handle */
void mori_host_finalizer(SEXP ptr) {
  mori_shm *shm = (mori_shm *) R_ExternalPtrAddr(ptr);
  if (shm != NULL) {
#ifdef _WIN32
    if (shm->handle != NULL) CloseHandle(shm->handle);
#else
    if (shm->name[0] != '\0') mori_shm_os_unlink(shm->name);
#endif
    free(shm);
    R_ClearExternalPtr(ptr);
  }
}
