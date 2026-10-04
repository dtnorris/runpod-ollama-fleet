# rpof-capacity-planning-evidence/v0.1

RPOF-owned read-only, advisory evidence for an existing armed campaign budget.
No evidence result is mutation permission. Real acquisition must repeat the
existing safety gate, reservation, provider mutation and commit protocol.

```
bin/rpof planning-evidence --campaign campaign.json --budget budget.json \
  --state-root /absolute/retained/root --profile-id qwen35 \
  --capability-request exact-capability.json --proposed-workers 3 --json
```

The API is `RunpodOllamaFleet::CapacityPlanningEvidence.new(binding:, profile_id:,
capability_request:, client:, clock:).document(proposed_workers:)`. CLI JSON is
always emitted; exit 0 means evidence was produced, **not** that admission is
possible. Invalid identity/input/retained authority returns exit 1. The CLI
uses `RUNPOD_API_KEY` for the existing read-only catalog endpoint only.

`proposed_workers` is an Integer in 1..1,000,000: the absolute target for the
selected profile. Zero is rejected: this interface does not preview retirement.
Counts above retained profile/campaign maxima produce refused evidence. Existing
active resources and pending/ambiguous reservations in every profile are counted.
Additional workers = max(proposed profile count - committed profile count, 0).
No projected retirement reduces either committed workers or their current rate.

Identity fields: contract_version, read_only, observed_at_utc, campaign_id,
campaign_identity_sha256, binding_sha256, budget_id, profile_id and exact generic
capability_fingerprint. The declaration and retained binding/ledger identities,
limits and original arm/deadline are verified; nothing is bound or armed here.
Authority includes unchanged declared limits, profile maximum, original absolute
deadline, active/pending counts, committed profile count/rate, accrued compute,
committed maximum liability and remaining uncommitted compute authority. The
nested existing authority-preview deadline describes derivation; the actual
retained absolute deadline is `authority.original_deadline_at_utc`.

Each candidate exposes rank, GPU ID, cloud, authorized, eligible, FO-15 rejection
reason, observed hourly rate, price_status, availability, provider_availability,
projected aggregate rate and admission_preview. Only immutable hardware binding
IDs are considered; required_gpu_id narrows them to exactly one. Qualification
and deterministic cheap-first ordering are the same `AuthorizedCandidates.observe`
used by FO-15. Ineligible candidates remain visible. No live inventory expands
hardware authority. Catalog failure leaves rank null, retained IDs visible and
no eligible candidates; lexical identity ordering then makes no ranking claim.

Price status is observed, unavailable or invalid. A finite positive observed
rate can coexist with a qualification rejection; `eligible` and `reason` must
also be checked. Missing/invalid rates are null, never defaults or historical
substitutes. Availability is reported_available, unavailable or unknown, with
the provider classification alongside it. This is the catalog's one-GPU
observation, not a reservation, guarantee or proof of proposed-count capacity.

Per-candidate preview states are admissible_under_current_authority,
not_admissible and insufficient_evidence. Every preview has reasons and
mutation_permission=false. The existing CampaignBudgetBinding.safety_report is
included, providing worker/hourly/cumulative/deadline/guardian checks, crash
horizon arithmetic, enforcement assumptions and billing exclusions. The profile
maximum is checked additionally. Missing guardian/safety evidence or price is
insufficient evidence unless a known hard bound already refuses the proposal.
Top-level status succeeds if any candidate passes, otherwise reports insufficient
evidence if any candidate is unresolved, else not_admissible. Reasons retain
candidate-specific detail; success never selects a candidate.

Projection = committed campaign hourly compute + additional workers * observed
candidate rate. Projected maximum liability = accrued compute + projected rate *
existing FO-08 crash horizon / 3600. This is RunPod pod compute only, **not** a
total provider bill or an AdventureFinder completion-time estimate. Existing
safety-report billing and guardian enforcement limitations remain authoritative.

Reads take existing shared locks without creating directories or lock files.
They never reserve liability, heartbeat, arm, retain a safety report, write desired
capacity, read or mutate consumer/fallback state, publish a registry, contact
provider create/delete, or inspect WLO storage. Catalog and authority are
point-in-time observations, not an atomic provider/ledger transaction. Detected
commitment changes during observation refuse a successful preview. Real admission
must always recheck current state. Missing or mismatched retained authority fails
closed. Repeated previews leave retained bytes and directory entries unchanged.

FO-21C owns AdventureFinder composition; FO-21D owns real proposal selection and
proof of entry into the existing mutation path. Neither is part of this contract.
