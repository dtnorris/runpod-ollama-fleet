# RunPod Desired Capacity Contract v0.1

Status: accepted normative RPOF-owned control-plane contract.

Contract identifier:

```text
rpof-desired-capacity/v0.1
```

This contract separates mutable desired worker counts from the immutable
campaign and budget authority that permits provider capacity. It does not
define a reconciliation controller.

The central rule is:

> Declared pools may have zero workers; desired-capacity changes retain one
> original campaign authority, parent budget and absolute deadline.

## Compatibility boundary

`rpof-capacity-campaign/v0.1` is frozen. Its profile validation continues to
require positive `min_workers`, `desired_workers` and `max_workers`, and its
campaign hash continues to include those fields. Implementations must not
reinterpret or rewrite historical v0.1 declarations.

For a v0.1 campaign without a persisted desired-capacity document, its declared
`desired_workers` values remain the effective desired counts exactly as before.
RPOF exposes those values as a deterministic compatibility baseline at desired
revision 0. The baseline is not persisted and does not alter campaign identity.
The first explicit desired-capacity mutation writes revision 1 and opts that
campaign/budget binding into this separate mutable-state contract.

`min_workers` is not part of mutable desired state. It remains frozen historical
input in the v0.1 campaign declaration and does not make a new desired count of
zero contradictory. The mutable contract expresses operator intent only;
future reconciliation policy is outside this version.

## Fixed authority and mutable intent

The immutable authority remains the composition of:

- the validated capacity campaign and its identity SHA;
- the hardware-qualification binding;
- the campaign budget declaration and binding SHA;
- the original parent budget ID;
- profile and campaign worker maxima;
- the aggregate hourly-rate ceiling;
- the cumulative compute ceiling;
- the maximum runtime and original absolute deadline;
- exact model, digest, context and full-GPU-residency requirements; and
- qualified GPU/cloud authority.

Desired state contains only authority references, revision metadata, mutation
provenance and one non-negative desired count for every authorized profile. A
desired document must not contain model, digest, context, residency, GPU,
cloud, worker-max, hourly-rate, cumulative-compute, runtime, deadline or billing
scope fields. Exact-key validation rejects such attempted authority widening.

A desired count of zero means:

- no new worker is requested for that profile;
- the profile remains present in immutable authority;
- its nonzero authorized maximum and exact model/runtime/hardware requirements
  remain unchanged;
- existing capacity is not implicitly drained, removed or destroyed; and
- a later desired increase may exercise the same original authority.

## Stored document

Every persisted document has exactly these root fields:

| Field | Type | Meaning |
| --- | --- | --- |
| `contract_version` | string | Exactly `rpof-desired-capacity/v0.1`. |
| `campaign_identity_sha256` | 64-character lowercase SHA-256 | Exact immutable campaign identity reference. |
| `binding_sha256` | 64-character lowercase SHA-256 | Exact campaign-budget binding reference. |
| `budget_id` | string | Exact original parent budget ID. |
| `revision` | positive integer | Monotonically increasing persisted revision. |
| `previous_sha256` | 64-character lowercase SHA-256 | SHA-256 of canonical JSON for the immediately preceding desired document. Revision 1 references the deterministic revision-0 baseline. |
| `updated_at_utc` | string | Canonical whole-second UTC timestamp `YYYY-MM-DDTHH:MM:SSZ`. |
| `reason` | string | Non-empty operator mutation reason. |
| `profiles` | non-empty array | Complete desired count set, sorted by `profile_id`. |

Every profile row has exactly:

| Field | Type | Meaning |
| --- | --- | --- |
| `profile_id` | string | An existing profile in immutable campaign authority. |
| `desired_workers` | non-negative integer | Current intent, from zero through that profile's immutable `max_workers`. |

Every authorized campaign profile must occur exactly once. Unknown, duplicate
or missing profiles fail closed. Desired counts above the immutable profile
maximum fail closed. The aggregate campaign maximum remains enforced by
ordinary mutation admission; this contract cannot increase it.

