# Dynamic worker registry v0.1

Status: frozen public WLO provider API for `dynamic-worker-registry/v0.1`.

`workload-orchestrator` owns this normative contract and its canonical valid
and invalid fixtures. Worker publishers such as LOW and RPOF implement this
interface independently; WLO consumes their snapshots for generic scheduling.
AFW owns workload capability requirements and does not read this registry. A
consumer must not read publisher-specific local runtime, provider fleet, pod,
tunnel, bootstrap, or lease state to recover information omitted here.

The canonical valid fixture is [`minimal-valid.json`](minimal-valid.json).
Canonical invalid fixtures are under [`invalid/`](invalid/). Independent
publishers may retain byte-identical conformance copies without becoming API
owners. Changing any field meaning, required field, enum, matching rule, or
fingerprint input requires a new contract version; v0.1 rejects unknown fields.

[`conformance.rb`](conformance.rb) is the standalone executable reference
validator for this wire contract. It uses only the Ruby standard library and
does not load WLO application or scheduling code. `INVALID_EXPECTATIONS.tsv`
records the intended rejection reason for every canonical invalid fixture.
`SHA256SUMS` pins the public corpus files; a provider may copy this directory
and verify it from its own checkout, but the copy remains non-authoritative.

Validate a snapshot directly with an optional explicit evaluation time:

```text
ruby conformance.rb SNAPSHOT.json [NOW_RFC3339]
```

## Snapshot shape

JSON names and enum values are case-sensitive. Objects contain exactly the
fields specified below. Required fields cannot be `null`.

| Field | Requirement |
| --- | --- |
| `contract_version` | Exact string `dynamic-worker-registry/v0.1`. |
| `registry_id` | Stable publisher namespace matching `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`. It must not encode an ephemeral fleet or campaign generation. |
| `revision` | Non-negative integer, strictly increasing for each `registry_id`. A publisher must durably advance it before making a newer snapshot visible. |
| `published_at` | UTC RFC 3339 timestamp in canonical second precision (`YYYY-MM-DDTHH:MM:SSZ`). |
| `expires_at` | Same format and strictly later than `published_at`. A snapshot is stale and unusable at or after this instant. |
| `workers` | Array of worker records. It may be empty. `worker_id` values are unique within the registry. |

A consumer remembers the greatest accepted revision for each `registry_id` and
rejects rollback, reuse of a revision with different bytes, future-dated
snapshots, malformed timestamps, and expired snapshots. An explicitly
configured clock-skew allowance may be used for `published_at`, but it cannot
extend `expires_at`. Publication must be atomic: partial JSON is malformed and
therefore supplies no eligible workers.

## Worker shape

Every listed worker contains exactly:

| Field | Requirement |
| --- | --- |
| `worker_id` | Stable provider-neutral logical identity within `registry_id`; same identifier syntax as `registry_id`. It may survive restarts or replacement of the capacity occupying that logical slot. |
| `generation_id` | Opaque nonempty string of at most 256 characters identifying one concrete worker incarnation. Replacement, reprovisioning, or any change that could let endpoint reuse address different capacity requires a new value. It must never be synthesized from `worker_id` alone. |
| `endpoint` | Absolute `http` or `https` Ollama base URL with a nonempty host and no user info, query, or fragment. The path is empty or `/`; consumers remove one trailing `/` before requests. Credentials do not belong in the registry. |
| `state` | One of `READY`, `NOT_READY`, or `UNAVAILABLE`. Only `READY` can be eligible. |
| `labels` | Sorted, unique array of nonempty strings. These are provider-neutral scheduling capabilities, not provider placement metadata. |
| `capabilities` | Exact capability object defined below. It records the evidence attached to this generation, even when the worker is not currently ready. |
| `capability_fingerprint` | Lowercase 64-hex SHA-256 of the canonical capability payload below. |

`READY` is an aggregate scheduling assertion: at publication time the concrete
generation exists, its endpoint is reachable and healthy, and every advertised
capability is backed by current generation-specific evidence. `NOT_READY`
means the generation exists but that assertion is not currently proven (for
example booting, unhealthy, or missing current evidence). `UNAVAILABLE` means
the generation cannot currently accept work. The distinctions within those
non-ready states are diagnostic only; both are ineligible. Omitting a former
worker is also equivalent to unavailable for new dispatch.

