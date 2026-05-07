test_that("shared_name + map_shared round-trip", {
  x <- share(as.double(1:50))
  nm <- shared_name(x)
  expect_true(is.character(nm))
  expect_gt(nchar(nm), 0L)
  y <- map_shared(nm)
  expect_identical(x[], y[])
})

test_that("is_shared distinguishes shared and non-shared objects", {
  expect_true(is_shared(share(1:10)))
  expect_false(is_shared(1:10))

  df <- share(data.frame(a = 1:3))
  expect_true(is_shared(df))

  s <- share(letters)
  expect_true(is_shared(s))

  expect_false(is_shared(NULL))
  expect_false(is_shared("hello"))
  expect_false(is_shared(data.frame(a = 1)))
  expect_false(is_shared(list(1, 2)))
})

test_that("shared_name returns a non-empty string for shared objects", {
  df <- share(data.frame(a = 1:3))
  nm <- shared_name(df)
  expect_true(is.character(nm))
  expect_gt(nchar(nm), 0L)

  s <- share(letters)
  expect_true(is.character(shared_name(s)))
})

test_that("shared_name returns NULL for non-shared inputs", {
  expect_null(shared_name(1:10))
  expect_null(shared_name(NULL))
  expect_null(shared_name(list(a = 1)))
  expect_null(shared_name("a"))

  s <- share(letters)
  nm <- shared_name(s)
  expect_null(shared_name(nm))
})

test_that("map_shared returns NULL on malformed input", {
  expect_null(map_shared(""))
  expect_null(map_shared("junk"))
  expect_null(map_shared(NULL))
  expect_null(map_shared(NA_character_))
  expect_null(map_shared(character(0)))
  expect_null(map_shared(c("a", "b")))
  expect_null(map_shared(1L))
  expect_null(map_shared(list("a")))
})

test_that("map_shared composes with shared_name on non-shared input", {
  expect_null(map_shared(shared_name(1:10)))
})

test_that("well-formed name for absent region errors", {
  bogus <- if (.Platform$OS.type == "windows") {
    "Local\\mori_0_fffffff"
  } else {
    "/mori_0_fffffff"
  }
  expect_error(map_shared(bogus), "not found")
})

test_that("is_shared is TRUE across all shared ALTREP kinds (host-side)", {
  expect_true(is_shared(share(1:10)))
  expect_true(is_shared(share(letters)))
  expect_true(is_shared(share(list(a = 1, b = "x"))))

  x <- share(list(list(1)))
  expect_true(is_shared(x[[1]]))

  y <- share(list(list(a = 1:3)))
  expect_true(is_shared(y[[1]][["a"]]))

  z <- share(list(list(s = letters)))
  expect_true(is_shared(z[[1]][["s"]]))
})

test_that("is_shared is TRUE across all shared ALTREP kinds (consumer-side)", {
  a <- share(1:10)
  expect_true(is_shared(map_shared(shared_name(a))))

  s <- share(letters)
  expect_true(is_shared(map_shared(shared_name(s))))

  L <- share(list(a = 1, b = "x"))
  expect_true(is_shared(map_shared(shared_name(L))))

  x <- share(list(list(1)))
  xx <- map_shared(shared_name(x))
  expect_true(is_shared(xx[[1]]))

  y <- share(list(list(a = 1:3)))
  yy <- map_shared(shared_name(y))
  expect_true(is_shared(yy[[1]][["a"]]))

  z <- share(list(list(s = letters)))
  zz <- map_shared(shared_name(z))
  expect_true(is_shared(zz[[1]][["s"]]))
})

test_that("shared_name carries a bracketed path for sub-lists and elements", {
  x <- share(list(a = 1:5, sub = list(b = letters, c = 1:10)))
  nm <- shared_name(x)
  expect_gt(nchar(nm), 0L)

  expect_identical(shared_name(x[[1]]),             paste0(nm, "[1]"))
  expect_identical(shared_name(x[["sub"]]),         paste0(nm, "[2]"))
  expect_identical(shared_name(x[["sub"]][["b"]]),  paste0(nm, "[2,1]"))
  expect_identical(shared_name(x[["sub"]][["c"]]),  paste0(nm, "[2,2]"))

  y <- map_shared(nm)
  expect_identical(shared_name(y[["sub"]]),        paste0(nm, "[2]"))
  expect_identical(shared_name(y[["sub"]][["b"]]), paste0(nm, "[2,1]"))
})

