# Test Suite Contract

## Whole-suite runtime baseline

Measured on 2026-09-25 from commit
`93102fbafd685f80e12f64023a07ce4bee6727fc`.

Environment:
- MacBook Pro M4 Pro, 48 GB
- Ruby 4.0.6
- 1 warm-up run discarded
- 10 measured runs
- 264 tests
- 1,664 assertions
- 3 skips

Runtime:
- min: 3.919 s
- median: 4.012 s
- mean: 4.031 s
- max: 4.246 s
- stddev: 0.099 s

## Whole-suite runtime ceilings

The ordinary, non-coverage test suite is protected by absolute wall-clock
ceilings measured with a monotonic clock on the same local development
hardware used for the baseline.

- warning threshold: 5.0 s
- hard failure threshold: 5.5 s

`rake test:runtime` runs the ordinary suite and applies these thresholds.
`rake test:contract` uses `test:runtime` as its product-test gate, so a suite
that reaches the hard ceiling fails the contract. Coverage instrumentation is
measured separately and is not subject to the ordinary-suite ceiling.
