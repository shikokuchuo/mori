# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

mori — Shared Memory for R Objects. Uses POSIX shared memory (Linux, macOS) and Win32 file mappings (Windows) with R's ALTREP framework to let multiple processes on the same machine read the same physical memory pages. No external dependencies. Requires R >= 4.3.0 (for ALTLIST). API: `share()` → ALTREP shared object, `map_shared()` → open SHM by name, `shared_name()` → extract identifier, `is_shared()` → test if shared. `shared_name()` returns a path-bearing identifier of the form `<prefix>[i1,i2,...]` for sub-lists / elements (1-based) and the bare prefix for roots; `map_shared()` accepts both forms and round-trips the addressed object directly. ALTREP serialization hooks emit the same identifier as the wire form — transparent under `serialize()` and `mirai`. Nested VECSXP elements are zero-copy: each level is an inline self-describing MORL region inside the parent SHM.

## Development Commands

### Testing

```r
# Run the full testthat suite
devtools::test()

# Run a single test file
devtools::test_active_file()
testthat::test_file("tests/testthat/test-nested.R")
```

### Building and Checking

```bash
# Build package
R CMD build .

# Check package
R CMD check --no-manual mori_*.tar.gz
```

```r
# Generate documentation from roxygen2 comments
devtools::document()
```

## Storage Model

- **Zero-copy (SHM-backed)**: All atomic vectors (any type, any attributes) and data frame columns are written directly into SHM and backed by ALTREP on consumers. Attributes serialize into a trailing region and restore via `SET_ATTRIB`. Numeric `Dataptr_or_null` returns the SHM pointer; `Dataptr(writable=TRUE)` triggers COW into a private copy. String `Elt` lazily creates CHARSXPs via `Rf_mkCharLenCE`; `Dataptr_or_null` returns NULL to force per-element access.
- **Nested lists (zero-copy)**: VECSXP/LISTSXP elements of a shared list are written inline as a complete child MORL region at their `data_offset`. Each level wraps in its own ALTLIST via a lightweight `mori_list_view` (pointer + bounds + index). `is_shared()` returns TRUE for sub-lists; `shared_name()` returns the root SHM name plus a 1-based bracketed index path (e.g. `/mori_abc_1[2,3]`); `map_shared(shared_name(sub))` opens the addressed sub-list / element directly. The OS-level region name is the prefix before `[` and is recoverable via `sub("\\[.*$", "", shared_name(x))`.
- **Pass-through**: All other R objects (environments, closures, language objects, NULL) are returned unchanged. No SHM is created.

## Concurrency Model

mori is **write-once on host, read-many on consumers, COW for any mutation.** Each `share()` allocates a new SHM region with a unique name; existing regions are never mutated. The host writes the full region inside `mori_create` before returning, and consumers obtain the name only after that call returns — partial writes are not observable. Consumer mappings are read-only (`PROT_READ` / `FILE_MAP_READ`); mutations trigger COW into private memory. No locking is implemented or required; any future change admitting in-place mutation breaks this model.

## share() Dispatch (`altrep.c: mori_create`)

All R exported functions are single `.Call` wrappers. `mori_create` dispatches on `TYPEOF(x)`:

0. Already a mori-backed ALTREP (`mori_owned_tag` on `R_altrep_data1(x)`) → return `x` unchanged. Idempotence required: re-sharing a sub-list view must not allocate a fresh root region (would break `shared_name()`).
1. `NILSXP` → returned as-is.
2. `VECSXP`/`LISTSXP` → `mori_shm_create_list_call` — ALTLIST with per-element directory. Pairlists are coerced to VECSXP at every level. Data frames go through this path.
3. `STRSXP` → `mori_shm_create_string_call` — ALTSTRING with offset table + packed strings.
4. SHM-eligible atomics (`REALSXP`, `INTSXP`, `LGLSXP`, `RAWSXP`, `CPLXSXP`) → `mori_shm_create_vector_call`.
5. Everything else → returned as-is.

