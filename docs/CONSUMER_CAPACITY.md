# FO-16 consumer-bound campaign capacity

FO-16 is opt-in. An unbound campaign retains its existing desired-capacity behavior.
Bind an immutable `rpof-consumer-binding/v0.1` JSON document using:

```text
bin/rpof campaign consumer-bind --campaign CAMPAIGN --budget BUDGET \
  --consumer-binding BINDING --state-root ROOT --json
```

This records intent only: no provider access or paid authorization. Repeating an
identical binding is idempotent; conflicting identity/configuration fails closed.
Binding and reconciliation share the existing campaign capacity-control lock,
including manual generation-bound FO-14 controls.

## Binding fields

Root fields are `contract_version`, exact `campaign_identity_sha256`, exact
`binding_sha256`, nonnegative integer `idle_grace_seconds`, and `profiles`.
Every campaign profile must appear exactly once. Each row contains:

| Field | Meaning |
| --- | --- |
| `profile_id` | Exact retained campaign profile |
| `consumer_id` | WLO public execution identity, 64 hex |
| `plan_sha256` | Exact WLO public plan identity, 64 hex |
| `pool_id` | Exact public demand pool |
| `capability_request` | Complete normative Ollama request object |
| `source_argv` | Absolute executable plus arguments returning public demand JSON |

The capability request is validated against campaign profile and hardware
qualification. Demand identity and semantic fingerprint must match the binding.
The consumer command must be read-only; use WLO's `consumer-demand` command.
Arguments are passed without a shell. Source failure, timeout, oversized or
invalid response, wrong identity, future/stale observations, and missing heartbeat
are not proof of quiescence. The command timeout is five seconds. Observations
and active heartbeats must be no more than 30 seconds old.

## Effective target and original authority

For fresh active demand:

`effective_target = min(operator_desired, runnable_count + bound_count)`

Otherwise the target is zero. WLO's bound count is whole-execution conservative;
it may retain more capacity than a per-worker allocation view would. No private
attempt mapping crosses the boundary.

The target only lowers FO-13 intent; it never changes that intent, campaign maxima,
hourly/cumulative ceilings, budget identity, deadline, or guardian authority.
Provisioning still passes through existing admission and FO-15 cheap-first
fallback. A stopped/expired campaign cannot be revived by later consumer demand.

## Retained grace and retirement

When current capacity exceeds target, RPOF durably records the first release
deadline. Restart does not reset it. Recovery before drain cancels grace when
the target again covers existing capacity. An already drained generation is not
silently made READY again; recovery suppresses automatic retirement while the
capacity is required. Manual FO-14 control remains available.

After grace, exact excess generations are drained through FO-14. Its publication
lock captures an expiry watermark in the generation's lifecycle before future
placement can advertise it READY. Publisher state retains the maximum expiry
across publications and TTL changes. Later config changes cannot shorten or
restart an established drain watermark. A subsequent reconciliation needs a
public WLO observation strictly newer than this watermark, with zero bound and
uncertain attempts and explicit quiescence, before requesting removal.

Removal and provider-absence verification remain FO-14 owned. No blind shrink,
generation substitution, or duplicate provider delete is introduced. Historical
publisher history without the new watermark is unknown: automatic retirement
remains blocked rather than inventing an expiry bound.

Paused, completed, failed, stale, or missing demand starts release toward zero.
Running, interrupted, or uncertain remote attempts (including archived attempts)
prevent automatic retirement. Missing consumer proof may leave workers drained
until the original campaign/guardian deadline tears down paid resources; demand
never extends that deadline. This is conservative retention, not indefinite
authority and not a claim that a cancelled local process ended remote work.

## Offline verification

```text
bundle exec ruby -Itest test/consumer_capacity_test.rb
bundle exec ruby -Itest test/campaign_lifecycle_test.rb
bundle exec ruby -Itest test/availability_fallback_test.rb
bundle exec ruby script/test-fo16-consumer-demand /path/to/workload-orchestrator
bundle exec rake
```

The external composed harness loads both repositories only in test code. It
checks public demand, READY placement, preserved running work through drain,
pause, missing source, completion, restarted retention, verified retirement,
campaign admission/deadline/stop, shared locking, and the fallback loop. Provider
and bring-up adapters are offline fixtures. Production RPOF invokes public JSON
commands; it does not read WLO execution, job, lock, or attempt files.