The identity of a dispatch binding is the five-tuple
`(registry_id, worker_id, generation_id, endpoint, capability_fingerprint)`.
WLO must persist that complete tuple on an attempt before dispatch. A later
snapshot cannot rewrite it. In particular, the same endpoint with a different
`generation_id` is a replacement worker, while a changed endpoint or
capability fingerprint under the same generation is a new binding that must
not be silently substituted into an existing attempt.

## Capabilities and fingerprint

`capabilities` contains exactly:

| Field | Requirement |
| --- | --- |
| `gpu_id` | Nonempty provider-neutral hardware/runtime identity string, at most 256 characters. It is compared exactly only when the workload supplies `required_gpu_id`. |
| `ollama.models` | Sorted, nonempty array of model records with unique `model` values. Sort by the tuple `(model, digest, context_length, fully_gpu_resident)`. |

Each model record contains exactly:

- `model`: nonempty Ollama runtime model identity, at most 256 characters;
- `digest`: lowercase exact 64-hex model digest;
- `context_length`: positive integer for the proven loaded runtime context; and
- `fully_gpu_resident`: boolean describing the proven loaded runtime model.

The canonical fingerprint payload has exactly these keys in this order:

```json
{"gpu_id":"NVIDIA A40","labels":["inference","ollama","remote"],"ollama_models":[{"context_length":131072,"digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fully_gpu_resident":true,"model":"qualified-model:latest"}]}
```

It is UTF-8 JSON with no insignificant whitespace or trailing newline. Labels
and models use the sorting rules above; model object keys appear exactly in the
shown order. `capability_fingerprint` is the lowercase SHA-256 hex digest of
those bytes. The canonical fixture fingerprint is
`2995693d958654b0074ed25377b7e0a82f06b78c8411f71dcc0b4f9a0a7ea621`.

Identity, generation, endpoint, state, timestamps, and registry revision are
deliberately not fingerprint inputs. They remain independent binding and
freshness checks and must not be inferred from the capability fingerprint.

## Eligibility and fail-closed behavior

For an AFW/WLO Ollama pool, a worker is eligible only when all of the following
are true:

1. the complete snapshot and worker record validate as v0.1, the revision is
   not a rollback, and the snapshot is unexpired;
2. `state` is exactly `READY`;
3. every required label is present;
4. one advertised model has an exact case-sensitive `model` match, exact
   lowercase digest match, and exact `context_length` match;
5. if `require_fully_gpu_resident` is present, it is `true` in the plan and the
   model record is exactly `true`; and
6. if `required_gpu_id` is present, it exactly equals `capabilities.gpu_id`.

No alias, digest prefix, context rounding, higher-context substitution,
residency inference, or label inference is permitted. A missing requirement in
the plan does not require that optional comparison, but every registry field
remains structurally required.

Unknown fields, duplicate identities, duplicate or unsorted labels/models,
missing fields, invalid scalar types, an invalid endpoint, a bad fingerprint,
or internally inconsistent timestamps invalidate the entire snapshot. A
consumer may retain the last previously accepted unexpired snapshot; it must
not salvage records from the invalid replacement. Missing, stale, malformed,
or non-ready records are ineligible. If an already-bound generation disappears
or changes, WLO retains the attempt's original binding and classifies any
result/transport outcome under its existing execution rules; it never makes
the attempt appear to have run on the replacement.

## Deliberate deferrals

This contract does not define polling transport, source configuration,
authentication, publisher election, dynamic scheduling, claims, attempts,
retries, provider lifecycle, campaigns, budgets, leases, cost, or production
execution. WLO's runtime may consume multiple independently versioned registry
streams, but it preserves each stream's `registry_id`, revision, snapshot hash,
and checkpoint rather than publishing a merged registry. This contract also
does not replace the existing AFW → WLO execution-plan or historical
execution-profile compatibility contracts.
