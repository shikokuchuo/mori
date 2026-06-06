#include <stdlib.h>
#include <stdio.h>
#include "mori.h"

/* Retry bound for mori_shm_create on a name collision. A process that reuses a
   PID after an unclean exit (common in containers) restarts the per-process
   name counter at 0 and can collide with an orphan left by the dead process;
   bump the counter and retry rather than fail. */
#define MORI_CREATE_RETRIES 256

// Platform-specific SHM implementations --------------------------------------

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define MORI_HINT_NOSPACE \
  "Free disk space backing the system paging file."

static int mori_err_classify(long code) {
  switch ((DWORD) code) {
  case ERROR_DISK_FULL:
    return MORI_ERR_NOSPACE;
  case ERROR_NOT_ENOUGH_MEMORY:
  case ERROR_OUTOFMEMORY:
  case ERROR_COMMITMENT_LIMIT:
  case ERROR_NO_SYSTEM_RESOURCES:
    return MORI_ERR_NOMEM;
  default:
    return MORI_ERR_OTHER;
  }
}

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

  DWORD hi = (DWORD) ((uint64_t) size >> 32);
  DWORD lo = (DWORD) (size & 0xFFFFFFFF);

  HANDLE h = NULL;
  for (int attempt = 0; attempt < MORI_CREATE_RETRIES; attempt++) {
    shm->name_len = (uint8_t) mori_shm_name(shm->name, sizeof(shm->name));
    h = CreateFileMappingA(
      INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, hi, lo, shm->name
    );
    if (h == NULL) return mori_err_classify((long) GetLastError());
    if (GetLastError() != ERROR_ALREADY_EXISTS) break;
    CloseHandle(h);                          /* opened a pre-existing region */
    h = NULL;
  }
  if (h == NULL) return MORI_ERR_NAME_COLLISION;

  void *addr = MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, size);
  if (addr == NULL) {
    long code = (long) GetLastError();       /* CloseHandle would clobber it */
    CloseHandle(h);
    return mori_err_classify(code);
  }

  shm->addr = addr;
  shm->size = size;
  shm->handle = h;
  return MORI_OK;
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

/* A Win32 file mapping lives only while a handle to it is open, so it cannot
   outlive its creator: there is no persistent name to remove and no orphan to
   reap. Both entry points are no-ops. */
int mori_shm_unlink_name(const char *name) {
  (void) name;
  return -1;
}

char **mori_shm_reap(int *n) {
  *n = 0;
  return NULL;
}

#else /* POSIX */

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

#ifndef MAP_POPULATE
#define MAP_POPULATE 0
#endif

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define MORI_HINT_NOSPACE \
  "Shared memory is provisioned at the OS or container level; in containers, " \
  "raise it at start (e.g. `docker run --shm-size=2g ...`)."

static int mori_err_classify(long code) {
  switch ((int) code) {
  case ENOSPC:
    return MORI_ERR_NOSPACE;
  case ENOMEM:
    return MORI_ERR_NOMEM;
  default:
    return MORI_ERR_OTHER;
  }
}

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

#ifdef __APPLE__

/* macOS has no enumerable SHM namespace (no /dev/shm; a dead creator's region is
   invisible to ipcs/lsof yet still holds memory), so to support reaping mori
   keeps its own registry: one empty marker file per region under a per-user dir,
   named like the region without the leading '/'. Created with the region and
   removed with it (mori_shm_os_unlink), so both leak together on an unclean death
   and reaping clears both. All marker ops are best-effort — failure forfeits only
   reapability, never the region. */

/* Per-user marker directory "<temp>/mori", created on first use and cached. Uses
   $TMPDIR first so it matches R's Sys.getenv("TMPDIR"); NULL if unavailable. */
static const char *mori_marker_dir(void) {
  static char dir[PATH_MAX];
  static int resolved = 0;            /* 0 = untried, 1 = valid, -1 = failed */
  if (resolved) return resolved > 0 ? dir : NULL;
  resolved = -1;

  char base[PATH_MAX];
  const char *tmp = getenv("TMPDIR");
  if (tmp != NULL && tmp[0] != '\0') {
    int bn = snprintf(base, sizeof(base), "%s", tmp);
    if (bn <= 0 || (size_t) bn >= sizeof(base)) return NULL;
  } else {
    size_t len = confstr(_CS_DARWIN_USER_TEMP_DIR, base, sizeof(base));
    if (len == 0 || len > sizeof(base)) {
      int bn = snprintf(base, sizeof(base), "%s", "/tmp");
      if (bn <= 0 || (size_t) bn >= sizeof(base)) return NULL;
    }
  }

  size_t bl = strlen(base);
  while (bl > 1 && base[bl - 1] == '/') base[--bl] = '\0';   /* avoid "//mori" */

  int n = snprintf(dir, sizeof(dir), "%s/mori", base);
  if (n <= 0 || (size_t) n >= sizeof(dir)) return NULL;
  if (mkdir(dir, 0700) != 0 && errno != EEXIST) return NULL;
  resolved = 1;
  return dir;
}

