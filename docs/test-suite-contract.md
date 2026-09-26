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

This baseline was measured before coverage became the canonical functional
safety-sweep run. Three coverage-instrumented spot checks on the same hardware
completed the Minitest portion in 3.949 s, 4.025 s, and 4.238 s, showing no
material runtime penalty.

## Whole-suite runtime ceilings

The canonical coverage-instrumented functional suite is protected by absolute
wall-clock ceilings measured with a monotonic clock.

- warning threshold: 5.0 s
- hard failure threshold: 5.5 s

When a parallel AdventureFinder workspace test marks the process with
`AF_TEST_CONTENDED=1`, the runtime guard automatically applies the fixed
`TEST_RUNTIME_CONTENTION_MULTIPLIER` of 1.25. That makes the contended thresholds
6.25 s warning / 6.875 s hard failure. Direct `rake` and serial workspace runs
retain the calibrated 5.0 s / 5.5 s limits. The multiplier accounts for deliberate
cross-repository resource contention; it does not redefine the isolated baseline.

`rake test:coverage` runs the full functional suite once with SimpleCov
enabled. That single run simultaneously enforces functional correctness, the
line/branch coverage ratchet, and the runtime ceiling.

## Default safety sweep

Plain `rake` runs the complete `test:contract` safety sweep in two stages.

1. `test:coverage` runs by itself first. It is the canonical functional test
   execution and enforces correctness, coverage, and runtime without competing
   with other health checks.
2. After it passes, `test:health` runs test-file independence and structural
   Minitest lint checks in parallel.

The default sweep is quiet on successful secondary checks. In an interactive
terminal, a single in-place spinner shows that the parallel health phase is
still running; redirected output prints one plain progress line instead. Its
final health summary is:

```text
test:lint: <N> files inspected, no offenses detected
test:deps: no broken dependencies found
```

If either secondary check fails, its captured diagnostic output is printed
before the safety sweep fails. The raw `rake test:lint` and `rake test:deps`
tasks remain available when detailed successful output is desired.

`rake test` remains available when only the fast uninstrumented product suite
is desired.
