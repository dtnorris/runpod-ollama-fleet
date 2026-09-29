# runpod-ollama-fleet (RPOF)

**RPOF (`runpod-ollama-fleet`)** owns optional RunPod/Ollama provider mechanics:
fleet resources/state, readiness and bootstrap, tunnels, leases and cost
safeguards, provider scaling/replacement, and opaque dispatch primitives.
**AFW (`af-workloads`)** owns AdventureFinder workload intent, qualification,
frozen scoring and result interpretation. **WLO (`workload-orchestrator`)** owns
automatic placement, attempts, retries, pause/resume, breakers, guarded paid
capacity and workload lifecycle. WLO invokes RPOF through a CLI and versioned
JSON boundary; operators use `bin/rpof` directly for manual fleet administration.

The frozen `afio-rpof/v0.1` wire names are compatibility identifiers, not a
statement that AFIO owns present-day execution.

## Historical extraction provenance

RPOF was seeded by a behavior-preserving extraction from the frozen pre-refactor
`local-model-eval` baseline:

- historical source repository: `local-model-eval`
- source commit: `2e34ccfdf0a6e4f6de97ddea8c1876fe489ba839`
- architectural contract owner: `adventure-finder`
- split contract: `docs/LOCAL_MODEL_EVAL_SPLIT_CONTRACT_v0.1.md`
- AFIO ↔ RPOF interface: `docs/AFIO_RPOF_INTERFACE_v0.1.md`

The extracted Ruby implementation intentionally retains the historical
`LocalModelEvaluation` namespace and `lme-runpod-*` helper names as compatibility
surfaces. They are not the current repository identity.

## Reproduce the frozen extraction

The historical extraction can still be reproduced from an AFW checkout that
retains the predecessor Git history and frozen source commit:

```bash
cd /Users/davidnorris/code/runpod-ollama-fleet
LME_SOURCE_REPO=../af-workloads ./script/import-frozen-lme
LME_SOURCE_REPO=../af-workloads ./script/verify-frozen-import
bundle install
bundle exec rake test
```

The scripts still default to the historical sibling path
`../af-inference-orchestrator`. The explicit override above points them at
the current AFW checkout, which must retain the frozen predecessor commit.
`LME_SOURCE_REPO` is a migration-compatibility variable; use another checkout
only if it contains that exact commit.

## Operator entry point

`bin/rpof` exposes the current interface and retained compatibility helper families:

```text
bin/rpof capability-check ...
bin/rpof dispatch ...
bin/rpof create ...
bin/rpof destroy ...
bin/rpof bootstrap ...
bin/rpof dispatch-legacy ...
bin/rpof lease ...
bin/rpof scale ...
bin/rpof replace ...
bin/rpof status ...
bin/rpof tunnels ...
```

`capability-check` and `dispatch` retain the frozen `afio-rpof` v0.1 wire
versions used by WLO's explicit compatibility adapter. `dispatch-legacy` and
the `lme-runpod-*` executable names remain compatibility surfaces for
pre-split workflows.

## Safety

No command in `script/import-frozen-lme` or `script/verify-frozen-import` contacts RunPod or creates paid infrastructure. The imported provider helper commands retain their existing confirmations, dry-run behavior, cost caps, managed-pod deletion checks, leases, and fail-closed behavior from the frozen source.
