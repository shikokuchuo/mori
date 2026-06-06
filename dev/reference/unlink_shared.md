# Unlink Shared Memory Regions

Remove shared memory regions created by
[`share()`](https://shikokuchuo.net/mori/dev/reference/share.md). Pass
one or more region names to remove specific regions, or call with no
arguments to reap *orphaned* regions: those whose creating process has
died without cleaning up, for example after a crash, a `SIGKILL`, or the
out-of-memory killer.

This function is only needed on Linux and macOS. On Windows, shared
memory cannot be orphaned, so there is never anything to clean up and
calling it has no effect.

## Usage

``` r
unlink_shared(name = NULL)
```

## Arguments

- name:

  a character vector of shared memory names as returned by
  [`shared_name()`](https://shikokuchuo.net/mori/dev/reference/shared_name.md),
  or `NULL` (the default) to reap orphaned regions. A sub-object path
  (e.g. `"/mori_abc_1[2,3]"`) is accepted and resolves to its underlying
  region. Names that are not valid mori identifiers are ignored.

## Value

Invisibly, a character vector of the region names that were removed, or
`NULL` if nothing was removed.

## Details

Shared memory is normally managed automatically: a region is unlinked
when the
[`share()`](https://shikokuchuo.net/mori/dev/reference/share.md) object
that owns it is garbage-collected, and on a clean R session exit. A
region is only left behind if the owning process is killed before either
can run. `unlink_shared()` removes such leftovers.

Unlinking a region removes only its name. Processes that have already
mapped it keep reading until they release it; the memory is freed once
the last mapping is gone.

The reap form (`name = NULL`) is **conservative**: a region is removed
only if its creating process — encoded in the region name — is no longer
running, so regions still in use by a live process are never touched.

## See also

[`share()`](https://shikokuchuo.net/mori/dev/reference/share.md) to
create a shared object,
[`shared_name()`](https://shikokuchuo.net/mori/dev/reference/shared_name.md)
to extract a region name.

## Examples

``` r
x <- share(rnorm(100))
nm <- shared_name(x)
rm(x)
unlink_shared(nm)
```
