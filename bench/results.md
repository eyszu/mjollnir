| workload | Mjollnir (ms) | crystal-pg (ms) | speedup | checksum |
|---|---:|---:|---:|:---:|
| select_one | 870.2 | 1545.9 | 1.78x | ok |
| point_lookup | 1007.7 | 2268.4 | 2.25x | ok |
| pool_8_fibers | 427.6 | 778.4 | 1.82x | ok |
| scan_ints_1M | 225.4 | 228.9 | 1.02x | ok |
| scan_text_300k | 152.5 | 130.1 | 0.85x | ok |
| scan_mixed_200k | 88.5 | 87.3 | 0.99x | ok |
| int_arrays_50k | 57.7 | 51.9 | 0.90x | ok |
| jsonb_any_20k | 27.5 | 30.7 | 1.12x | ok |
| jsonb_typed_20k | 23.4 | 29.5 | 1.26x | ok |
| insert_loop_10k | 490.5 | 754.4 | 1.54x | ok |
| insert_50k | 219.0 | 3828.9 | 17.48x | ok |
