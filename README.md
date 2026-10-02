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
bin/rpof campaign plan|start|status|stop|desired|desired-set ...
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

Operator status keeps lifecycle and scheduling terms separate:

- **provider active** means provider or provider-owned fleet evidence says the
  paid resource exists/runs;
- **bootstrap passed** means current generation-specific capability evidence
  passed; it is not registry readiness;
- **tunnel established** means the recorded managed tunnel process identity is
  alive and matches the current pod/endpoint;
- **registry READY** means the frozen registry predicate also has valid
  capability evidence and a healthy current-generation endpoint;
- **compatible**, **busy**, **idle**, and WLO blocking reasons belong to WLO,
  not RPOF.

Single-fleet, aggregate, and campaign human status label these facts explicitly.
Campaign JSON retains the historical `ready_workers` field for compatibility;
its legacy meaning is provider-active fleet-state rows, recorded by
`ready_workers_legacy_meaning`. New consumers must use
`provider_active_workers` and `registry_ready_workers`.

`bin/rpof status` and `bin/rpof status --all` default to a compact pod table
bounded to 72 columns. Each worker occupies one physical line with its existing
short handle (`burst_N` or aggregate alias such as `A1`), GPU, bootstrap-qualified
model, provider state, registry state, and tracked hourly rate. `PROV=UP` means
provider `RUNNING`; it does not imply `REG=READY`. Long GPU/model values end in
`~` and remain complete in `--json` and `--verbose` output. Use `--width COLUMNS`
for wider panes; `--verbose` retains the detailed lifecycle, bootstrap, tunnel,
inference, lease, shutdown, and cost views.

For a short retained-evidence diagnosis, use `bin/rpof doctor pod A2`,
`bin/rpof doctor fleet A`, or `bin/rpof doctor campaign --campaign FILE
--budget FILE`. Add `--json` for stable structured output. Pod bootstrap evidence
is available with `--logs --lines N`; output is bounded to 200 lines and known
credential forms are redacted. Doctor is read-only: it consumes retained fleet,
registry, campaign, guardian, and teardown evidence and never contacts RunPod,
publishes a new registry revision, or changes paid capacity.

## Operator process ownership

RPOF command completion, process lifetime and provider-resource lifetime are
separate facts. The classifications below describe the invoking process:

- **FOREGROUND WORK OWNER**: the CLI owns the active local operation;
- **DETACHED WORK LAUNCHER**: continuing local subprocesses outlive the CLI;
- **ONE-SHOT INSPECTION/PUBLICATION**: the CLI reads or publishes current state
  without owning workload or paid-capacity lifecycle;
- **CONTROL REQUEST** / **RESOURCE MUTATION**: the CLI changes durable local or
  provider state but is not itself a continuing owner; and
- **TEARDOWN REQUEST**: the CLI requests deletion/retirement, whose success
  requires the command-specific provider-absence condition.

