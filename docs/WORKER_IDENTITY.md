# RPOF worker identity

RPOF persists two provider-neutral identities in authoritative fleet state for
the frozen `dynamic-worker-registry/v0.1` contract:

- `worker_id` identifies one logical worker slot within one RPOF fleet. It is
  deterministic from the durable fleet identity and numeric slot, never from a
  mutable display name.
- `generation_id` identifies one concrete incarnation of that slot. It is
  deterministic from `worker_id`, RPOF's monotonically increasing generation,
  and the provider pod ID. It is persisted rather than rebuilt during registry
  publication.

## Lifecycle rules

| Event | `worker_id` | `generation_id` |
| --- | --- | --- |
| Repeated observation of the same pod | unchanged | unchanged |
| Bootstrap process restart | unchanged | unchanged |
| Tunnel process or local-port restart | unchanged | unchanged |
| Explicit replacement in the same slot | unchanged | changed |
| Scale down, then recreate the same slot in the same fleet | unchanged | changed |
| Endpoint or local-port reuse by replacement capacity | unchanged | changed |
| Destroy the fleet and create a new fleet | changed | changed |
| Destroy a worker without replacement | worker disappears | generation disappears |

The generation counter is part of `generation_id`, so an explicit recreation
rotates generation identity even if a provider unexpectedly returns a repeated
pod identifier. Endpoint and local-port values never participate in identity,
so their reuse cannot hide replacement.

## Fail-closed projection

Registry publication must call `RunpodFleetState#registry_identity` with the
provider pod ID observed by current readiness/tunnel evidence. Projection is
rejected when that observation is missing or differs from authoritative fleet
state. Schema-v2 fleet state is also rejected if either identity is absent or
does not match the durable slot, generation counter, and provider pod evidence.

Schema-v1 historical state is intentionally not upgraded or reinterpreted.
Cost-safe destruction remains available, but identity-sensitive replacement,
scale-up, and registry publication fail until the fleet is destroyed and
recreated. This prevents an old attempt from being attributed to replacement
capacity through a guessed identity.

DW-02 should use this projection seam while assembling the rest of each worker
record from current generation-specific readiness, tunnel, bootstrap, and model
evidence. DW-03 does not publish snapshots or manage registry revisions.
