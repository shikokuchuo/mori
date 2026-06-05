# Corruption guards: hand map_shared() regions that carry a valid mori name but
# malformed contents, and assert it errors rather than reading garbage. The
# validation contract is that a well-formed identifier which fails to map errors
# (a malformed identifier returns NULL silently). Like test-create.R, these
# craft regions as files, so they are deterministic only on Linux /dev/shm
# (macOS uses kernel-backed shm_open with no file-visible namespace).

# Little-endian field encoders matching the on-disk region layout.
i32 <- function(x) writeBin(as.integer(x), raw(), size = 4L, endian = "little")
i64 <- function(x) {
  x <- as.double(x)
  out <- raw(8L)
  for (k in seq_len(8L)) {
    out[k] <- as.raw(x %% 256)
    x <- x %/% 256
  }
  out
}

MORL <- strtoi("4d4f524c", 16L)  # "MORL" magic, little-endian
REALSXP <- 14L
VECSXP <- 19L

# MORL header (24 bytes) + 32-byte directory entries (see SHM Region Layouts).
morl_header <- function(n, attrs_offset = 0, attrs_size = 0)
  c(i32(MORL), i32(n), i64(attrs_offset), i64(attrs_size))
morl_entry <- function(data_offset, data_size, sexptype, attrs_size = 0, length = 0)
  c(i64(data_offset), i64(data_size), i32(sexptype), i32(attrs_size), i64(length))

# Write `bytes` to a fresh /dev/shm region with a well-formed mori name, arrange
# for its removal when the calling test exits, and return the identifier. The
# "f"-prefixed counter keeps these names clear of any real share() allocations.
corrupt_counter <- local({
  i <- 0L
  function() {
    i <<- i + 1L
    i
  }
})
write_corrupt <- function(bytes, envir = parent.frame()) {
  name <- sprintf("/mori_%x_f%07x", Sys.getpid(), corrupt_counter())
  writeBin(bytes, file.path("/dev/shm", sub("^/", "", name)))
  defer(unlink(file.path("/dev/shm", sub("^/", "", name))), envir = envir)
  name
}

test_that("map_shared() errors on an unknown magic number", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  name <- write_corrupt(c(i32(0L), raw(60L)))  # 64-byte region, magic = 0
  expect_error(map_shared(name), "invalid or corrupted")
})

test_that("map_shared() errors on a truncated MORL header", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  name <- write_corrupt(c(i32(MORL), raw(4L)))  # magic present, header < 24 bytes
  expect_error(map_shared(name), "invalid nested list region")
})

test_that("map_shared() errors on an out-of-range element count", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  name <- write_corrupt(morl_header(n = 1000L))  # 24-byte region claims 1000 elements
  expect_error(map_shared(name), "invalid nested list region")
})

test_that("element access errors when a directory offset is out of bounds", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  name <- write_corrupt(c(
    morl_header(n = 1L),
    morl_entry(data_offset = 2^40, data_size = 8, sexptype = REALSXP, length = 1)
  ))
  expect_error(map_shared(name)[[1]], "invalid element data")
})

test_that("element access errors when attrs exceed the element data", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  name <- write_corrupt(c(
    morl_header(n = 1L),
    morl_entry(data_offset = 24, data_size = 8, sexptype = REALSXP,
               attrs_size = 16, length = 1)
  ))
  expect_error(map_shared(name)[[1]], "invalid element data")
})

test_that("nested element access errors on a corrupt child region", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  # parent (n = 1) points element 0 at a 24-byte VECSXP child with bad magic
  name <- write_corrupt(c(
    morl_header(n = 1L),
    morl_entry(data_offset = 56, data_size = 24, sexptype = VECSXP),
    c(i32(0L), raw(20L))
  ))
  expect_error(map_shared(name)[[1]], "invalid nested list region")
})

test_that("path-form map_shared() errors on an out-of-bounds intermediate", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  name <- write_corrupt(c(
    morl_header(n = 1L),
    morl_entry(data_offset = 2^40, data_size = 8, sexptype = VECSXP)
  ))
  expect_error(map_shared(paste0(name, "[1,1]")), "invalid nested region")
})