Each path returns via `mori_make_result`, which chains the host extptr into the ALTREP's keeper chain (see Internal State and Lifetime).

### Two-pass write invariant

Writing into SHM is count-then-write in two flavours: `mori_serialize_count` / `mori_serialize_into` (serialize.c, fallback serialized bytes) and the recursive `mori_nested_size` / `mori_nested_write` (altrep.c, whole MORL regions). **If the count and the writer disagree by even one byte, the SHM region is malformed and consumers will read garbage.** Any change to either side must be mirrored in the other.

## ALTREP Classes

Registered in `mori_altrep_init`. Numeric types — `mori_real`, `mori_integer`, `mori_logical`, `mori_raw`, `mori_complex` — share the `mori_vec` pattern with a SHM-backed data pointer. `mori_string` uses `mori_str` with lazy per-element access via `Elt` and `Rf_mkCharLenCE`. `mori_list` uses `mori_list_view` with a per-element directory and a lazy `Elt` cache that uses `R_NilValue` as the "uncached" sentinel — a fresh VECSXP is naturally R_NilValue-filled, so cache init is zero work. NIL-valued elements are the sole singleton output of `mori_unwrap_element`'s fallback path, so they aren't cached; re-extraction returns the same `R_NilValue` and identity is preserved for free.

### COW invariant for new ALTREP methods

Any method returning a writable pointer (or mutating) **must check `R_altrep_data2(x)` first** — if non-null, the vector has been materialized to a private copy and the SHM pointer is no longer authoritative. New `Dataptr` / coercion methods routinely forget this. `Dataptr_or_null` returns the materialized copy when data2 is set, the SHM pointer otherwise.

## ALTREP Serialization Hooks

All classes register `Serialized_state` and `Unserialize`.

- **Identifier wire form (single canonical shape)**. `mori_format_chain` is the single source of truth used by both `mori_shm_name` (the `.Call`) and the three `Serialized_state` methods. It seeds a stack-allocated `path[MORI_MAX_PATH]` from the rear with the leaf's index (when `>= 0`), then walks the keeper chain through `mori_owned_tag` hops, prepending each `view->index` (`>= 0` only) into the buffer — root→leaf order falls out in `path[rear..MORI_MAX_PATH)` without a second pass. Formats `<prefix>` (root) or `<prefix>[i1+1,...]` (sub-object) into a caller-provided 1 KB stack buffer using `shm->name_len` (cached at create/open time, no per-call `strlen`). 1-based externalisation cues R's `[[i]]` semantics; the parser converts back to 0-based.
- **Unserialize**. `mori_Unserialize` delegates STRSXP × 1 state to `mori_shm_open_and_wrap`; on parse-success it returns the opened ALTREP, on parse-failure it falls through to expanded-state handling (the COW-materialized ALTSTRING case). `mori_shm_open_and_wrap` runs `mori_parse_identifier`: prefix-only routes through magic-dispatch, path form routes through `mori_open_path_c` (C-level core that walks each intermediate VECSXP directory via `mori_make_view_extptr` — a bare keeper-chain extptr with no ALTLIST wrapper and no attribute restoration, since intermediates are never observed — bounds-checking children against parents, and calls `mori_unwrap_element` at the leaf where the full ALTLIST + attrs are constructed).

Fallback to full materialization when:
- COW-materialized vectors (data2 is set) — returns the materialized copy.
- Nesting depth exceeds `MORI_MAX_PATH` (64) in `mori_format_chain`.

### Identifier grammar

```
identifier ::= prefix [ "[" int1 ("," int1)* "]" ]
prefix     ::= MORI_PREFIX_LITERAL hex+ "_" hex+
hex+       ::= [0-9a-f]+         # one or more, lowercase
int1       ::= [1-9][0-9]*       # 1-based, no leading zeros
```

