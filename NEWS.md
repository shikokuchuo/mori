# mori (development version)

* `share()` on Linux fails with a clean R error when `/dev/shm` is too small (typical in containers, where the limit can be raised at start) instead of SIGBUS-ing mid-serialize (#14).
* `map_shared()` on Linux no longer prefaults the whole region, restoring lazy first-touch access to match macOS.
* `shared_name()` returns the root SHM name for sub-lists and elements.

# mori 0.1.0

* Initial CRAN release.