static int mori_marker_path(const char *shm_name, char *out, size_t outsize) {
  const char *dir = mori_marker_dir();
  if (dir == NULL) return -1;
  int n = snprintf(out, outsize, "%s/%s", dir, shm_name + 1);  /* skip '/' */
  return (n > 0 && (size_t) n < outsize) ? 0 : -1;
}

static void mori_marker_create(const char *shm_name) {
  char path[PATH_MAX];
  if (mori_marker_path(shm_name, path, sizeof(path)) != 0) return;
  int fd = open(path, O_CREAT | O_WRONLY, 0600);
  if (fd >= 0) close(fd);                  /* empty: the name carries the PID */
}

static void mori_marker_remove(const char *shm_name) {
  char path[PATH_MAX];
  if (mori_marker_path(shm_name, path, sizeof(path)) != 0) return;
  unlink(path);
}

#endif /* __APPLE__ */

static int mori_shm_os_unlink(const char *name) {
  int r = shm_unlink(name);
#ifdef __APPLE__
  mori_marker_remove(name);            /* drop the marker in lockstep */
#endif
  return r;
}

#endif

/* Public unlink-by-name for unlink_shared(). Returns 0 on success, -1 on
   failure (e.g. the region is absent). */
int mori_shm_unlink_name(const char *name) {
  return mori_shm_os_unlink(name);
}

#if defined(__linux__) || defined(__APPLE__)

#include <signal.h>
#include <dirent.h>

static int mori_pid_alive(pid_t pid) {
  if (pid <= 0) return 1;             /* never treat as reapable */
  if (kill(pid, 0) == 0) return 1;    /* exists and signalable */
  return errno == EPERM;              /* exists but owned by another user */
}

/* Reap orphans of dead creators by scanning a directory of mori region names —
   /dev/shm entries on Linux, mori's marker files on macOS — and unlinking the
   region behind each name whose creator PID (mori_<pid>_<counter>) is dead.
   Returns the removed names ("/mori_..." form) as a malloc'd array of *n malloc'd
   strings (caller frees each, then the array); NULL / *n == 0 if none. */
char **mori_shm_reap(int *n) {
  *n = 0;

#ifdef __linux__
  const char *scan_dir = "/dev/shm";          /* the kernel's own registry */
#else
  const char *scan_dir = mori_marker_dir();   /* mori's marker registry */
  if (scan_dir == NULL) return NULL;          /* marker dir unavailable */
#endif

  DIR *dir = opendir(scan_dir);
  if (dir == NULL) return NULL;

  const char *prefix = &MORI_PREFIX_LITERAL[1];  /* skip the leading '/' */
  const size_t prefix_len = strlen(prefix);

  char **list = NULL;
  size_t cap = 0, count = 0;

  struct dirent *ent;
  while ((ent = readdir(dir)) != NULL) {
    const char *fname = ent->d_name;
    if (strncmp(fname, prefix, prefix_len) != 0) continue;

    const char *pid_str = fname + prefix_len;
    char *end;
    long pid = strtol(pid_str, &end, 16);
    if (end == pid_str || *end != '_') continue;    /* not <pid>_<counter> */
    if (mori_pid_alive((pid_t) pid)) continue;       /* creator still alive */

    /* shm name = "/" + entry name */
    char shm_name[MORI_NAME_MAX];
    int wn = snprintf(shm_name, sizeof(shm_name), "/%s", fname);
    if (wn <= 0 || (size_t) wn >= sizeof(shm_name)) continue;

    /* Already gone: a race with another reap/unlink, so only the winner reports
       it. On macOS the stale marker is still dropped (mori_shm_os_unlink does so
       before returning). */
    if (mori_shm_os_unlink(shm_name) != 0) continue;

    if (count == cap) {
      size_t ncap = cap ? cap * 2 : 8;
      char **grown = realloc(list, ncap * sizeof(*list));
      if (grown == NULL) break;                       /* OOM: return so far */
      list = grown;
      cap = ncap;
    }
    size_t len = (size_t) wn + 1;              /* wn == strlen(shm_name) */
    char *copy = malloc(len);
    if (copy == NULL) break;
    memcpy(copy, shm_name, len);
    list[count++] = copy;
  }
  closedir(dir);

  *n = (int) count;
  return list;
}

