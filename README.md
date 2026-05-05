
<!-- README.md is generated from README.Rmd. Please edit that file -->

# mori

<!-- badges: start -->

[![CRAN
status](https://www.r-pkg.org/badges/version/mori)](https://CRAN.R-project.org/package=mori)
[![R-CMD-check](https://github.com/shikokuchuo/mori/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/shikokuchuo/mori/actions/workflows/R-CMD-check.yaml)
[![Codecov test
coverage](https://codecov.io/gh/shikokuchuo/mori/graph/badge.svg)](https://app.codecov.io/gh/shikokuchuo/mori)
<!-- badges: end -->

      ________
     /\ mori  \
    /  \       \
    \  /  森   /
     \/_______/

Shared Memory for R Objects

→ `share()` writes an R object into shared memory and returns a shared
version

→ ALTREP serialization hooks — shared objects serialize compactly and
work transparently with `serialize()` and `mirai()`

→ ALTREP-backed lazy access — a 100-column data frame is one `mmap`;
columns materialize on first touch

→ OS-level shared memory (POSIX / Win32) — pure C, no external
dependencies; read-only in other processes, preventing corruption of
shared data

→ Automatic cleanup — shared memory is freed when the R object is
garbage collected

<br />

## Why mori

Parallel computing multiplies memory. When 8 workers each need the same
200 MB dataset, that is 1.6 GB of serialization, transfer, and
deserialization — with 8 separate copies consuming RAM.

`share()` writes the data into shared memory once and each worker maps
the same physical pages — turning per-worker copies into per-worker
references.

``` r
library(mori)
library(mirai)
library(lobstr)

daemons(8)

# 200 MB data frame — 5 columns × 5M rows
df <- as.data.frame(matrix(rnorm(25e6), ncol = 5))
shared_df <- share(df)
```

Without mori, each worker holds the full data frame. With mori, each
worker holds a small reference into the shared region:

``` r
mirai_map(1:8, \(i, data) format(lobstr::obj_size(data)),
          .args = list(data = df))[.flat] |> unique()
#> [1] "200.00 MB"

mirai_map(1:8, \(i, data) format(lobstr::obj_size(data)),
          .args = list(data = shared_df))[.flat] |> unique()
#> [1] "824 B"
```

Avoiding 8 × 200 MB of serialize / deserialize also translates into a
significant runtime saving:

``` r
boot_mean <- \(i, data) colMeans(data[sample(nrow(data), replace = TRUE), ])

# Without mori — each daemon deserializes a full copy
mirai_map(1:8, boot_mean, .args = list(data = df))[] |> system.time()
#>    user  system elapsed 
#>   0.649  13.662   8.442

# With mori — each daemon maps the same shared memory
mirai_map(1:8, boot_mean, .args = list(data = shared_df))[] |> system.time()
#>    user  system elapsed 
#>   0.002   0.004   4.688

daemons(0)
```

## Installation

``` r
install.packages("mori")
```

## Quick Start

`share()` writes an R object once into shared memory and returns a
zero-copy ALTREP view. Shared objects serialize compactly via ALTREP
serialization hooks, working transparently with mirai and any R
serialization path. Shared memory is automatically freed when the object
is garbage collected.

``` r
library(mori)

# Share a vector — returns an ALTREP-backed object
x <- share(rnorm(1e6))
mean(x)
#> [1] -0.0006004896

# Serialized form is ~100 bytes, not ~8 MB
length(serialize(x, NULL))
#> [1] 124
```

## Sharing by Name

`shared_name()` extracts the SHM name from a shared object.
`map_shared()` opens a shared region by name — useful for accessing the
same data from another process without serialization:

``` r
x <- share(1:1e6)

# Extract the SHM name
nm <- shared_name(x)
nm
#> [1] "/mori_7a39_8"

# Another process can map the same region by name
y <- map_shared(nm)
identical(x[], y[])
#> [1] TRUE
```

## Use with mirai

Shared objects can be sent to local daemons — the ALTREP serialization
hooks ensure only the SHM name crosses the wire, and the daemon maps the
same physical memory.

> Workers must run on the same machine — mori shares physical RAM, not
> bytes over a network.

``` r
library(lobstr)
library(mirai)

daemons(1)

x <- share(rnorm(1e6))

# Worker maps the same shared memory — 0 bytes copied
m <- mirai(list(mean = mean(x), size = lobstr::obj_size(x)), x = x)
m[]
#> $mean
#> [1] -0.001750826
#> 
#> $size
#> 840 B

daemons(0)
```

Elements of a shared list also serialize compactly — each element
travels as a reference to its position in the parent shared region, not
as the full data:

``` r
daemons(3)

# Share a list — all 3 vectors in a single shared region
x <- share(list(a = rnorm(1e6), b = rnorm(1e6), c = rnorm(1e6)))

# Each element is sent as (parent_name, index) — zero-copy on the worker
mirai_map(x, \(v) format(lobstr::obj_size(v)))[.flat] |> unique()
#> [1] "840 B"

daemons(0)
```

## How It Works

### What gets shared

All atomic vector types and lists / data frames are written directly
into shared memory, with attributes preserved end-to-end. Pairlists are
coerced to lists. `share()` returns ALTREP wrappers that point into the
shared pages — no deserialization, no per-process memory allocation.

All other R objects (environments, closures, language objects) are
returned unchanged by `share()` — no shared memory region is created.

<figure>
<img src="man/figures/mori-diagram.svg"
alt="Diagram showing share() writing an object once into OS-backed shared memory, which is then memory-mapped by other processes using zero-copy ALTREP wrappers" />
<figcaption aria-hidden="true">Diagram showing share() writing an object
once into OS-backed shared memory, which is then memory-mapped by other
processes using zero-copy ALTREP wrappers</figcaption>
</figure>

### Lazy access

A data frame lives in a single shared region; columns are read on
demand, so a worker that needs 3 of 100 columns only loads 3. Character
strings are accessed lazily per element.

``` r
df <- share(as.data.frame(matrix(rnorm(1e7), ncol = 100)))
shared_name(df)        # one region for all 100 columns
#> [1] "/mori_7a39_b"
shared_name(df[[50]])  # sub-path into the same region
#> [1] "/mori_7a39_b[50]"
```

### Lifetime

Shared memory is managed by R’s garbage collector. The SHM region stays
alive as long as any shared object backed by it remains referenced in R
— the original returned by `share()`, or a column or sub-list extracted
from it, in this or another process. When no references remain, the
garbage collector frees the shared memory automatically.

**Important:** Always assign the result of `share()` to a variable. The
shared memory is kept alive by the R object reference — if the result is
used temporarily (not assigned), the garbage collector may free the
shared memory before a consumer process has mapped it.

### Copy-on-write

Shared data is mapped read-only. Mutations are always local — R’s
copy-on-write mechanism ensures other processes continue reading the
original shared data:

- **Structural changes** to a list or data frame (adding, removing, or
  reordering elements) produce a regular R list. The shared region is
  unaffected.
- **Modifying values** within a shared vector (e.g., `X[1] <- 0`)
  materializes just that vector into a private copy. Other vectors in
  the same shared region stay zero-copy.

–

Please note that the mori project is released with a [Contributor Code
of Conduct](https://shikokuchuo.net/mori/CODE_OF_CONDUCT.html). By
contributing to this project, you agree to abide by its terms.
