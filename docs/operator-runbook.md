# RPOF operator runbook

RPOF owns provider capacity, campaign admission, original budget/deadline,
independent guardian enforcement, generation readiness, registry publication
and verified teardown. It neither schedules workloads nor interprets their
results. Use the chosen RPOF checkout with its installed Ruby bundle and provider
credentials. Inspect its actual HEAD and working tree before mutation.

## Inspect and establish bounded intent

For an existing campaign, use its exact public declaration paths as `CAMPAIGN`
and `BUDGET`, and its original durable root as `STATE_ROOT`. Start's output or
the composing application's registered context supplies these paths. Reuse them
throughout; do not create another campaign/budget to add or replace workers.

**Read-only / inspect:**

```bash
bin/rpof campaign plan --campaign "$CAMPAIGN" --budget "$BUDGET" --state-root "$STATE_ROOT" --json
bin/rpof campaign status --campaign "$CAMPAIGN" --budget "$BUDGET" --state-root "$STATE_ROOT" --json
bin/rpof campaign desired --campaign "$CAMPAIGN" --budget "$BUDGET" --state-root "$STATE_ROOT" --json
```

Plan does not arm authority or create resources. Status distinguishes desired,
provider-active, pending and registry-ready workers, and reports guardian,
controller, original deadline, accrued compute and maximum liability. A live pod
is not READY. Use [operator diagnostics](operator-diagnostics.md) for bounded
worker/campaign diagnosis and logs. If an original start used `--hardware FILE`,
pass that same qualification file on subsequent campaign operations.

For new single-profile capacity, [bounded fleet](BOUNDED_FLEET.md) is the public
preview/start/view entry point. Supply an exact generic capability request and
explicit worker, hourly, cumulative-compute, runtime and enforcement bounds.
Preview is read-only; it reports the crash-horizon liability at the hourly
ceiling without establishing a guardian or claiming live admission.

## Start — retained authority plus provider mutation / paid capacity

After reviewing the plan, finite maximum additional crash loss, billing scope
and independent enforcement proof, set `PROFILE_ID` and `CAPABILITY` to the
exact approved profile and generic request, then:

```bash
bin/rpof campaign start --campaign "$CAMPAIGN" --budget "$BUDGET" \
  --state-root "$STATE_ROOT" --capability-request "$PROFILE_ID=$CAPABILITY" \
  --ssh-public-key "$SSH_PUBLIC_KEY" --authorize-paid
```

Repeat `--capability-request PROFILE=FILE` for each needed profile. This is an
explicit paid operation. The supervised controller outlives the initiating CLI;
the independent guardian remains the safety/teardown owner. RPOF rechecks actual
pricing, bounded admission and reservation before provider mutation. Original
authority is reused on restart, never widened or rearmed with a fresh deadline.
Missing/ambiguous authority, unhealthy guardian or unbounded crash liability is
a stop condition. See [campaign](CAPACITY_CAMPAIGN.md),
[budget](CAMPAIGN_BUDGET.md), [paid-start safety](PAID_START_SAFETY.md) and
[worker bring-up](WORKER_BRINGUP.md).

**Registry publication — local retained-state mutation, no capacity mutation:**

```bash
RPOF_STATE_ROOT="$STATE_ROOT" bin/rpof workers --json
```

This observational publisher may persist registry identity/revision checkpoints.
It does not create capacity, warm models or execute jobs. Only verified exact
generation capability evidence can publish READY. WLO owns the public
[registry](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/dynamic-worker-registry/v0.1/README.md)
and [capability request](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/ollama-capability-request/v0.1/README.md)
contracts; RPOF operates without loading WLO implementation source.

## Planning evidence — read-only, advisory

```bash
bin/rpof planning-evidence --campaign "$CAMPAIGN" --budget "$BUDGET" \
  --state-root "$STATE_ROOT" --profile-id "$PROFILE_ID" \
  --capability-request "$CAPABILITY" --proposed-workers 1 --json
```

The count is an absolute profile target. Exit 0 means an evidence document was
produced, not capacity admitted. Every preview has `mutation_permission=false`.
The [v0.1 planning contract](../contracts/rpof-capacity-planning-evidence/v0.1/README.md)
defines identities, freshness observations, candidate prices and safety evidence.
Real acquisition must repeat RPOF admission; external ETA/proposal output cannot
raise limits, extend deadlines, replace hardware qualification or reserve a pod.

## Add, drain, remove — retained-state mutation consumed by the controller

Read current desired and worker lifecycle revisions/identities from campaign
status. Desired revision and selected-generation revision are separate.
`TARGET` is an absolute target; `REVISION` is the current desired revision:

```bash
bin/rpof campaign add --campaign "$CAMPAIGN" --budget "$BUDGET" --state-root "$STATE_ROOT" \
  --profile "$PROFILE_ID=$TARGET" --expected-revision "$REVISION" --reason "$REASON"
```

The command updates bounded intent; the controller may later create paid capacity
only through the original admission gates. To retire a selected generation,
use [selected worker lifecycle](SELECTED_WORKER_LIFECYCLE.md): drain with exact
profile/fleet/worker/generation/pod IDs and its lifecycle revision, lower desired
intent with `desired-set`, then explicitly confirm `remove --confirm-remove`.
The selected controls do not decide whether workload effects are complete.
Confirm removal only after reviewing public consumer evidence when completion
is required; never infer idle from a stale observation.

Optional [consumer-bound capacity](CONSUMER_CAPACITY.md) records an immutable
`rpof-consumer-binding/v0.1` via `campaign consumer-bind`. Its configured
read-only command returns the public `wlo-consumer-demand/v0.1` document.
Consumer identity, liveness, bound/uncertain work and post-drain expiry proof
are required by that contract. Missing proof is not zero demand or permission
to delete. Consumer binding never widens original authority.

## Stop — provider teardown request; verify completion

```bash
bin/rpof campaign stop --campaign "$CAMPAIGN" --budget "$BUDGET" \
  --state-root "$STATE_ROOT" --reason "operator requested teardown"
bin/rpof campaign status --campaign "$CAMPAIGN" --budget "$BUDGET" --state-root "$STATE_ROOT" --json
```

Stop disables ordinary capacity reconciliation and requests guardian-owned
teardown. Keep inspecting until status reports CLOSED and verified provider
absence. A successful request, closing a view, Ctrl-C, tunnel stop or WLO pause
is not teardown completion. Unresolved provider outcomes retain liability.

## Troubleshooting

Use campaign status and the public doctor/log interfaces from
[diagnostics](operator-diagnostics.md). Provider/budget/guardian/readiness and
teardown failures belong to RPOF. Missing READY evidence is distinct from
provider absence. WLO execution failures belong to the consumer's diagnostics;
RPOF does not read or repair consumer storage. Preserve ambiguous reservations
and original identities; never edit retained state or replay create/delete to
force a desired result. Stop when the public diagnostic reports unsafe admission.
