# Generation-bound worker bring-up v0.1

RPOF exposes a controller-callable `WorkerBringupReconciler` prerequisite for
automatic worker bring-up. It advances one exact worker generation through
tunnel, bootstrap, and capability evidence, then stops with
`readiness_prerequisites_satisfied`. It does not create provider resources or
publish a worker as READY.

The durable identity binds the campaign identity SHA, profile, logical worker
slot, provider resource, worker ID, monotonically increasing worker generation,
generation ID, tunnel target, and exact `ModelRequirement` fingerprint. A
different generation or exact requirement receives a different identity and
cannot reuse retained evidence. Advancing the worker generation marks every
stage of the prior identity stale and prevents it from becoming current again.

State is stored below `worker-bringup-v0.1/<worker-id>/`. Each identity has an
immutable-name JSON record, while a locked and atomically replaced `current`
pointer selects the active generation. Stage statuses are `not_started`,
`in_progress`, `passed`, `failed_retryable`, `failed_terminal`, and `stale`.
This lets a restarted controller reconstruct progress without remembering that
it launched a child process.

Tunnel evidence must match the exact provider resource, worker, generation,
and endpoint. Bootstrap attempts are persisted before launch. An in-progress
attempt must retain its attempt ID and a process identity containing PID,
process group, operating-system start token, and command fingerprint. PID or
process-name matching alone is not sufficient. A vanished or ambiguous process
fails closed and is not silently relaunched; retryable bootstrap state advances
only when the caller explicitly requests a retry.

Passed bootstrap and capability evidence must match the worker generation and
the exact model, digest, context, full-residency requirement, and constrained
GPU when present. The human alias remains provenance only.

`campaign start` now accepts a repeatable exact-requirement binding:

```console
bin/rpof-campaign campaign start CAMPAIGN.json \
  --model-requirement PROFILE_ID=MODEL_REQUIREMENT.json
```

Every campaign profile requires one binding. The supervised controller request
persists the artifact path, artifact SHA-256, and semantic requirement
fingerprint, and validates them before controller/provider startup and again in
the restarted controller. A retained older controller request is rejected
rather than adopted without this binding.

FO-11 will supply the production adapters and compose this primitive with
provider-capacity reconciliation and dynamic-registry READY publication.
Replacement policy and later lifecycle behavior remain outside this contract.