#else /* other POSIX: the SHM namespace cannot be enumerated */

char **mori_shm_reap(int *n) {
  *n = 0;
  return NULL;
}

#endif /* __linux__ || __APPLE__ */

static size_t mori_shm_name(char *name, size_t size) {
  static unsigned int counter = 0;
  int n = snprintf(name, size, MORI_PREFIX_LITERAL "%x_%x",
                   (unsigned) getpid(), counter++);
  return (n > 0 && (size_t) n < size) ? (size_t) n : 0;
}

/* Tear down a partially-created region and return the failure category for
   `code`. Callers pass errno (or posix_fallocate's return) directly: it is
   read as an argument before close/unlink run, which would clobber errno. */
static int mori_create_fail(int fd, const char *name, int code) {
  close(fd);
  mori_shm_os_unlink(name);
  return mori_err_classify(code);
}

int mori_shm_create(mori_shm *shm, size_t size) {

  shm->addr = NULL;
  shm->size = 0;

  int fd = -1;
  for (int attempt = 0; attempt < MORI_CREATE_RETRIES; attempt++) {
    shm->name_len = (uint8_t) mori_shm_name(shm->name, sizeof(shm->name));
    fd = mori_shm_os_open(shm->name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd >= 0) break;
    if (errno != EEXIST)                    /* a real failure, not a collision */
      return mori_err_classify(errno);
  }
  if (fd < 0) return MORI_ERR_NAME_COLLISION;

  if (ftruncate(fd, (off_t) size) != 0)
    return mori_create_fail(fd, shm->name, errno);

#ifdef __linux__
  /* Reserve tmpfs pages now: ftruncate leaves the file sparse and tmpfs
     only allocates on write fault — SIGBUS if /dev/shm is full. (MAP_POPULATE
     alone won't help: read prefault on a hole resolves to the shared zero
     page without allocating.) posix_fallocate returns errno directly. */
  int ferr = posix_fallocate(fd, 0, (off_t) size);
  if (ferr != 0)
    return mori_create_fail(fd, shm->name, ferr);
#endif

  void *addr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                     MAP_SHARED | MAP_POPULATE, fd, 0);
  if (addr == MAP_FAILED)
    return mori_create_fail(fd, shm->name, errno);

  close(fd);

#ifdef MADV_HUGEPAGE
  if (size >= 2 * 1024 * 1024)
    madvise(addr, size, MADV_HUGEPAGE);
#elif defined(__APPLE__)
  madvise(addr, size, MADV_WILLNEED);
#endif

#ifdef __APPLE__
  mori_marker_create(shm->name);   /* register for reaping */
#endif

  shm->addr = addr;
  shm->size = size;
  return MORI_OK;
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

// Platform-independent error rendering ---------------------------------------

/* Map a failure category to a user-facing summary and an actionable
   platform-specific remediation hint ("" where the summary suffices). The
   caller composes these into its error message. */
void mori_err_describe(int category, const char **summary, const char **hint) {
  *hint = "";
  switch (category) {
  case MORI_ERR_NOSPACE:
    *summary = "out of space";
    *hint = MORI_HINT_NOSPACE;
    break;
  case MORI_ERR_NOMEM:
    *summary = "not enough memory";
    break;
  case MORI_ERR_NAME_COLLISION:
    *summary = "could not find a free region name after repeated retries";
    break;
  default:
    *summary = "an unexpected error occurred";
    break;
  }
}

// Platform-independent heap-allocating variants ------------------------------

/* Malloc a mori_shm and create the SHM region into it. On success returns
   MORI_OK and writes the new region into *out; on failure leaks nothing,
   sets *out to NULL, and returns the failure category. */
int mori_shm_create_heap(mori_shm **out, size_t size) {
  *out = NULL;
  mori_shm *shm = malloc(sizeof(mori_shm));
  if (shm == NULL) return MORI_ERR_NOMEM;
  int rc = mori_shm_create(shm, size);
  if (rc != MORI_OK) {
    free(shm);
    return rc;
  }
  *out = shm;
  return MORI_OK;
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
