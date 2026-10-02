# Paid campaign start safety proof

`bin/rpof campaign start --authorize-paid` does not create a provider resource
until one authoritative `rpof-capacity-campaign-safety-report/v0.1` evaluates to
`PASS`. The report is derived from the immutable campaign binding, its existing
parent-budget ledger, current guardian runtime evidence, and the full projected
start. It is returned in start JSON and emitted before the first provider
mutation (human output on stdout; a compact `paid_start_safety_gate` JSON event
on stderr when `--json` is selected).

The gate refuses paid start when it cannot prove positive finite worker, hourly,
cumulative-compute, runtime, guardian-poll, heartbeat-timeout, and teardown
limits; the original unexpired absolute deadline; an ARMED mutation-ready
ledger; a fresh independent launchd guardian whose runtime budget/binding
identity matches; or a projected worker/rate/liability total within the durable
authority. A missing projected provider rate is a refusal, not a warning.

The binding is persisted before arm, `ARMING` remains sticky after an ambiguous
arm result, and resume must reuse the original `armed_at_utc` and
`deadline_at_utc`. The report is read-only: it does not refresh either guardian
or orchestrator heartbeats and cannot widen the authority. Every subsequent
create, scale, or replacement still makes a durable reservation before the
provider call.

## Compute-liability derivation

The single ledger calculation used by reporting and admission is:

```text
crash_horizon_seconds =
  guardian_poll_seconds
  + orchestrator_heartbeat_timeout_seconds
  + teardown_reserve_seconds

maximum_additional_compute_usd =
  active_plus_pending_hourly_compute_usd
  * crash_horizon_seconds
  / 3600

committed_maximum_compute_liability_usd =
  accrued_compute_usd + maximum_additional_compute_usd
```

The poll term covers the worst point in the guardian cadence before it observes
a stale orchestrator heartbeat; the heartbeat term is the durable liveness
window; and the teardown term is the shared provider-deletion/absence-verification
window. Pending and ambiguous reservations accrue conservatively from their
reservation time at their full reserved rate. Replacement overlap therefore
is not free capacity.

This is a conditional host-side compute bound, not a provider-side total-spend
cap. It applies while the guardian is running on an awake host and can reach
RunPod, issue successful deletion, and verify absence within the reserved
window. Launchd restarts a crashed guardian while the user service is
available, but the formula does not prove an upper bound on launchd restart
latency. The report therefore says explicitly that it does not guarantee the
modeled horizon through launchd/user-service loss, host power loss or reboot
before service restoration, sleep, network loss, provider API failure, delete
failure, or unverifiable provider state. Such failures retain teardown and
failure evidence; they do not justify a false `CLOSED` or provider-absence
claim.

## Billing scope

The cap is exactly **RunPod pod compute represented by catalog/observed pod
hourly cost and recorded in the campaign ledger**. It is deliberately named a
cumulative compute cap in the frozen declarations and safety output.

The campaign attaches a pre-existing Global Volume; it does not create or own
that volume and guardian teardown does not delete it. Pod creation also requests
container-disk storage. RPOF has no pricing/accounting input for container or
persistent-disk storage, pre-existing network or Global Volume storage,
snapshots/retained storage, network/egress, billing granularity, taxes, credits,
or other provider charges. Those charges are not proven bounded by the campaign
ledger and may continue outside its compute cap.

## Failure-domain summary

| Event | Enforcement result |
| --- | --- |
| Campaign CLI, WLO, initiating agent, shell, or terminal exits | Guardian and original authority continue. |
| Guardian process exits while launchd/user service remains available | Launchd is configured to restart it; restart latency is not included as an independently proven bound. |
| launchd/user service unavailable | No compute-loss guarantee. |
| Host sleeps, loses power, or reboots before service restoration | No compute-loss guarantee. |
| Host loses network or RunPod API is unavailable | Teardown retries and evidence remain; no finite deletion-time guarantee. |
| Provider delete fails or resource cannot be listed/probed | No absence claim and no `CLOSED`; no finite deletion-time guarantee. |

WLO consumes READY workers but owns none of this budget, guardian, deadline, or
teardown authority.

## Direct compatibility commands

Direct `create`, `fulfill`, scale-up, and replacement are not campaign-grade
automation. Their detached lease watchdog is not launchd-supervised and does
not provide the campaign identity/failure-domain proof. Consequently their
`--yes` automated paid forms are blocked. Interactive direct creation and
fulfillment require both finite runtime and spend lease values; interactive
scale-up/replacement requires the existing fleet to carry both. Read-only dry
runs and scale-down/teardown remain available. Production automation must use
an authorized campaign start.