| Command | Classification | What remains after return | Ctrl-C / terminal loss | Correct lifecycle command |
| --- | --- | --- | --- | --- |
| `campaign plan`, `campaign status`, `campaign desired` | ONE-SHOT INSPECTION | Existing guardian, provider resources, tunnels and WLO execution continue. | Interrupts only the request/view. | `wlo pause` pauses work; `campaign stop` requests paid teardown. |
| `campaign desired-set` | CONTROL REQUEST | Revisioned desired state changes; the request itself makes no provider call. A running matching controller reads the accepted revision on its next pass. The original budget/deadline, guardian and WLO execution remain unchanged. | May leave either the prior complete revision or the new complete revision; interrupting it never implies provider rollback or teardown. | Inspect with `campaign desired`; use `campaign start` to ensure continuing reconciliation is supervised. |
| `campaign start` | DETACHED/SUPERVISED CONTROLLER LAUNCHER | One identity-bound launchd controller owns ordinary heartbeat and desired-capacity reconciliation after the CLI, WLO, shell, or terminal exits. The independent guardian remains the safety enforcer. | After launch, Ctrl-C affects only the initiating output/view; it does not stop the controller or capacity. | `campaign stop`, then status until `CLOSED` with provider absence verified. |
| `campaign stop` | TEARDOWN REQUEST | The budget first blocks mutation, controller supervision is disabled, and the independent guardian continues teardown after the CLI returns. | Interrupts only the requesting CLI; it does not cancel the durable teardown request or prove completion. | Re-run status/stop until provider absence is verified and the budget is `CLOSED`. |
| `workers --json`, `status`, `doctor`, `capacity`, `capability-check` | ONE-SHOT INSPECTION/PUBLICATION | Workloads, guardians, tunnels and provider resources continue. Registry publication may advance its durable revision; doctor only consumes retained evidence. Neither owns work or capacity. | Interrupts only the request. | Use WLO and RPOF lifecycle commands explicitly. |
| `create`, `fulfill`, `scale`, `replace` | MANUAL RESOURCE MUTATION | Provider resources remain; a configured lease watchdog is detached but is not campaign-grade independent enforcement. Automated `--yes` paid forms are blocked; positive manual mutations require finite runtime and spend leases. | May leave a partial or completed mutation; it is not rollback or teardown. Inspect state/provider evidence before retrying. | Use authorized `campaign start` for production automation; otherwise use `destroy` or `shutdown` as applicable. |
| `destroy` | TEARDOWN REQUEST | No selected paid worker should remain only after synchronous provider-absence verification succeeds; unrelated resources/watchdogs may remain. | Interrupting the CLI does not prove deletion. | Inspect `status`; repeat explicit teardown if required. |
| `shutdown` | TEARDOWN REQUEST | Immediate graceful/force modes own the request until verified completion; `--terminal` launches a detached shutdown watchdog. | Ctrl-C of an immediate request is not completion. After `--terminal` returns, shell Ctrl-C has no effect on its watchdog. | Inspect `status`; use `keep` only to cancel a pending lifecycle gate, not a hard lease. |
| `keep` | CONTROL REQUEST | Paid resources continue; only the pending/timed-out lifecycle shutdown gate is cancelled. | Interrupts only the request. | Use `shutdown`, `destroy` or `campaign stop` for teardown. |
| `bootstrap`, `runtime-alias` | FOREGROUND WORK OWNER | Paid resources remain. Remote/model state may be partial if interrupted. | Interrupts the CLI operation; it does not stop WLO or delete provider capacity. | Inspect evidence/readiness before retrying; use an explicit teardown command for capacity. |
| `tunnels start`, `tunnels repair` | DETACHED WORK LAUNCHER | Healthy managed SSH tunnel processes continue after the CLI returns. A Ctrl-C during start cleans up tunnels newly started by that invocation, but existing tunnels and paid workers remain. | Never pauses WLO or tears down provider capacity. | `tunnels stop` stops selected tunnels only. |
| `tunnels status`, `tunnels stop` | ONE-SHOT INSPECTION / CONTROL REQUEST | `status` leaves tunnels unchanged apart from health-state reconciliation; `stop` removes selected local tunnels but leaves paid workers alive. | Interrupts only this request. | Use provider teardown separately. |
| `lease status` | ONE-SHOT INSPECTION | The lease watchdog, provider resources and WLO continue. | Interrupts only the request. | Use the applicable provider teardown command. |
| `lease watch` | FOREGROUND WORK OWNER | When invoked directly, that watchdog is the foreground owner; `create`/`fulfill` normally launch it detached. | Ctrl-C stops only the directly invoked watchdog and leaves paid resources alive; it is not teardown. | Restore lease enforcement or explicitly tear down capacity. |
| `cost enable` | DETACHED WORK LAUNCHER | The detached cost watchdog continues after the CLI or terminal exits. | Later shell Ctrl-C has no effect. | `cost disable` stops the watchdog only; provider teardown remains separate. |
| `cost watch` | FOREGROUND WORK OWNER | The foreground watchdog enforces configured cost policy while alive. | Ctrl-C stops that watchdog, not paid resources. | `cost enable` restores detached enforcement; use explicit teardown for resources. |
| Other `cost` controls | CONTROL REQUEST / ONE-SHOT INSPECTION | Configured resources and any running watchdog continue unless `disable` explicitly stops that watchdog. | Interrupts only the request. | Provider teardown remains separate. |
| `budget arm` | DETACHED WORK LAUNCHER | The independent launchd budget guardian continues after the CLI returns. It enforces authority but is not a workload or campaign controller. | Ctrl-C does not constitute teardown and may leave arm evidence requiring inspection. | Use campaign stop/budget teardown flow and verify provider absence. |
| Other `budget` commands | CONTROL REQUEST / ONE-SHOT INSPECTION | The guardian/resources continue according to retained budget state. `begin-teardown` requests guardian-owned teardown; `close` is not a substitute for provider-absence proof. | Interrupts only the request. | Use the bound campaign teardown/status flow for production capacity. |