`MORI_PREFIX_LITERAL` (in `mori.h`) is `/mori_` (POSIX) / `Local\\mori_` (Windows) and is the **single source of truth shared between `shm.c`'s name-format strings** (`MORI_PREFIX_LITERAL "%x_%x"` POSIX, `MORI_PREFIX_LITERAL "%lx_%x"` Windows) and the parser's literal `memcmp`. Change once; both sides stay in sync. Names are variable-width hex (no zero-padding); `MORI_NAME_MAX = 30` bounds the prefix on either platform (Windows worst case: `Local\\mori_<8hex>_<8hex>` = 28 chars + NUL).

`mori_parse_identifier` is bounded and single-pass: `memchr` length cap (`MORI_IDENTIFIER_MAX`) → literal `memcmp` against `MORI_PREFIX_LITERAL` → two bounded hex-digit run scans separated by `_` (each guarded by `p < eos`, each rejecting empty runs) → dispatch on the byte after the second run (`\0` for prefix-only, `[` for path) → comma-separated 1-based indices with per-token `INT32_MAX` overflow check, terminated by `]`. Indices stored as 0-based. The path-parse loop relies on NUL-termination as a sentinel (every fail-branch's predicate excludes `\0`), so trailing `p < eos` checks aren't needed there. Sizing invariant: `MORI_NAME_MAX + 2 + 11 × MORI_MAX_PATH < MORI_FORMAT_BUFLEN`.

### Validation contract

`map_shared` and unserialize share `mori_parse_identifier` for shape validation but differ in failure mode: **malformed input → `NULL`** (wrong type/length, `NA`, missing or malformed prefix, malformed bracketed path); **well-formed identifier that fails to map → error** (missing region, bad magic, truncated header, OOB path index, non-VECSXP intermediate). Preserve this split in `mori_shm_open_and_wrap`: collapsing it either way breaks the probe-vs-corruption distinction.

## SHM Region Layouts

Magic identifier in the first 4 bytes: MORH (`0x4D4F5248`) atomic vector, MORL (`0x4D4F524C`) ALTLIST, MORS (`0x4D4F5253`) ALTSTRING. The tables below are the canonical spec; `mori_serialize_into` and `mori_nested_write` are the implementations.

**MORH — atomic vector.** 64-byte header, data starts at byte 64 (64-byte aligned for SIMD). Trailing serialized attributes (if any) follow the data.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | magic (`0x4D4F5248`) |
| 4 | 4 | sexptype (REALSXP, INTSXP, etc.) |
| 8 | 8 | length (int64) |
| 16 | 8 | attrs_size (int64, 0 if no attributes) |
| 24 | 40 | reserved (zero) |
| 64+ | | raw vector data |
| 64 + length×elt_size | | serialized attributes (`attrs_size` bytes, if > 0) |

Attributes are a serialized pairlist; `mori_restore_attrs` unserializes and applies via `SET_ATTRIB` on the consumer.

**MORL — ALTLIST.** Header + element directory + per-element data regions.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | magic (`0x4D4F524C`) |
| 4 | 4 | n_elements (int32) |
| 8 | 8 | attrs_offset (int64) |
| 16 | 8 | attrs_size (int64) |
| 24 | 32×n | element directory |
| varies | | element data (64-byte aligned) |
| varies | | serialized attributes |

Each directory entry (32 bytes): `data_offset(8) + data_size(8) + sexptype(4) + attrs_size(4) + length(8)`. `sexptype` semantics: `0` → serialized bytes (via serialize.c); `STRSXP` → offset table + packed strings at `data_offset`; `VECSXP` → nested MORL region inlined at `data_offset` of size `data_size` (child's own header / directory / elements / attrs all inline; parent's `attrs_size` is always 0 for VECSXP children); other → raw zero-copy data. For non-VECSXP entries with `attrs_size > 0`, attrs are appended within the data region at `data_offset + data_size - attrs_size`.

**MORS — ALTSTRING.** 24-byte header + offset table + packed string bytes + optional trailing attributes.

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | magic (`0x4D4F5253`) |
| 4 | 4 | attrs_size (int32, 0 if none) |
| 8 | 8 | n_strings (int64) |
| 16 | 8 | str_data_size (int64, total size of offset table + packed strings) |
| 24 | 16×n | offset table |
| 64-aligned | | packed string bytes |
| 24 + str_data_size | | serialized attributes (`attrs_size` bytes, if > 0) |

Each offset table entry (16 bytes): `str_offset(int64) + str_length(int32) + str_encoding(int32)`. `str_offset` is relative to the start of the packed string area. `str_length < 0` means `NA_STRING`. `str_encoding` is a `cetype_t` (0=native, 1=UTF-8, 2=Latin-1, 3=bytes). The same layout is used inline for STRSXP elements within ALTLIST regions (offset table starts at the element's `data_offset`; element-level attrs use the directory entry's `attrs_size` field).

## Internal State and Lifetime

SHM lifetime is fully automatic via chained external pointer finalizers. Three interned symbols (C globals in `altrep.c`):

- **`mori_shm_tag`** (`Rf_install("mori_shm")`) — tags the SHM mapping extptr (host- and consumer-side). Addr is `mori_shm *`; finalizer: `munmap`.
- **`mori_host_tag`** (`Rf_install("mori_host")`) — tags the host-only unlink extptr created by `mori_make_result`. Addr is `mori_shm *` carrying `name` (POSIX) or `HANDLE` (Windows); finalizer: `shm_unlink` / `CloseHandle`. Sits above the shm terminus in the keeper chain.
- **`mori_owned_tag`** (`Rf_install("mori_owned")`) — tags every malloc-backed extptr in the keeper chain: each mori ALTREP's `data1` extptr (view, vec, or str) **and** the bare keeper-chain extptrs created by `mori_make_view_extptr` for path-walk intermediates (which have no ALTREP wrapper but still hold a `mori_list_view *`). Addr type for ALTREP data1 is recovered from `TYPEOF(x)` at the ALTREP boundary: `VECSXP → mori_list_view *`, `STRSXP → mori_str *`, else `mori_vec *`. Bare keeper-chain hops are always `mori_list_view *` (vec/str only ever appear as leaves). Standalone-vs-element carried in each struct's `index` field (`-1` standalone/root, `>= 0` element/sub-list); redundantly recoverable from `data1.prot`'s tag (`shm_tag → standalone`, `owned_tag → element/sub-list`). Common finalizer: `mori_owned_finalizer` `free`s the addr.

`is_shared()` is a pointer comparison against `mori_owned_tag`. `mori_shm_name()` invokes `mori_format_chain` to emit the bare prefix for roots / standalones and the path-bearing form (`<prefix>[i1,i2,...]`, 1-based) for sub-objects.

### Keeper chain

- **Host side (`share`)**: `mori_shm_create` allocates and mmaps the region; the POSIX fd is closed after mmap (mapping stays valid). `mori_make_result` splits ownership — the ALTREP wrapper gets the mapping via the `mori_shm_tag` extptr (finalizer → `munmap`); the host extptr (`mori_host_tag`, finalizer → `shm_unlink` / `CloseHandle`) is chained as that extptr's `prot`. Both finalizers run when the ALTREP is GC'd. `R_RegisterCFinalizerEx(..., TRUE)` covers session exit.
- **Consumer side (`map_shared` / unserialize)**: `mori_shm_open` maps read-only (size via `fstat` / `VirtualQuery`); fd closed after mmap. The shm extptr's finalizer is `munmap` only — never unlink. For lists opened by prefix, the shm extptr's immediate child is a root view extptr (`mori_list_view *`, index=-1) that becomes ALTREP data1; sub-lists accessed via `Elt` (index >= 0) chain through their parent view extptr the same way. For path-form `map_shared("/mori_x_y[i,j,...]")`, intermediate hops are bare keeper-chain extptrs (`mori_make_view_extptr`, no ALTLIST) — only the leaf's ALTREP exists. The chain shape is identical for `mori_format_chain`'s purposes either way. Element vectors hold a `mori_vec` / `mori_str` extptr whose `prot` is the immediate parent view (or the shm extptr for vec/str at the root).
- **Element lifetime**: leaves keep the root SHM alive through the chain (leaf → parent view(s) → shm extptr → host extptr). Every `R_MakeExternalPtr` retains its `prot`, so the chain survives even if enclosing ALTLIST(s) are GC'd. `mori_format_chain` is the only chain walker: it walks `mori_owned_tag` hops (always `mori_list_view *` — vec/str extptrs are only ever leaves), collecting view indices (skipping the root view's -1) until it hits the shm extptr.

