# RunPod shutdown lifecycle

RPOF owns the complete paid-capacity campaign lifecycle and the mechanics and
provider verification for retiring RunPod capacity. WLO owns only generic
workload terminal state. A WLO pause, stop or crash does not retire provider
capacity; the RPOF campaign's independent guardian continues enforcing its
original limits and teardown policy. Older AFIO terminal handoffs below
describe historical managed fleets, not the current AFW-to-WLO production
path.

## Historical AFIO terminal gate

An older AFIO campaign could arm a terminal gate after reaching a terminal
result. Legacy v0.2 WLO/RPOF executions used a WLO-owned paid budget and
capacity session; that path is compatibility-only. Managed fleets use a
five-minute continuous-idle window by default:

```text
RUNNING
  -> AFIO terminal handoff
TERMINAL-PENDING 05:00
  -> inference activity resets the idle timer
  -> bin/rpof keep FLEET cancels this terminal event
  -> five continuous inactivity minutes
DRAINING
  -> new work on selected workers is blocked
  -> already-running inference may finish
  -> idle workers are deleted and provider absence is verified
  -> still active after ten minutes: DRAIN TIMEOUT / INPUT REQUIRED
```

`bin/rpof status --all` renders the pending countdown, drain timeout, and exact
copy/paste `keep` or force command whenever operator input is relevant.

A new terminal event may be armed after a prior `keep`; `keep` is not a permanent
lifecycle exemption. Configure a fleet as `persistent` when automatic terminal
retirement should be disabled entirely. Unconfigured fleets default to
`managed`, not persistent.

## Operator commands

Graceful shutdown starts draining immediately:

```bash
bin/rpof shutdown --fleet batch31-qwen35-main --all
```

Target individual workers with `--workers 1,4,8`.

Cancel a pending or timed-out lifecycle shutdown with the short keep command:

```bash
bin/rpof keep batch31-qwen35-main
```

Force shutdown is deliberately harder to invoke:

```bash
bin/rpof shutdown --fleet batch31-qwen35-main --all --force
```

`--force` requires a real interactive terminal and an explicit lowercase `y`.
There is no `--yes` bypass. It may interrupt active inference.

Graceful shutdown never automatically escalates to force. If inference remains
active for the ten-minute drain timeout, RPOF leaves the workers alive and
DRAINING, reports `DRAIN TIMEOUT` in aggregate status, and requires operator
input.

## Provider verification and idempotence

Shutdown stops managed tunnels, requests provider deletion, and waits until the
pod no longer appears in RunPod's live pod list before RPOF marks the worker
destroyed or clears the current fleet pointer. Failure to verify provider
absence is a failed shutdown, not success.

Repeated shutdown is idempotent: already-absent pods are accepted and reconciled
into terminal RPOF state. Worker and fleet records retain their teardown reason.

## Relationship to cost control

For a production capacity campaign, campaign stop or guardian enforcement is
the normal shutdown path. Manual and historical managed-fleet controls remain
additional backstops:

1. RPOF campaign stop/guardian, historical AFIO terminal gate, or operator shutdown
2. ephemeral idle or unavailable reaping
3. soft runtime/spend drain
4. hard runtime/spend teardown

`keep` only cancels the workload-lifecycle shutdown gate. It does not override a
hard lease or runtime cost policy.
