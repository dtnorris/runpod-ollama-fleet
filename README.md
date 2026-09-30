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

Historical workload dispatch remains available through `dispatch`,
`dispatch-admit`, `dispatch-close`, `dispatch-legacy`, `capability-check`, and
`execution-pool-fulfill`. These commands, their frozen `afio-rpof` contracts,
`RunpodDispatcher`, and the `lme-runpod-*` executable names are compatibility
surfaces for recoverable executions and migration rollback. New campaign and
registry code loads independently of them, and new WLO dynamic-worker
executions must not call them.

`bin/rpof workers --json` emits a short-lived
`dynamic-worker-registry/v0.1` snapshot. This is the provider-neutral worker
discovery seam for consumers such as WLO; consumers do not read RPOF fleet,
bootstrap, tunnel, or provider state directly. Only records marked `READY` are
eligible for new work.

`ExecutionPoolFulfill` is also compatibility orchestration: although it uses
legitimate provider-capacity operations underneath, it consumes the historical
execution-pool request contract and coordinates readiness for the older guarded
WLO/RPOF path. It is not part of the campaign/registry production surface.

## Safety

No command in `script/import-frozen-lme` or `script/verify-frozen-import` contacts RunPod or creates paid infrastructure. The imported provider helper commands retain their existing confirmations, dry-run behavior, cost caps, managed-pod deletion checks, leases, and fail-closed behavior from the frozen source.
