# Changelog

## mori (development version)

- [`share()`](https://shikokuchuo.net/mori/dev/reference/share.md) on
  Linux fails with a clean R error when `/dev/shm` is too small (typical
  in containers, where the limit can be raised at start) instead of
  SIGBUS-ing mid-serialize
  ([\#14](https://github.com/shikokuchuo/mori/issues/14)).
- [`map_shared()`](https://shikokuchuo.net/mori/dev/reference/map_shared.md)
  on Linux no longer prefaults the whole region, restoring lazy
  first-touch access to match macOS.
- [`shared_name()`](https://shikokuchuo.net/mori/dev/reference/shared_name.md)
  returns the root SHM name for sub-lists and elements.

## mori 0.1.0

CRAN release: 2026-04-21

- Initial CRAN release.
