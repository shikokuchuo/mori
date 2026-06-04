# share() must not fail when the name it would pick collides with an orphan
# left by a previous process that reused the same PID. This is deterministic
# only where regions are files we can pre-create (Linux /dev/shm).

test_that("share() retries past a colliding orphaned region name", {
  if (Sys.info()[["sysname"]] != "Linux")
    skip("requires file-backed /dev/shm (Linux only)")

  x <- share(1:10)
  nm <- shared_name(x) # "/mori_<pid>_<counter>"
  parts <- regmatches(nm, regexec("^/mori_([0-9a-f]+)_([0-9a-f]+)$", nm))[[1]]
  expect_length(parts, 3L)
  pid_hex <- parts[2]
  next_counter <- strtoi(parts[3], 16L) + 1L

  # Occupy the exact name share() would use next, so its O_EXCL create collides.
  collide <- sprintf("/dev/shm/mori_%s_%x", pid_hex, next_counter)
  collide_name <- sprintf("/mori_%s_%x", pid_hex, next_counter)
  file.create(collide)
  defer(unlink(collide))

  y <- share(1:10) # would target the occupied name; must retry past it
  expect_true(is_shared(y))
  expect_equal(as.integer(y), 1:10)
  expect_false(identical(shared_name(y), collide_name))
  expect_true(file.exists(collide)) # the occupying orphan was left untouched
})
