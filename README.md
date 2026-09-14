# runpod-ollama-fleet — Step 4 extraction seed

This seed creates the new **RPOF (`runpod-ollama-fleet`)** repository without changing the active `local-model-eval` RunPod path yet.

It is intentionally a behavior-preserving extraction from the frozen pre-refactor baseline:

- source repository: `local-model-eval`
- source commit: `2e34ccfdf0a6e4f6de97ddea8c1876fe489ba839`
- architectural contract owner: `adventure-finder`
- split contract: `docs/LOCAL_MODEL_EVAL_SPLIT_CONTRACT_v0.1.md`
- AFIO ↔ RPOF interface: `docs/AFIO_RPOF_INTERFACE_v0.1.md`

## Step-4 scope

This seed imports only the provider-control-plane implementation and deterministic tests assigned to RPOF by the frozen split contract. It deliberately does **not** import AdventureFinder experiment, qualification, backlog, scoring, or result-interpretation code.

The copied Ruby implementation keeps the historical `LocalModelEvaluation` namespace and `lme-runpod-*` helper names for migration compatibility. Those names are compatibility surface, not the target architecture.

The active LME operator workflow is **not switched over by this seed**. That cutover is the next bridge step, after this extracted suite is green. This avoids a flag-day change and avoids using paid RunPod calls as a debugging technique.

## Seed an empty repository

From an empty checkout at `/Users/davidnorris/code/runpod-ollama-fleet`:

```bash
unzip ~/Downloads/runpod-ollama-fleet-step4-seed-v0.1.zip -d /Users/davidnorris/code/runpod-ollama-fleet
cd /Users/davidnorris/code/runpod-ollama-fleet
./script/import-frozen-lme
./script/verify-frozen-import
bundle install
bundle exec rake test
```

The importer reads the exact frozen Git objects from the existing local checkout at `/Users/davidnorris/code/local-model-eval`. Override that only when necessary with `LME_SOURCE_REPO=/path/to/local-model-eval`.

## Transitional operator entry point

`bin/rpof` exposes the extracted helper families without claiming the AFIO-facing v0.1 bridge is already complete:

```text
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

`dispatch-legacy` is intentionally named as such because the frozen AFIO-facing `capability-check` + `dispatch` JSON contract belongs to the bridge step, not this extraction seed.

## Safety

No command in `script/import-frozen-lme` or `script/verify-frozen-import` contacts RunPod or creates paid infrastructure. The imported provider helper commands retain their existing confirmations, dry-run behavior, cost caps, managed-pod deletion checks, leases, and fail-closed behavior from the frozen source.
