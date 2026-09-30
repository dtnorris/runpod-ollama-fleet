# runpod-ollama-fleet (RPOF)

**RPOF (`runpod-ollama-fleet`) is a provider-capacity manager and dynamic
worker-registry publisher.** It owns optional RunPod/Ollama provider mechanics:
fleet resources/state, readiness and bootstrap, tunnels, leases and cost
safeguards, provider scaling/replacement, campaign lifecycle, and worker
capability publication.
**AFW (`af-workloads`)** owns AdventureFinder workload intent, qualification,
frozen scoring and result interpretation. **WLO (`workload-orchestrator`)** owns
generic scheduling and execution state: placement, attempts, retries,
pause/resume and breakers. **RPOF owns the paid-capacity campaign lifecycle,**
including cumulative and hourly limits, deadlines, worker ceilings, the
independent guardian, provider replacement and teardown. The production WLO
path discovers RPOF capacity through the provider-neutral worker registry and
executes selected work itself; it does not ask RPOF to schedule or dispatch
jobs. Stopping WLO does not stop or widen a campaign. Operators use `bin/rpof`
directly for campaign and fleet administration.

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
./script/import-frozen-lme
./script/verify-frozen-import
bundle install
bundle exec rake test
```

The scripts default to the current sibling path `../af-workloads`, whose Git
history must retain the frozen predecessor commit. `LME_SOURCE_REPO` is a
migration-compatibility variable; use it to select another historical checkout
only if that checkout contains the exact frozen commit.

## Operator entry point

`bin/rpof` exposes the current capacity/registry interface:

```text
bin/rpof campaign plan|start|status|stop ...
bin/rpof workers --json
bin/rpof create ...
bin/rpof destroy ...
bin/rpof bootstrap ...
bin/rpof lease ...
bin/rpof scale ...
bin/rpof replace ...
bin/rpof status ...
bin/rpof tunnels ...
```

DW-33 removed `dispatch`, `dispatch-admit`, `dispatch-close`, `dispatch-legacy`
and `execution-pool-fulfill`, including their direct executables and workload
orchestration modules. Frozen `afio-rpof` contract validators remain available
for audit; historical dispatch artifacts are not runnable through current code.
Read-only `capability-check` and capacity-only `fulfill` remain supported.

`bin/rpof workers --json` emits a short-lived
`dynamic-worker-registry/v0.1` snapshot. This is the provider-neutral worker
discovery seam for consumers such as WLO; consumers do not read RPOF fleet,
bootstrap, tunnel, or provider state directly. Only records marked `READY` are
eligible for new work.

`RPOF_STATE_ROOT` and `RPOF_STATE_REPO_ROOT` select the same state namespace
for `workers --json` and `status --all` (also single-fleet status).

## Safety

No command in `script/import-frozen-lme` or `script/verify-frozen-import` contacts RunPod or creates paid infrastructure. The imported provider helper commands retain their existing confirmations, dry-run behavior, cost caps, managed-pod deletion checks, leases, and fail-closed behavior from the frozen source.