## Code Organization

### src/

- **mori.h** — types (`mori_shm`, `mori_buf`, `mori_vec` with `index` field, `mori_list_view`), declarations, `MORI_ALIGN64`, and the identifier grammar constants (`MORI_NAME_MAX`, `MORI_MAX_PATH`, `MORI_IDENTIFIER_MAX`, `MORI_FORMAT_BUFLEN`, `MORI_PREFIX_LITERAL`).
- **shm.c** — platform SHM create/open/close + finalizers for both sides.
- **serialize.c** — `mori_serialize_count`, `mori_serialize_into`, `mori_unserialize_from`, `mori_sizeof_elt`. Used for fallback (non-zero-copy) ALTLIST entries where directory `sexptype == 0`.
- **altrep.c** — all ALTREP class definitions, `mori_create` dispatcher, recursive writers (`mori_nested_size` / `mori_nested_write`), consumer open+wrap (`mori_shm_open_and_wrap`), path open (`mori_open_path_c`), view constructors (`mori_make_view_extptr` for bare keeper-chain extptrs, `mori_make_list_view` for full ALTLIST + attrs), identity/name (`mori_is_shared` / `mori_shm_name`), identifier formatter / parser (`mori_format_chain` / `mori_parse_identifier`), serialization hooks, `mori_altrep_init`.
- **init.c** — `R_init_mori`, `.Call` registration table (4 entries: `mori_create`, `mori_shm_open_and_wrap`, `mori_is_shared`, `mori_shm_name`).

