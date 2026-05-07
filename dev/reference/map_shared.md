# Open Shared Memory by Name

Open a shared memory region identified by a name string and return an
ALTREP-backed R object that reads directly from shared memory.

## Usage

``` r
map_shared(name)
```

## Arguments

- name:

  a character string as returned by
  [`shared_name()`](https://shikokuchuo.net/mori/dev/reference/shared_name.md):
  either a bare shared memory name (opens the root) or a name with a
  1-based bracketed index path (e.g. `"/mori_abc_1[2,3]"`, opens the
  addressed sub-list or element directly).

## Value

The R object stored at the named region (or sub-object at the given
path), or `NULL` if `name` is not a valid shared memory name (wrong
type, length, `NA`, missing or malformed prefix, or malformed bracketed
path). If `name` parses as valid but the region is absent or corrupted —
or the path doesn't address a valid sub-object — an error is raised.

## See also

[`share()`](https://shikokuchuo.net/mori/dev/reference/share.md) to
create a shared object,
[`shared_name()`](https://shikokuchuo.net/mori/dev/reference/shared_name.md)
to extract the shared memory name.

## Examples

``` r
x <- share(1:100)
nm <- shared_name(x)
y <- map_shared(nm)
sum(y)
#> [1] 5050
```
