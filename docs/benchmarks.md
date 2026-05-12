# Benchmarks

Generated from `hyperfine` JSON produced by `tools/04-benchmark-files.sh`.

_Last rendered: 2026-05-12T05:27:50+00:00._

## Scope

- Render mode: latest rows for current checkout/version only.
- Version: `0.1.0`; git: `v0.1.0-dirty`

Lower mean time is better. `vs fastest` is the slowdown relative to the fastest command in the same file/buffer group. `Input MiB/s` is compressed-input throughput, not decompressed-output throughput.

## `biofast.fq.gz`

Path: `testdata/biofast.fq.gz`  
Compressed size: 464.35 MiB

### Buffer: `2M`

| Tool | Buffer | Mean ± σ (ms) | Median (ms) | vs fastest | Input MiB/s |
|---|---:|---:|---:|---:|---:|
| `zgz` | `2M` | 1850.17 ± 8.06 | 1845.77 | 1.00× | 251.0 |
| `zgzfill` | `2M` | 1870.76 ± 2.35 | 1870.66 | 1.01× | 248.2 |
| `rzgz-zlib-ng` | `2M` | 1870.93 ± 3.24 | 1871.39 | 1.01× | 248.2 |
| `rzgz-zlib-rs` | `2M` | 1871.32 ± 1.76 | 1871.04 | 1.01× | 248.1 |
| `rzgz-miniz` | `2M` | 1875.30 ± 4.97 | 1873.75 | 1.01× | 247.6 |
| `zcat` | `system` | 6183.73 ± 8.94 | 6181.51 | 3.34× | 75.1 |
| `gzip -dc` | `system` | 6190.33 ± 7.17 | 6190.56 | 3.35× | 75.0 |

### Buffer: `default`

| Tool | Buffer | Mean ± σ (ms) | Median (ms) | vs fastest | Input MiB/s |
|---|---:|---:|---:|---:|---:|
| `zgz` | `default` | 1919.90 ± 8.44 | 1917.43 | 1.00× | 241.9 |
| `rzgz-zlib-rs` | `default` | 1924.02 ± 9.27 | 1921.05 | 1.00× | 241.3 |
| `rzgz-zlib-ng` | `default` | 1926.28 ± 3.48 | 1924.91 | 1.00× | 241.1 |
| `rzgz-miniz` | `default` | 1927.14 ± 2.85 | 1927.21 | 1.00× | 241.0 |
| `zgzfill` | `default` | 1941.31 ± 4.58 | 1940.24 | 1.01× | 239.2 |
| `zcat` | `system` | 6183.73 ± 8.94 | 6181.51 | 3.22× | 75.1 |
| `gzip -dc` | `system` | 6190.33 ± 7.17 | 6190.56 | 3.22× | 75.0 |
