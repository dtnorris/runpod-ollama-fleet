# RPOF Capacity Campaign Budget v0.1

`rpof-capacity-campaign-budget/v0.1` binds exactly one validated
`rpof-capacity-campaign/v0.1` identity to one existing RPOF parent budget and
independent guardian. It is an authority declaration, not a provider plan, and
does not create or select paid resources.

The required declaration fields are:

- `campaign_identity` and `campaign_identity_sha256`: the exact DW-04 campaign
  declaration and hardware-qualification binding;
- `budget_id`: the durable parent budget identity;
- `max_cumulative_compute_usd`: finite total compute authority;
- `max_aggregate_hourly_rate_usd` and `max_workers`: copies of the immutable
  DW-04 campaign ceilings;
- `max_runtime_seconds`: the one runtime used to derive the original absolute
  deadline;
- `guardian_poll_seconds`, `orchestrator_heartbeat_timeout_seconds`, and
  `teardown_reserve_seconds`: independent enforcement and conservative
  teardown timing.

Unknown fields fail closed. All numeric limits must be positive and finite,
the heartbeat timeout must be at least twice the guardian interval, and the
worker/rate ceilings must exactly match the campaign declaration. The
canonical normalized JSON bytes are SHA-256 hashed. That binding hash becomes
the existing `RunpodBudget` plan identity, so its ledger, guardian launchd
identity, reservations, and provider-absence evidence all belong to the same
campaign authority. The ledger request uses
`rpof-capacity-campaign-parent-budget/v0.1`; legacy
`afio-production-burst-budget/v0.1` declarations retain their existing exact
shape and behavior.

## Durable arm and resume

The binding is stored under an address derived only from `campaign_id`. That
makes a changed campaign hash, hardware-qualification hash, budget ID, or limit
collide with and be rejected by the original durable record instead of opening
a second ledger. Its phases are:

- `BOUND`: immutable authority persisted; no arm attempt has started;
- `ARMING`: guardian/ledger arm began but the final result is not yet durable;
- `ARMED`: the independent guardian was loaded, probed, heartbeating from a
  different process, and the parent ledger reported mutation-ready.

`ARMING` is deliberately sticky after an error. A retry must inspect the
ledger/guardian evidence; it cannot silently create or arm a new identity. An
`ARMED` resume reuses the same parent ledger and verifies the persisted
`armed_at_utc` and `deadline_at_utc`. Neither is recalculated.

## Capacity authority and crash liability

Status exposes the immutable cumulative, hourly, worker, and deadline limits;
active plus pending worker count; active plus pending reserved rate; and any
over-limit condition. Pending reservations count as possible paid capacity,
so replacement overlap is not free capacity.

The conservative post-controller-crash horizon is:

`guardian_poll_seconds + orchestrator_heartbeat_timeout_seconds + teardown_reserve_seconds`

Maximum additional compute liability is the current active-plus-pending rate
times that horizon divided by 3600. The existing parent ledger adds that value
to accrued compute and rejects durable reservations above the cumulative cap.
The independent guardian continues heartbeat evaluation and teardown after the
campaign-starting process exits. Guardian teardown errors are retained in the
parent ledger until a later retry verifies provider absence and closes it.

Before the first paid mutation, campaign start now evaluates the authoritative
[`rpof-capacity-campaign-safety-report/v0.1`](PAID_START_SAFETY.md). The report
uses this same ledger calculation (rather than a second estimate), proves the
guardian runtime identity matches the budget/binding, includes the full
projected start, and fails closed on any missing proof. It also states the
conditional enforcement failure domain and the compute-only billing scope.

`mutation_authority!` and `reserve_capacity_mutation!` prove the original
binding and reject projected worker, hourly-rate or cumulative-liability
widening. Campaign start and later scale or replacement mutations use that
authority, and the operator CLI reports the same durable budget and guardian
state. WLO has no API that can reset, widen or replace this authority.
