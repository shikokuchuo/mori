# mori 0.2.2

* Region name counters now start at a per-process random value, so a process reusing a crashed process's PID no longer collides with its orphaned regions (#50).

# mori 0.2.1

* New `prune_shared()` removes shared memory regions orphaned by a process that was killed before it could clean up (#25).
* When `share()` fails to create a shared memory region it now reports the requested size and, where applicable, an actionable hint (e.g. raising a container's `/dev/shm` limit) instead of a generic message (#29).

# mori 0.2.0

* Wire-format change (breaking): The serialization format and the shared memory region naming scheme have both changed.
* `shared_name()` and `map_shared()` now round-trip for sub-lists and extracted elements, not just whole shared objects. Sub-object identifiers carry a bracketed index path (e.g. `/mori_abc_1[2,3]`).
* `shared_name()` now returns `NULL` for non-shared inputs (previously the empty string `""`); `shared_name(x) %||% ""` retains the previous behaviour.
* `share()` on Linux fails with a clean R error when `/dev/shm` is too small (typical in containers, where the limit can be raised at start) instead of SIGBUS-ing mid-serialize (#14).
* `map_shared()` on Linux no longer prefaults the whole region, restoring lazy first-touch access to match macOS.

# mori 0.1.0

* Initial CRAN release.
