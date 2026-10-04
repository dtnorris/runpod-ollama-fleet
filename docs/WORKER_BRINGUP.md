# Generation-bound worker bring-up v0.1

RPOF composes the controller-callable `WorkerBringupReconciler` into the FO-09
campaign controller. After provider-capacity reconciliation, it advances one
exact worker generation through tunnel, bootstrap, and capability evidence.
The controller then publishes a dynamic-worker-registry snapshot; READY is
possible only when the durable state says `readiness_prerequisites_satisfied`.

The durable identity binds the campaign identity SHA, profile, logical worker
slot, provider resource, worker ID, monotonically increasing worker generation,
generation ID, tunnel target, and exact Ollama capability fingerprint. A
different generation or exact capability receives a different identity and
cannot reuse retained evidence. Advancing the worker generation marks every
stage of the prior identity stale and prevents it from becoming current again.

State is stored below `worker-bringup-v0.1/<worker-id>/`. Each identity has an
immutable-name JSON record, while a locked and atomically replaced `current`
pointer selects the active generation. Stage statuses are `not_started`,
`in_progress`, `passed`, `failed_retryable`, `failed_terminal`, and `stale`.
This lets a restarted controller reconstruct progress without remembering that
it launched a child process.

Tunnel evidence must match the exact provider resource, worker, generation,
and endpoint. Bootstrap attempts are persisted before launch. The production
adapter starts the existing bootstrap command as a nonblocking owned process so
the campaign controller can continue its heartbeat. An in-progress attempt
retains its attempt ID and a process identity containing PID, process group,
operating-system start token, and command fingerprint. PID or process-name
matching alone is not sufficient. A restarted controller adopts an exact
matching process/evidence record. A vanished or ambiguous process fails closed
and is not silently relaunched.

Passed bootstrap and capability evidence must match the worker generation and
the exact model, digest, context, full-residency requirement, and constrained
GPU when present. No alias or other provenance enters the generic request.

`campaign start` accepts a repeatable exact-capability binding:

```console
bin/rpof campaign start --campaign CAMPAIGN.json --budget BUDGET.json \
  --capability-request PROFILE_ID=OLLAMA_CAPABILITY_REQUEST.json
```

Every campaign profile requires one binding. The supervised controller request
persists the artifact path, artifact SHA-256, and semantic capability
fingerprint, and validates them before controller/provider startup and again in
the restarted controller. Historical v0.2 AF-shaped retained state is loaded
only by the explicit compatibility reader, is never accepted as new input, and
is not rewritten in place.

Desired zero performs no provider or bring-up work. Lower desired counts do not
drain already retained workers. Every tunnel launch, bootstrap launch,
capability transition, and registry publication rechecks current campaign
authority; teardown prevents later stages and publication. Generation changes
make the prior tunnel, bootstrap, capability, and READY evidence ineligible.

The deterministic hard-offline acceptance check is:

```console
bundle exec bin/rpof-worker-bringup-acceptance
```

It exercises one authorized start through automatic READY using fakes only and
does not contact RunPod, open tunnels, call Ollama, pull models, or run
inference. Replacement and downscale policy remain outside FO-11.