RPOF inspection output may decorate the stored document with calculated
`sha256` and `persisted` fields. They are view metadata, not stored contract
fields.

## Revision and concurrency semantics

Revision 0 is the deterministic compatibility baseline:

- it uses the v0.1 campaign declaration's desired counts;
- `previous_sha256` and `updated_at_utc` are null;
- its reason is `rpof-capacity-campaign/v0.1 initial desired capacity`; and
- it is readable without creating filesystem state.

Each mutation supplies the current expected revision. Under one exclusive
desired-state lock, RPOF must:

1. load and validate the current document or revision-0 baseline;
2. compare the supplied expected revision with the current revision;
3. fail closed on any mismatch;
4. apply requested profile-count changes to the complete profile set;
5. validate every resulting count against immutable authority;
6. retain the previous document hash;
7. write the next retained revision durably; and
8. atomically replace the current document.

Two writers presenting the same expected revision cannot both succeed. A stale
expected revision fails even when its requested counts now match current state.
An identical request presented against the current revision is idempotent: it
returns current state without incrementing revision or appending history. The
later reason does not rewrite the provenance of the accepted state.

A failed current-file replacement must leave the prior current document valid.
A retained next-revision file without a matching current replacement is
ambiguous evidence and must block reuse of that revision rather than being
silently overwritten. Malformed current/history documents, missing retained
history or a broken previous hash fail closed.

## Budget and deadline invariants

A desired-capacity update must leave all of these byte-for-byte or
value-for-value unchanged:

- campaign identity SHA;
- budget ID;
- budget/binding SHA;
- parent `armed_at_utc`;
- original parent `deadline_at_utc`;
- maximum cumulative compute;
- maximum aggregate hourly rate;
- maximum workers;
- maximum runtime;
- accrued compute;
- committed resources; and
- pending or ambiguous reservations and their liability.

No desired mutation, resume, zero-to-positive transition or compatibility
baseline may arm a second parent budget or establish a new runtime horizon. If
the original deadline is expired, desired state remains readable and may record
intent, but existing paid-mutation admission must reject a later increase. A new
campaign authority requires a separate explicit operation outside this
contract.

Desired capacity is not reserved spend. A count does not reserve workers or
money. Every later provider mutation still passes the existing durable
reservation path, guardian/identity checks, committed-plus-pending worker and
hourly-rate accounting, cumulative-liability check, and original-deadline
check. Pending or ambiguous liability cannot be discarded because desired
capacity was lowered.

## Lifecycle and provider effects

Reading or updating desired state is control-plane work only. It must perform:

- zero provider create calls;
- zero provider delete calls;
- zero provider list calls;
- zero model downloads;
- zero inference calls; and
- zero implicit add, drain, remove or stop reconciliation.

Campaign plan/start/status may consume one validated desired revision. Campaign
status must keep desired, provider-active, registry-READY and maximum counts
distinct and must expose the desired contract version, revision and original
deadline. A campaign start may add missing capacity only through the ordinary
paid admission path. This contract does not define downward reconciliation.

The independent guardian remains the safety enforcer and teardown owner. It is
not a desired-capacity controller and must not watch this document to create or
remove workers. Provider reconciliation belongs to the existing campaign controller/lifecycle,
documented in [Capacity campaigns](../../../docs/CAPACITY_CAMPAIGN.md);
it is not performed by desired-state reads or updates.

## Required refusal conditions

At minimum, RPOF fails closed for:

- unsupported contract version;
- unknown or extra document fields;
- campaign identity, binding SHA or budget ID mismatch;
- negative, non-integer or above-maximum desired count;
- unknown, duplicate or missing profile;
- non-positive persisted revision;
- stale expected revision;
- missing or invalid previous hash;
- malformed or non-canonical timestamp;
- empty or malformed mutation reason;
- missing/mismatched retained revision history; and
- an already-retained different document for the proposed next revision.

These refusals do not authorize a replacement campaign, replacement budget or
new deadline.