`.Call` names match C function names; all entry points take a single `SEXP`.

### R/

`mori-package.R` (package docs) and `share.R` (four `.Call` wrappers — dispatch and error handling are at the C level).

## Testing

testthat edition 3. Entry point `tests/testthat.R`; tests in `tests/testthat/test-*.R` grouped by topic (each file's `desc()` strings are authoritative). All tests run unconditionally — nothing gated behind `skip_on_cran` or environment variables.

## Platform Notes

- **Linux**: SHM in `/dev/shm/` (tmpfs). Accessed via `open()` / `unlink()` directly to avoid the `-lrt` link dependency that `shm_open` requires. `MAP_POPULATE` pre-faults pages.
- **macOS**: Kernel-backed SHM via `shm_open` / `shm_unlink` (in libc, no extra link flags). `MAP_POPULATE` is a no-op (defined to 0).
- **Windows**: Page-file-backed via `CreateFileMappingA` / `MapViewOfFile`. `kernel32` is always available. Host must keep the mapping handle alive until consumers have opened it (the GC-chained host extptr handles this).

## Package Conventions

- roxygen2 with markdown support; NAMESPACE is auto-generated.
- MIT license.
- `README.md` is generated from `README.Rmd` — edit the `.Rmd` and re-knit, never edit `README.md` directly.
- `CLAUDE.md` and `.claude/` are excluded from package builds (via `.Rbuildignore`).
