# mori 0.2.0

* Wire-format change (breaking): The serialization format and the shared memory region naming scheme have both changed.
* `shared_name()` and `map_shared()` now round-trip for sub-lists and extracted elements, not just whole shared objects. Sub-object identifiers carry a bracketed index path (e.g. `/mori_abc_1[2,3]`).
* `shared_name()` now returns `NULL` for non-shared inputs (previously the empty string `""`); `shared_name(x) %||% ""` retains the previous behaviour.
* `share()` on Linux fails with a clean R error when `/dev/shm` is too small (typical in containers, where the limit can be raised at start) instead of SIGBUS-ing mid-serialize (#14).
* `map_shared()` on Linux no longer prefaults the whole region, restoring lazy first-touch access to match macOS.

# mori 0.1.0

* Initial CRAN release.
