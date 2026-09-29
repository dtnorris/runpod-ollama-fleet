# RPOF Capacity Campaign v0.1

`rpof-capacity-campaign/v0.1` declares bounded desired capacity for several
model profiles under one durable campaign identity. Parsing and validation are
read-only: the contract does not authorize or provision provider resources.

Required top-level fields are:

- `contract_version`: exactly `rpof-capacity-campaign/v0.1`;
- `campaign_id`: durable operator-selected identity;
- `max_workers`: aggregate worker ceiling;
- `max_hourly_rate_usd`: aggregate rate ceiling reserved for DW-06 enforcement;
- `profiles`: one or more model-capacity declarations.

Each profile requires `profile_id`, `model`, `expected_digest`,
`required_context_length`, `require_fully_gpu_resident`, `min_workers`,
`desired_workers`, and `max_workers`. Counts must satisfy
`min_workers <= desired_workers <= max_workers`. Full GPU residency must be
required. The sum of profile maxima cannot exceed the campaign maximum.

The declaration cannot select GPUs, clouds, pods, fleets, volumes, or provider
handles. RPOF resolves each model through `ExecutionPoolHardware`, then records
a separate deterministic hardware-qualification binding hash. A campaign's
lifecycle identity consists of its `campaign_id`, normalized declaration hash,
and hardware-qualification hash. This prevents provider qualification changes
from silently retaining an earlier lifecycle identity.

The campaign does not duplicate paid-budget fields. DW-05 remains responsible
for the parent cumulative-spend limit, immutable deadline/runtime lease,
guardian cadence, and crash-surviving teardown lifecycle. DW-06 will enforce
the declared aggregate worker and hourly-rate ceilings.

## Ownership boundary

Campaign `plan`, `start`, `status`, and `stop` manage provider capacity only.
They do not accept jobs, job IDs, commands, environment payloads, affinity,
attempts, or result paths, and they do not load RPOF's historical dispatch
implementation. Worker discovery is published separately through
`bin/rpof workers --json`; WLO owns assignment and execution.
