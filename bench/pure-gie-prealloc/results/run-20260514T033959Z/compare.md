# A/B benchmark: PR #2924 (preallocate EPP request body buffer)

Run timestamp: `20260514T033959Z` (UTC)
Run directory: `results/run-20260514T033959Z/`

## Configuration

| key | value |
|---|---|
| concurrency      | 1200 |
| input_chars      | 220000 |
| warmup_reqs      | 300 |
| round_reqs       | 1500 |
| rounds (B/P alt) | 2 |
| baseline tag     | epp:baseline |
| prealloc tag     | epp:prealloc |
| ttft_threshold_ms| 1100 |
| host_cpus        | 24 |

## Headline (median across rounds, per arm)

| metric | baseline | prealloc | drop (baseline - prealloc) |
|---|---:|---:|---:|
| TTFT median-of-round-means (ms)            | 1330.64 | 1286.26 | 3.3% |
| Process() flat alloc share (%)             | 30 | 13.205 | 56.0% |
| Process() cum  alloc share (%)             | 69.89  | 64.045  | 8.4% |

## Verdict: **PASS**

(*StreamingServer).Process flat alloc share dropped by 56.0% (>=30%).

## Per-round raw

```
round	arm	tag	ttft_median_ms	process_flat_pct	process_cum_pct	total_alloc
1	baseline	baseline	1288.99	29.41	69.42
1	prealloc	prealloc	1301.92	13.61	63.08
2	prealloc	prealloc	1270.59	12.80	65.01
2	baseline	baseline	1372.29	30.59	70.36
```

## Notes

- Allocation deltas (`allocs-delta.top30.txt`) attribute only the
  measured window (after warmup); absolute profiles
  (`allocs-after.top30.txt`) are kept too for direct comparability
  with the historical `results/historical/round-{1,2}/` numbers.
- Single-machine vllm-sim TTFT is dominated by simulator state and
  EPP request-path overhead; PR #2924 specifically targets the
  request-body `append` hotspot, so the strongest signal is the
  Process() flat alloc share, not TTFT itself.
