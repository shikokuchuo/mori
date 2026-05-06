test_that("double vector write triggers materialization without mutating SHM", {
  x <- as.double(1:100)
  sx <- share(x)
  y <- map_shared(shared_name(sx))
  original <- y[1]

  y2 <- y
  y2[1] <- 999
  expect_equal(y2[1], 999)

  z <- map_shared(shared_name(sx))
  expect_equal(z[1], original)
})

test_that("string vector write triggers materialization without mutating SHM", {
  x <- c("original", "data")
  sx <- share(x)
  y <- map_shared(shared_name(sx))
  y2 <- y
  y2[1] <- "modified"
  expect_identical(y2[1], "modified")

  z <- map_shared(shared_name(sx))
  expect_identical(z[1], "original")
})

test_that("sum on materialized vector uses the private copy", {
  x <- share(as.double(1:100))
  x[1] <- 999
  expect_equal(sum(x), 999 + sum(2:100))
})

test_that("attributes survive COW materialization on atomic ALTREP", {
  # Attributes live on the ALTREP wrapper, not on data2 — verify the
  # wrapper-side attrs remain visible after a write triggers materialization.
  x <- share(c(a = 1, b = 2, c = 3))
  x[1] <- 99
  expect_identical(names(x), c("a", "b", "c"))

  m <- share(matrix(as.double(1:12), nrow = 3))
  m[1, 1] <- 999
  expect_identical(dim(m), c(3L, 4L))

  f <- share(factor(c("a", "b", "c", "a")))
  f[1] <- "b"
  expect_s3_class(f, "factor")
  expect_identical(levels(f), c("a", "b", "c"))
})

test_that("attributes survive serialize round-trip after COW", {
  x <- share(c(a = 1, b = 2, c = 3))
  x[1] <- 99
  y <- unserialize(serialize(x, NULL))
  expect_identical(names(y), c("a", "b", "c"))
  expect_equal(unname(y), c(99, 2, 3))
})

test_that("COW on integer vector preserves SHM", {
  x <- share(1:10L)
  nm <- shared_name(x)
  x[1] <- 99L
  expect_equal(x[1], 99L)
  y <- map_shared(nm)
  expect_identical(y[1], 1L)
})

test_that("COW on logical vector preserves SHM", {
  x <- share(c(TRUE, FALSE, TRUE, NA))
  nm <- shared_name(x)
  x[1] <- FALSE
  expect_false(x[1])
  y <- map_shared(nm)
  expect_true(y[1])
})

test_that("COW on raw vector preserves SHM", {
  x <- share(as.raw(0:9))
  nm <- shared_name(x)
  x[1] <- as.raw(255)
  expect_identical(x[1], as.raw(255))
  y <- map_shared(nm)
  expect_identical(y[1], as.raw(0))
})

test_that("COW on complex vector preserves SHM", {
  x <- share(complex(3, real = 1:3, imaginary = 4:6))
  nm <- shared_name(x)
  x[1] <- complex(1, real = 99, imaginary = 99)
  expect_equal(Re(x[1]), 99)
  expect_equal(Im(x[1]), 99)
  y <- map_shared(nm)
  expect_equal(Re(y[1]), 1)
})
