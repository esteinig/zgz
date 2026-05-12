# Benchmarks

Generated from `hyperfine` JSON produced by `tools/04-benchmark-files.sh`.

_Last rendered: 2026-05-12T05:59:33+00:00._

## Scope

- Render mode: latest rows for current checkout/version only.
- Version: `0.2.0`; git: `v0.2.0`

Lower mean time is better. `vs fastest` is the slowdown relative to the fastest command in the same file/buffer group. `Input MiB/s` is compressed-input throughput, not decompressed-output throughput.

## `biofast.fq.gz`

Path: `testdata/biofast.fq.gz`  
Compressed size: 464.35 MiB

### Buffer: `2M`

| Tool | Buffer | Mean ± σ (ms) | Median (ms) | vs fastest | Input MiB/s |
|---|---:|---:|---:|---:|---:|
| `zgz` | `2M` | 1836.47 ± 8.31 | 1836.00 | 1.00× | 252.9 |
| `zgzfill` | `2M` | 1857.77 ± 3.18 | 1858.09 | 1.01× | 250.0 |
| `rzgz-zlib-rs` | `2M` | 1863.20 ± 9.47 | 1863.73 | 1.01× | 249.2 |
| `rzgz-miniz` | `2M` | 1863.88 ± 7.61 | 1861.55 | 1.01× | 249.1 |
| `rzgz-zlib-ng` | `2M` | 1865.59 ± 7.29 | 1861.43 | 1.02× | 248.9 |
| `gzip -dc` | `system` | 6153.78 ± 27.60 | 6158.28 | 3.35× | 75.5 |
| `zcat` | `system` | 6163.63 ± 24.37 | 6167.42 | 3.36× | 75.3 |

### Buffer: `default`

| Tool | Buffer | Mean ± σ (ms) | Median (ms) | vs fastest | Input MiB/s |
|---|---:|---:|---:|---:|---:|
| `zgz` | `default` | 1905.78 ± 5.74 | 1906.81 | 1.00× | 243.7 |
| `rzgz-zlib-rs` | `default` | 1912.95 ± 8.90 | 1914.73 | 1.00× | 242.7 |
| `rzgz-zlib-ng` | `default` | 1917.42 ± 6.05 | 1916.69 | 1.01× | 242.2 |
| `rzgz-miniz` | `default` | 1919.33 ± 5.92 | 1916.80 | 1.01× | 241.9 |
| `zgzfill` | `default` | 1930.90 ± 8.39 | 1928.47 | 1.01× | 240.5 |
| `gzip -dc` | `system` | 6153.78 ± 27.60 | 6158.28 | 3.23× | 75.5 |
| `zcat` | `system` | 6163.63 ± 24.37 | 6167.42 | 3.23× | 75.3 |
