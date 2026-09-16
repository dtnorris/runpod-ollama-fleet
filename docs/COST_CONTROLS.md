# RunPod runtime cost controls

RPOF's existing per-fleet lease remains the final hard breaker. Runtime cost
controls add a second, opt-in layer for graceful draining, ephemeral-worker
reaping, aggregate dispatch admission, and cost visibility.

Nothing changes until `bin/rpof cost enable` is run.

## Recommended production pattern

For a persistent production fleet, use soft limits to stop assigning new jobs
between inference requests and hard limits as the final emergency teardown:

```bash
bin/rpof cost configure \
  --fleet batch31-qwen35-main \
  --lifecycle persistent \
  --soft-max-runtime-minutes 60 \
  --hard-max-runtime-minutes 75 \
  --soft-max-spend-usd 5.00 \
  --hard-max-spend-usd 6.00
```

At a soft limit the fleet enters `draining`: already-running inference is not
interrupted, but capability checks and dispatch stop admitting new jobs. Once
all active workers are idle, the watchdog tears the fleet down. A hard limit
still destroys active workers immediately.

Runtime/spend thresholds are measured from the first watchdog observation of
the current fleet generation, so applying a policy to an already-running fleet
does not retroactively consume the new budget.

## Ephemeral helper fleets

Ephemeral fleets also reap workers that stay idle or unavailable. Defaults are
180 seconds idle and 90 seconds unavailable:

```bash
bin/rpof cost configure \
  --fleet batch31-qwen35-copytest \
  --lifecycle ephemeral \
  --soft-max-runtime-minutes 30 \
  --hard-max-runtime-minutes 40
```

Override the defaults when a helper fleet should disappear faster:

```bash
bin/rpof cost configure \
  --fleet batch31-qwen35-copyextra \
  --lifecycle ephemeral \
  --idle-timeout-seconds 120 \
  --unavailable-timeout-seconds 60 \
  --soft-max-runtime-minutes 20 \
  --hard-max-runtime-minutes 30
```

## Aggregate runtime cap

Set the normal aggregate managed-rate ceiling and start the local watchdog:

```bash
bin/rpof cost enable --max-total-hourly-usd 5.00 --poll-seconds 15
```

Exceeding this runtime cap blocks new dispatch and drains queued dispatch work
between jobs; it does not interrupt a request already in flight. The hard
per-fleet lease remains the emergency breaker. Existing `--max-runtime-minutes`
and `--max-spend-usd` leases are still hard-stop controls; set them at or beyond
the cost policy's hard thresholds so they do not preempt graceful drain.

For a deliberate short provisioning/copy burst, raise the runtime cap with an
automatically expiring override instead of permanently changing the normal
limit. Provisioning still honors its own `--max-total-hourly-usd` cap; the
runtime policy can only tighten that cap, never silently raise it. When the
burst intentionally exceeds the normal provisioning cap, raise both explicitly:

```bash
bin/rpof cost override --max-total-hourly-usd 6.75 --minutes 20
# and pass --max-total-hourly-usd 6.75 to the corresponding create/scale/fulfill command
```

## Visibility and audit

```bash
bin/rpof cost status
bin/rpof status --all
```

Aggregate status reports productive ACTIVE rate separately from idle,
unavailable, and unknown burn. Automatic drain/destroy actions are appended to:

```text
output/runpod-fleets/cost-events.jsonl
```

Each event records fleet key/id, worker indices, action, timestamp, and teardown
reason.

Disable runtime enforcement explicitly with:

```bash
bin/rpof cost disable
```