test_that("map_shared(shared_name(sub)) yields the addressed sub-object", {
  x <- share(list(outer = list(a = 1:5, b = letters)))
  sub <- x[["outer"]]
  reopened <- map_shared(shared_name(sub))
  expect_identical(reopened[["a"]][], 1:5)
  expect_identical(reopened[["b"]][], letters)
})

test_that("shared_name round-trips for any shared input", {
  x <- share(list(a = 1:5, sub = list(b = letters, c = 1:10)))

  # `[]` on an atomic ALTREP triggers materialization with well-defined
  # semantics, but on an ALTLIST it's implementation-defined. Walk the
  # structure element-wise and only use `[]` at atomic leaves so the
  # round-trip check is unambiguous.
  same_shape <- function(a, b) {
    expect_identical(is.list(a), is.list(b))
    if (is.list(a)) {
      expect_identical(length(a), length(b))
      expect_identical(names(a), names(b))
      for (k in seq_along(a)) same_shape(a[[k]], b[[k]])
    } else {
      expect_identical(a[], b[])
    }
  }

  for (sub in list(x, x[["a"]], x[["sub"]], x[["sub"]][["b"]],
                   x[["sub"]][["c"]])) {
    same_shape(map_shared(shared_name(sub)), sub)
  }
})

test_that("OS name extractable from sub-object identifier", {
  x <- share(list(a = 1:5))
  os_name <- sub("\\[.*$", "", shared_name(x[[1]]))
  expect_identical(os_name, shared_name(x))
})

test_that("shared_name round-trips at depth", {
  x <- share(list(a = list(b = list(c = list(d = 1:5)))))
  leaf <- x[["a"]][["b"]][["c"]][["d"]]
  expect_match(shared_name(leaf), "\\[1,1,1,1\\]$")
  expect_identical(map_shared(shared_name(leaf))[], 1:5)
})

test_that("map_shared rejects inputs that fail the prefix grammar", {
  # All of these miss the prefix grammar; the path parser is unreachable.
  expect_null(map_shared("not_a_mori_name"))         # literal mismatch
  expect_null(map_shared("/mori_abc[1]"))            # missing _ separator
  expect_null(map_shared("/mori_abc"))               # missing _ separator
  expect_null(map_shared("/mori__abc"))              # empty first hex run
  expect_null(map_shared("/mori_abc_"))              # empty second hex run
  expect_null(map_shared("/mori_0_g"))               # non-hex in second run
  expect_null(map_shared("/mori_0-1"))               # wrong separator
  expect_null(map_shared("/mori_0_ABC"))             # uppercase in random part
  expect_null(map_shared("/mori_0/1"))               # slash terminates run
})

test_that("map_shared rejects valid prefix with malformed path", {
  good <- if (.Platform$OS.type == "windows") {
    "Local\\mori_0_fffffff"
  } else {
    "/mori_0_fffffff"
  }
  expect_null(map_shared(paste0(good, "[]")))           # empty bracket
  expect_null(map_shared(paste0(good, "[0]")))          # zero (1-based)
  expect_null(map_shared(paste0(good, "[-1]")))         # negative
  expect_null(map_shared(paste0(good, "[1,]")))         # trailing comma
  expect_null(map_shared(paste0(good, "[,1]")))         # leading comma
  expect_null(map_shared(paste0(good, "[1,,2]")))       # double comma
  expect_null(map_shared(paste0(good, "[a]")))          # non-digit
  expect_null(map_shared(paste0(good, "[01]")))         # leading zero
  expect_null(map_shared(paste0(good, "[2147483648]"))) # exceeds INT32_MAX
  expect_null(map_shared(paste0(good, "[1] ")))         # trailing space
  expect_null(map_shared(paste0(good, "[1]x")))         # trailing junk
  expect_null(map_shared(paste0(good, " [1]")))         # leading whitespace
  expect_null(map_shared(paste0(good, "[")))            # unclosed bracket
  expect_null(map_shared(paste0(good, "[1!]")))         # bad delimiter after digit
  expect_null(map_shared(paste0(good, "[1.5]")))        # non-int delimiter
  expect_null(map_shared(paste0(good, "[1?2]")))        # non-comma between toks
  # >64 indices: count exceeds MORI_MAX_PATH
  expect_null(map_shared(paste0(
    good, "[", paste(rep("1", 65), collapse = ","), "]"
  )))
})