Across every row, `wlo pause` is the command for intentional graceful workload
pause. It does not tear down paid resources. For production campaign capacity,
`rpof campaign stop` is the teardown request, and completion requires a later
status proving provider absence and `CLOSED`. Closing a view, pressing Ctrl-C,
losing a shell or losing a terminal is never a substitute for either action.

## Paid-start safety

Authorized campaign start fails closed before its first provider mutation
unless the durable authority, projected compute liability, original deadline,
and matching healthy independent guardian produce a PASSing safety report. The
cap covers recorded RunPod pod compute only—not storage, Global Volume,
network/egress, or other provider charges—and the report states the host/network/provider
failure domain instead of claiming a provider-side hard total-spend cap. See
[`docs/PAID_START_SAFETY.md`](docs/PAID_START_SAFETY.md).

## Versioned desired capacity

`rpof-capacity-campaign/v0.1` remains frozen: its positive `min_workers`,
`desired_workers` and `max_workers` validation and identity hashing are
unchanged. RPOF overlays explicit mutable intent with
`rpof-desired-capacity/v0.1`, bound to the immutable campaign identity, budget
binding SHA and budget ID. The compatibility baseline is revision 0 and uses
the v0.1 declaration's desired counts. The first accepted update is revision 1.

`campaign desired-set` requires an expected revision, records a reason, rejects
unknown profiles and counts above each immutable profile maximum, and retains a
hash-linked revision history. A desired count of zero keeps the profile and its
model, digest, context, residency, hardware and maximum-worker authority. The
update performs no provider calls and does not reserve spend, reset the parent
budget or deadline, discard pending liability, or turn the guardian into a
desired-capacity controller. A running identity-bound controller reads the
accepted revision on every reconciliation pass and may add missing capacity
through normal admission. Lower desired counts do not delete or drain existing
capacity; those lifecycle operations remain outside this controller.

The controller is supervised by the current macOS per-user launchd session. It
survives launcher, WLO, shell, terminal, and controller-process exit while that
service is available, but does not claim host-power, reboot, sleep, network, or
provider availability. Its heartbeat cadence is the smaller of 10 seconds and
one third of the frozen orchestrator-heartbeat timeout (never below one second).

## Plan-derived model requirements

`RunpodOllamaFleet::ModelRequirement` consumes the exact JSON artifact emitted by
AdventureFinder model preflight. `CampaignRunpodRuntime` can validate it against a
campaign profile and hardware binding before any provider lookup or mutation. Model,
full digest, context, residency, and optional GPU identity must match exactly; the
human alias is retained only as provenance and is never translated by RPOF.

## Safety

No command in `script/import-frozen-lme` or `script/verify-frozen-import` contacts RunPod or creates paid infrastructure. The imported provider helper commands retain their existing confirmations, dry-run behavior, cost caps, managed-pod deletion checks, leases, and fail-closed behavior from the frozen source.
