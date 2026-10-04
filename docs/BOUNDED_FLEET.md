# Bounded fleet operator workflow

`bin/rpof bounded-fleet` is a convenience layer over the existing RPOF
campaign, parent budget, independent guardian, paid-start safety gate,
supervised controller, generation-bound worker bring-up, and dynamic registry.
It does not define another fleet lifecycle or budget authority.

The workflow is:

```text
bounded-fleet preview
        ↓
bounded-fleet start --authorize-paid
        ↓
existing supervised campaign controller
        ↓
provider create / tunnel / bootstrap / exact capability verification
        ↓
dynamic-worker-registry READY publication
        ↓
bounded-fleet view
```

## Explicit bounded intent

Preview and start take the same required intent:

- `--campaign-id` and `--profile-id`;
- one exact `ollama-capability-request/v0.1` file;
- `--desired-workers` and immutable `--max-workers`;
- `--max-hourly-rate-usd`;
- `--max-cumulative-compute-usd`;
- `--max-runtime-seconds`;
- `--guardian-poll-seconds`;
- `--heartbeat-timeout-seconds`; and
- `--teardown-reserve-seconds`.

The current RPOF hardware qualification file selects the pre-authorized model
profile. An optional `required_gpu_id` inside the generic capability request
narrows that existing qualified set. No fallback across providers or GPUs is
performed.

RPOF derives a single-profile `rpof-capacity-campaign/v0.1` declaration and its
matching `rpof-capacity-campaign-budget/v0.1` declaration. The required campaign
minimum is the conservative value `1`; campaign and profile worker maxima are
the operator's same explicit `--max-workers` ceiling. The budget ID is derived
deterministically from the campaign ID. The capability request is canonicalized
without adding aliases, workload/batch IDs, provenance, provider state, or
budget fields.

For example, with an existing exact capability request:

```bash
bin/rpof bounded-fleet preview \
  --campaign-id production-fleet-a \
  --profile-id qwen27 \
  --capability-request /absolute/path/qwen27-capability.json \
  --desired-workers 1 \
  --max-workers 2 \
  --max-hourly-rate-usd 2.00 \
  --max-cumulative-compute-usd 5.00 \
  --max-runtime-seconds 3600 \
  --guardian-poll-seconds 5 \
  --heartbeat-timeout-seconds 30 \
  --teardown-reserve-seconds 120
```

Use the identical options with `start --authorize-paid` to authorize the paid
path. Preview creates no retained authority, guardian, controller, tunnel,
registry publication, provider resource, or inference request. It shows the
exact capability fingerprint, campaign/binding identities, qualified hardware,
limits, deadline derivation, billing scope, and maximum crash-horizon compute
liability at the hourly ceiling. The live paid-start gate remains deliberately
unevaluated until the original authority and independent guardian exist and
current provider pricing can be observed.

## Start, restart, and retained authority

Start first retains the derived campaign, budget, and canonical capability
artifacts under the RPOF state root. It then delegates to the existing
`campaign start --authorize-paid` path. That path alone binds and arms the
parent budget, establishes or verifies the independent guardian, evaluates the
FO-08 safety report, and launches or attaches the supervised controller. The
controller alone owns provider reconciliation, tunnels, bootstrap, exact
capability verification, and READY publication.

Retained files are addressed by campaign ID. A repeated identical invocation
reuses byte-identical artifacts and the existing campaign/budget authority. A
conflicting campaign, budget, hardware identity, capability, or limit fails
closed. Exact partial initialization can be completed on retry; malformed or
conflicting retained artifacts are not rewritten. Existing campaign semantics
continue to reject ambiguous arm state, expired original deadlines, unhealthy
guardians, pending liability above the cumulative cap, and closed campaigns.
Neither CLI restart nor controller restart derives a fresh deadline or budget.

## Attached read-only view and explicit teardown

After a successful start, attach with:

```bash
bin/rpof bounded-fleet view \
  --campaign-id production-fleet-a
```

The view repeatedly composes the existing read-only campaign status. It reports
desired capacity, provider-active and pending workers, bootstrap and tunnel
evidence, registry READY, hourly rate, cumulative liability/cap, deadline,
controller, guardian, teardown reason, and provider-absence evidence as
separate facts. `--once` renders one snapshot; `--interval SECONDS` controls the
attached refresh interval.

Ctrl-C stops only the view. The original controller, guardian, budget,
deadline, desired capacity, provider resources, tunnels, and WLO execution are
unchanged. Paid teardown remains an explicit existing campaign operation. The
start command prints the exact retained paths needed for it:

```bash
bin/rpof campaign stop \
  --campaign <retained-campaign.json> \
  --budget <retained-budget.json>
```

Teardown is not complete until later status reports `CLOSED` with provider
absence verified. WLO execution remains separate; this interface never reads
WLO execution storage, schedules jobs, infers worker demand, or stops WLO.