test_that("map_shared errors on valid identifier with bad path", {
  x <- share(list(a = 1:5))
  nm <- shared_name(x)
  expect_error(map_shared(paste0(nm, "[99]")), "out of bounds")
})

test_that("map_shared errors when intermediate path index is OOB", {
  x <- share(list(a = 1:5, b = list(c = 1:5)))
  nm <- shared_name(x)
  expect_error(map_shared(paste0(nm, "[99,1]")), "out of bounds")
})

test_that("map_shared errors when path step is not a nested list", {
  x <- share(list(a = 1:5, b = list(c = 1:5)))
  nm <- shared_name(x)
  # Element 1 (a) is atomic — descending into it must error
  expect_error(map_shared(paste0(nm, "[1,1]")), "not a nested list")
  # Element 2 of b is also atomic — verify the same at depth
  expect_error(
    map_shared(paste0(nm, "[2,1,1]")), "not a nested list"
  )
})

test_that("path-form on missing region yields the same 'not found' error", {
  bogus <- if (.Platform$OS.type == "windows") {
    "Local\\mori_0_fffffff"
  } else {
    "/mori_0_fffffff"
  }
  expect_error(map_shared(bogus),                "not found")
  expect_error(map_shared(paste0(bogus, "[1]")), "not found")
})

test_that("share() is idempotent on already-shared objects", {
  x <- share(as.double(1:100))
  expect_identical(share(x), x)
  expect_identical(shared_name(share(x)), shared_name(x))

  s <- share(letters)
  expect_identical(share(s), s)
  expect_identical(shared_name(share(s)), shared_name(s))

  L <- share(list(a = 1:3, b = c("x", "y")))
  expect_identical(share(L), L)
  expect_identical(shared_name(share(L)), shared_name(L))

  y <- map_shared(shared_name(x))
  expect_identical(share(y), y)
  expect_identical(shared_name(share(y)), shared_name(y))

  root <- share(list(v = 1:10, sub = list(a = 1:5, s = letters)))
  sub <- root[[2L]]
  expect_identical(share(sub), sub)
  elt <- root[[1L]]
  expect_identical(share(elt), elt)
})

test_that("is_shared/shared_name preserved after COW materialization", {
  x <- share(as.double(1:10))
  nm <- shared_name(x)
  expect_gt(nchar(nm), 0L)
  x[1] <- 99
  expect_equal(x[1], 99)
  expect_true(is_shared(x))
  expect_identical(shared_name(x), nm)
})

test_that("shared_name returns NULL for nesting beyond MORI_MAX_PATH", {
  # Chain length > 64 forces mori_format_chain to overflow → NULL.
  x <- 1:5
  for (i in seq_len(70)) x <- list(x)
  sx <- share(x)
  deep <- sx
  for (i in seq_len(70)) deep <- deep[[1]]
  expect_true(is_shared(deep))
  expect_null(shared_name(deep))

  # Same for a string leaf and an intermediate sub-list at depth.
  xs <- letters
  for (i in seq_len(70)) xs <- list(xs)
  sxs <- share(xs)
  deep_s <- sxs
  for (i in seq_len(70)) deep_s <- deep_s[[1]]
  expect_true(is_shared(deep_s))
  expect_null(shared_name(deep_s))

  xl <- list(leaf = 1:3)
  for (i in seq_len(70)) xl <- list(xl)
  sxl <- share(xl)
  deep_l <- sxl
  for (i in seq_len(68)) deep_l <- deep_l[[1]]
  expect_true(is_shared(deep_l))
  expect_null(shared_name(deep_l))
})

test_that("shared_name returns NULL for a non-mori ALTREP", {
  # A compact-seq ALTREP has no mori_owned_tag at data1 → NULL.
  expect_null(shared_name(1:5))
})
