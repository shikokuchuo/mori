# unlink_shared() — removal by name is supported on all POSIX platforms;
# reaping (no argument) enumerates /dev/shm and is therefore Linux-only.

skip_on_os("windows")

linux_only <- function() {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("reaping requires enumerable /dev/shm (Linux only)")
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
  linux_only()
  x <- share(rnorm(100))
  nm <- shared_name(x)

  unlink_shared()
  expect_silent(y <- map_shared(nm)) # region of a live process survives reaping
  expect_equal(sum(y), sum(x))
})

test_that("unlink_shared() (reap) returns NULL when nothing is orphaned", {
  linux_only()
  unlink_shared()              # clear any pre-existing orphans
  expect_null(unlink_shared()) # a second reap finds nothing to remove
})

test_that("unlink_shared() (reap) returns NULL on macOS", {
  if (Sys.info()[["sysname"]] != "Darwin")
    skip("macOS-specific: SHM namespace is not enumerable for reaping")

  expect_null(unlink_shared())
})

test_that("unlink_shared() (reap) removes a dead process's orphan", {
  linux_only()
  skip_if_not_installed("parallel")

  # Run a child to exit so its PID is dead, then fabricate an orphan named for
  # that PID. The reaper classifies purely by the PID in the name, so this
  # exercises the dead-PID branch deterministically.
  p <- parallel::mcparallel(Sys.getpid())
  dead_pid <- parallel::mccollect(p)[[1]]

  orphan <- sprintf("/dev/shm/mori_%x_0", dead_pid)
  shm_name <- sprintf("/mori_%x_0", dead_pid)
  file.create(orphan)
  defer(unlink(orphan))

  reaped <- unlink_shared()
  expect_true(shm_name %in% reaped)
  expect_false(file.exists(orphan))
})

test_that("unlink_shared() (reap) keeps a live process's region", {
  linux_only()
  # A region named for the current (live) process must never be reaped.
  live <- sprintf("/dev/shm/mori_%x_deadbeef", Sys.getpid())
  shm_name <- sprintf("/mori_%x_deadbeef", Sys.getpid())
  file.create(live)
  defer(unlink(live))

  reaped <- unlink_shared()
  expect_false(shm_name %in% reaped)
  expect_true(file.exists(live))
})
