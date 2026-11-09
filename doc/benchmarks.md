# Benchmarks

`bench/` (dub subpackage `:bench`) times the client's own work against an
in-memory fake server (`bench/source/benchmarks/fakeserver.d`): a `Transport`
that answers the frontend messages with canned responses, so neither the
network nor a real server is measured. Each case is prepared once, then run
at least 5 times and for at least the minimum time; the runner reports the
median and minimum time and the bytes allocated per row (per call for the
`1000 ...` cases: divide by 1000 for one call, rows is the result size).

```sh
dub run :bench -b release                       # all cases
dub run :bench -b release -- --filter copyOut/  # the cases whose name contains the text
dub run :bench -b release -- --rows 10000 --min-time 2 --csv results.csv
```

On a busy machine compare the `min ms` column; the median moves with
background load.

## Results

Issue #35 (allocation and performance fixes from the code review), LDC 1.36
`-b release`, WSL2 on a shared machine (approximate: compare ratios, not
absolute numbers). Minimum time in ms, allocated bytes per row.

| case | rows | before ms | after ms | speed-up | before B/row | after B/row |
|---|---:|---:|---:|---:|---:|---:|
| query/iterate 10 columns | 100000 | 41.87 | 16.11 | 2.6× | 400 | 352 |
| query/getters 10 columns | 100000 | 119.74 | 56.55 | 2.1× | 640 | 400 |
| query/3 getters by name | 100000 | 45.86 | 24.65 | 1.9× | 400 | 352 |
| query/struct 10 fields | 100000 | 129.33 | 59.20 | 2.2× | 640 | 400 |
| query/simple protocol getString | 100000 | 45.78 | 20.74 | 2.2× | 432 | 432 |
| query/1000 queryValue on N rows | 100 | 5.69 | 2.77 | 2.1× | 10080 | 5280 |
| query/1000 exec on N rows | 100 | 48.10 | 2.71 | 17.7× | 406240 | 5440 |
| params/exec 5 int4 | 100000 | 257.19 | 63.03 | 4.1× | 864 | 192 |
| params/exec 3 ? placeholders | 100000 | 347.03 | 64.66 | 5.4× | 1104 | 192 |
| params/exec 6 mixed types | 100000 | 298.74 | 66.41 | 4.5× | 1152 | 192 |
| params/exec 5 Variant | 100000 | 368.32 | 81.09 | 4.5× | 1088 | 192 |
| params/exec int4[1000] | 1000 | 86.54 | 7.22 | 12.0× | 55829 | 212 |
| params/insert 5 fields | 100000 | 72.98 | 6.71 | 10.9× | 365 | 49 |
| params/rewritePlaceholders 100 chars | 1000000 | 2246.95 | 235.12 | 9.6× | 480 | 160 |
| value/numeric getString | 100000 | 77.63 | 28.03 | 2.8× | 272 | 96 |
| value/numeric getDouble | 100000 | 85.32 | 27.62 | 3.1× | 272 | 80 |
| value/numeric getDecimal | 100000 | 93.21 | 33.24 | 2.8× | 304 | 112 |
| value/numeric getLong | 100000 | 54.21 | 23.27 | 2.3× | 192 | 80 |
| value/timestamptz getString | 100000 | 126.17 | 25.51 | 4.9× | 336 | 80 |
| value/inet getString | 100000 | 73.76 | 23.39 | 3.2× | 176 | 80 |
| value/int4[100] get!(int[]) | 100000 | 209.16 | 199.64 | 1.0× | 9856 | 1616 |
| value/int4[100] getString | 100000 | 1143.83 | 399.46 | 2.9× | 12128 | 3184 |
| value/text int4[100] get!(int[]) | 100000 | 2382.78 | 703.04 | 3.4× | 17616 | 7808 |
| value/text text[5] get!(string[]) | 100000 | 211.30 | 92.18 | 2.3× | 832 | 512 |
| copyIn/text writeRow 5 fields | 100000 | 382.07 | 310.16 | 1.2× | 785 | 656 |
| copyIn/csv writeRow 5 fields | 100000 | 414.21 | 318.19 | 1.3× | 825 | 656 |
| copyIn/write raw lines | 1000000 | 20.40 | 12.70 | 1.6× | 81 | 0 |
| copyOut/text rows | 100000 | 209.50 | 60.06 | 3.5× | 528 | 320 |
| copyOut/text rows getters | 100000 | 212.42 | 68.12 | 3.1× | 528 | 320 |
| copyOut/csv rows | 100000 | 201.63 | 92.25 | 2.2× | 560 | 352 |
| copyOut/binary rows | 100000 | 51.46 | 18.39 | 2.8× | 400 | 192 |
| copyOut/binary rows getters | 100000 | 57.95 | 24.00 | 2.4× | 400 | 192 |

`params/exec 6 mixed types` takes a `const Date`, which did not compile
before #35; its "before" was measured with a mutable one.

The COPY IN `writeRow` cases spend most of their time formatting the `double`
value as text (`formatFloat8`, shortest digits by trial); #36 replaces that.
