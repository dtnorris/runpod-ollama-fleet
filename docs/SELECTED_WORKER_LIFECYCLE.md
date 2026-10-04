# Explicit campaign capacity controls (FO-14)

Use the retained campaign, budget, hardware and state root from the original
start. This also works for the retained declarations created by bounded-fleet
start. Do not start another campaign to change capacity.

All examples below append the same `--campaign FILE --budget FILE --hardware
FILE --state-root DIR` arguments. These controls never pause or cancel WLO.

| Operation | Command suffix | Effect |
| --- | --- | --- |
| Inspect | `status --json` | Desired revision, provider/registry counts, exact worker identities, lifecycle revision/history, error and next action |
| Increase target | `add --profile qwen35=2 --expected-revision 3 --reason 'operator add'` | Absolute target, not a delta; FO-13 CAS plus existing authority/projection checks; controller creates later |
| Drain | `drain --profile-id qwen35 --fleet-id F --worker-id W --generation-id G --pod-id P --expected-revision 0 --reason 'operator drain'` | Persist exact-generation drain; no provider call or delete |
| Reduce intent | `desired-set --profile qwen35=1 --expected-revision 4 --reason 'retire capacity'` | Existing FO-13 operation; does not itself delete a worker |
| Request retirement | `remove --profile-id qwen35 --fleet-id F --worker-id W --generation-id G --pod-id P --expected-revision 1 --reason 'operator confirmed' --confirm-remove` | Require prior drain and lower desired target; persist request for supervised removal |
| Stop | `stop --reason 'operator stop'` | Existing parent-budget teardown; controller disabled, guardian remains authoritative; CLOSED requires absence proof |

Use current values from status; example revision numbers are illustrative.
Desired revision and selected-worker lifecycle revision are separate. Identical
requests at the current revision are no-ops. Stale revisions always fail, even
for repeated requests. Retry a busy control request after the controller pass.

## Drain continuity

The existing registry contract's `UNAVAILABLE` state removes future placement
eligibility while preserving worker identity. Drain captures the last published
worker record under the registry publication lock and retains its complete
capability evidence, endpoint, worker ID and generation. Fresh snapshots change
only its state. No WLO-specific fields are added. A generation that has never
been published stays unpublished during drain.

Consumers observe drain through their next fresh registry poll. Previously
accepted snapshots are not remotely revoked. Within the same publication second,
a changed worker set fails closed rather than replaying a cached READY snapshot
or fabricating a future timestamp. Later publication keeps the same registry ID
and advances the revision. Continue publishing while a drained attempt finishes;
WLO's normal source-expiry rules still apply.

Removal is explicit operator authorization that the selected generation may be
deleted. RPOF never decides that an attempt finished, queries WLO, or infers busy
or idle state. The operator must arrange workload completion separately before
confirming removal when completion is required.

## Retained state and concurrency

`fleet.json` retains lifecycle state on the selected worker, with exact
`worker_id`, `generation_id`, `pod_id`, mutation ID, revision, reason and history.

| State | Recovery/next action |
| --- | --- |
| active (implicit revision 0) | Normal qualification controls READY publication |
| draining | Publish retained tuple as UNAVAILABLE; explicit remove is required |
| retirement_requested | Controller may send one delete through existing fleet lifecycle |
| delete_in_progress | Intent was persisted before delete; after restart only verify absence |
| delete_ambiguous | Keep resource liability and slot; verify absence without replaying delete |
| retired | Provider absence verified; omit registry row; retain tombstone and history |

The existing nonblocking fleet lifecycle lock serializes selected operations,
scale and replacement. The campaign capacity-control lock covers whole controller
passes, including FO-15 cleanup, and selected CLI requests. FO-13 retains its own
CAS lock. Stop/guardian authority is independent of these ordinary control locks.
Guardian destruction's state reconciliation retries if the fleet lifecycle lock
is busy; provider teardown is not held behind that metadata write.

The controller persists delete intent before calling the existing exact-ID/name
checked delete primitive. It requires provider 404 absence, not just a successful
delete response, before recording retirement. Local absence evidence precedes
ledger release; restart repairs an interrupted release. A live or ambiguous
resource is never automatically reused. Use campaign stop for guardian-owned
teardown if a delete may never have been sent and the resource remains live.

Retired slots remain attributable in fleet state, including the final slot.
A later desired increase fills retired slots through the existing replacement
primitive, which creates a fresh generation and moves old lifecycle evidence
into worker history. Old commands fail against the new generation. Slot reuse
uses the existing slot GPU qualification; it does not become FO-15 failed
candidate cleanup. Growth beyond existing slots retains FO-15 fallback.
Unresolved candidate generations cannot drain, and unresolved fallback must
settle before selected removal or slot reuse; campaign stop remains available.

## Verification and boundaries

`test/selected_worker_lifecycle_test.rb` covers registry continuity, restart,
exact selection, duplicate/concurrent requests, ambiguous deletes, absence
verification, generation reuse and structural consumer independence.
Campaign and fallback tests cover original authority, add CAS, admission gates,
lock interaction, and separation of selected retirement from candidate cleanup.

Optional composed proof against a pinned WLO checkout:

```sh
bundle exec ruby script/test-fo14-wlo-drain /path/to/workload-orchestrator
```

This external test harness alone reads WLO's persisted attempt metadata. It
binds a real WLO attempt using RPOF's produced snapshot, invokes RPOF drain,
checks that no worker is eligible for new placement, checks byte-identical
persisted attempt metadata, and completes the attempt through WLO. RPOF
production imports no WLO implementation and reads no consumer storage.
The default RPOF test suite has no sibling repository dependency.

There is no new budget/deadline authority, desired-capacity schema, automatic
consumer-demand scaling, idle release, liveness check, or WLO execution control.
FO-20 measurements remain observational and are not a correctness dependency.
