# share() picks a fresh name per call (mori_<pid>_<counter>) and creates it with
# O_EXCL, so it never reuses or mutates an existing region. A name collision with
# an orphan left by a previous process that reused the same PID is therefore
# surfaced as an error (prune_shared() is the mechanism for clearing such
# orphans), not worked around. Deterministic only where regions are files we can
# pre-create (Linux /dev/shm).

test_that("share() errors when the name it would use is already taken", {
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
  file.create(collide)
  defer(unlink(collide))

  # The error envelope carries the requested size, the collision summary, and
  # the prune_shared() remediation hint.
  expect_error(
    share(1:10),
    "cannot create region.*already in use.*prune_shared"
  )
})
