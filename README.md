# runpod-ollama-fleet (RPOF)

**RPOF (`runpod-ollama-fleet`)** is AdventureFinder's current/default supporting
infrastructure for optional RunPod/Ollama remote compute. It owns provider mechanics,
fleet lifecycle/state, readiness, leases/cost safety, bootstrap/tunnels, worker
replacement/scaling, and generic remote dispatch. AdventureFinder inference intent,
qualification, production-workload semantics, and result interpretation remain in
**AFIO (`af-inference-orchestrator`)**.

The AFIO ↔ RPOF boundary is CLI + versioned machine-readable files. The frozen v0.1
interface is defined by the AdventureFinder architecture contracts.

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

The historical extraction can still be reproduced from the renamed AFIO checkout,
which retains the predecessor Git history and frozen source commit:

```bash
cd /Users/davidnorris/code/runpod-ollama-fleet
./script/import-frozen-lme
./script/verify-frozen-import
bundle install
bundle exec rake test
```

By default the importer reads the exact frozen Git objects from the sibling
`af-inference-orchestrator` checkout. Override that only when necessary with
`LME_SOURCE_REPO=/path/to/source-checkout`. The `LME_SOURCE_REPO` name is retained
as a migration-compatibility identifier.

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

`capability-check` + `dispatch` are the frozen AFIO-facing v0.1 JSON interface.
`dispatch-legacy` and the `lme-runpod-*` executable names remain compatibility
surfaces for pre-split workflows.

## Safety

No command in `script/import-frozen-lme` or `script/verify-frozen-import` contacts RunPod or creates paid infrastructure. The imported provider helper commands retain their existing confirmations, dry-run behavior, cost caps, managed-pod deletion checks, leases, and fail-closed behavior from the frozen source.
