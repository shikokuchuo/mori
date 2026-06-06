# unlink_shared() — removal by name is supported on all POSIX platforms;
# reaping (no argument) enumerates /dev/shm on Linux and mori's own per-user
# marker directory (<TMPDIR>/mori) on macOS. Windows is skipped at file level.

skip_on_os("windows")

# Fabricate the on-disk record that reap scans for, for a region named after
# `pid`, and return both the record path and the "/mori_..." shm name. On Linux
# that record is a file in /dev/shm; on macOS it is a marker file in mori's
# registry directory, which mirrors the C resolution exactly since both read the
# same TMPDIR. Reaping classifies purely by the PID in the name.
fabricate_orphan_record <- function(pid, counter = "0") {
  name <- sprintf("mori_%x_%s", pid, counter)
  shm_name <- paste0("/", name)
  if (Sys.info()[["sysname"]] == "Linux") {
    record <- file.path("/dev/shm", name)
  } else {                                            # Darwin
    tmp <- Sys.getenv("TMPDIR")
    if (!nzchar(tmp)) skip("TMPDIR unset; cannot locate mori marker directory")
    dir <- file.path(sub("/+$", "", tmp), "mori")
    dir.create(dir, showWarnings = FALSE, mode = "0700")
    record <- file.path(dir, name)
  }
  list(record = record, shm_name = shm_name)
}

test_that("unlink_shared(name) removes a region", {
  x <- share(rnorm(100))
  nm <- shared_name(x)
  rm(x)

  expect_identical(unlink_shared(nm), nm)
  expect_error(map_shared(nm), "not found")
})

test_that("unlink_shared() returns invisibly", {
  x <- share(1:10)
  nm <- shared_name(x)
  rm(x)
  expect_invisible(unlink_shared(nm))
})

test_that("unlink_shared(name) accepts a sub-object path and removes the region", {
  x <- share(list(a = 1:10, b = letters))
  sub_nm <- shared_name(x$a)
  region <- sub("\\[.*$", "", sub_nm)
  rm(x)

  expect_match(sub_nm, "\\[", fixed = FALSE)
  expect_identical(unlink_shared(sub_nm), region)
  expect_error(map_shared(region), "not found")
})

test_that("unlink_shared() ignores names that are not mori identifiers", {
  expect_null(unlink_shared("not_a_mori_name"))
  expect_null(unlink_shared(c("/etc/passwd", "garbage")))
})

test_that("unlink_shared() is vectorised and skips NA", {
  x <- share(1:10)
  y <- share(letters)
  nx <- shared_name(x)
  ny <- shared_name(y)
  rm(x, y)

  removed <- unlink_shared(c(nx, NA_character_, ny))
  expect_setequal(removed, c(nx, ny))
})

test_that("unlinking an already-removed region returns NULL", {
  x <- share(1:10)
  nm <- shared_name(x)
  rm(x)
  expect_identical(unlink_shared(nm), nm)
  expect_null(unlink_shared(nm))
})

test_that("unlink_shared() rejects non-character, non-NULL input", {
  expect_error(unlink_shared(123), "character vector or NULL")
})

test_that("unlink_shared() (reap) leaves live regions untouched", {
  x <- share(rnorm(100))
  nm <- shared_name(x)

  unlink_shared()
  expect_silent(y <- map_shared(nm)) # region of a live process survives reaping
  expect_equal(sum(y), sum(x))
})

test_that("unlink_shared() (reap) returns NULL when nothing is orphaned", {
  unlink_shared()              # clear any pre-existing orphans
  expect_null(unlink_shared()) # a second reap finds nothing to remove
})

test_that("unlink_shared() (reap) removes a dead process's orphan", {
  # Spawn a short-lived shell, capture its PID, and let R reap it (system()
  # waits before returning) so the PID is dead. Fabricate an orphan record
  # named for that PID; the reaper classifies purely by the PID in the name, so
  # this exercises the dead-PID branch deterministically.
  dead_pid <- as.integer(system("echo $$", intern = TRUE))

  orphan <- fabricate_orphan_record(dead_pid)
  file.create(orphan$record)
  defer(unlink(orphan$record))

  reaped <- unlink_shared()

  # The record is cleared on every platform. On Linux the /dev/shm file is a
  # real region, so its name is also reported as removed; on macOS the record is
  # a marker with no backing region, so shm_unlink finds nothing to reclaim and
  # the name is not reported (it is reported only when a region was reclaimed).
  expect_false(file.exists(orphan$record))
  if (Sys.info()[["sysname"]] == "Linux")
    expect_true(orphan$shm_name %in% reaped)
  else
    expect_false(orphan$shm_name %in% reaped)
})

test_that("unlink_shared() (reap) keeps a live process's region", {
  # A region named for the current (live) process must never be reaped.
  live <- fabricate_orphan_record(Sys.getpid(), counter = "deadbeef")
  file.create(live$record)
  defer(unlink(live$record))

  reaped <- unlink_shared()
  expect_false(live$shm_name %in% reaped)
  expect_true(file.exists(live$record))
})
