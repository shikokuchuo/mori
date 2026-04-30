# Extract Shared Memory Name

Extract the SHM region name from a shared object. This name can be
passed to
[`map_shared()`](https://shikokuchuo.net/mori/dev/reference/map_shared.md)
to open the same region in another process.

## Usage

``` r
shared_name(x)
```

## Arguments

- x:

  a shared object as returned by
  [`share()`](https://shikokuchuo.net/mori/dev/reference/share.md) or
  [`map_shared()`](https://shikokuchuo.net/mori/dev/reference/map_shared.md).

## Value

A character string identifying the shared memory region, or the empty
string `""` if `x` is not a shared object. For a sub-list or element
extracted from a shared list, the name returned is the root region's
name; mapping it via
[`map_shared()`](https://shikokuchuo.net/mori/dev/reference/map_shared.md)
yields the root object, from which the sub-list or element can be
re-accessed.

## See also

[`map_shared()`](https://shikokuchuo.net/mori/dev/reference/map_shared.md)
to open a shared region by name.

## Examples

``` r
x <- share(rnorm(100))
shared_name(x)
#> [1] "/mori_1a32_3"
```
