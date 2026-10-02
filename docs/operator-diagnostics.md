# Operator diagnostics

`bin/rpof doctor pod A2`, `fleet A`, and `campaign` provide short read-only
explanations over retained RPOF evidence. Add `--json` for the complete
structured result. Pod bootstrap evidence is available with `--logs --lines
15`; the maximum is 200 lines and known provider/API/AWS/bearer-token forms are
redacted.

Pod handles reuse aggregate-status aliases (`A1`, `A2`, and so on). Canonical
worker and pod IDs are accepted by RPOF itself. Every form must resolve to one
current retained worker identity; stale or ambiguous input fails closed.

Stages are `provider_creation`, `tunnel`, `bootstrap`,
`capability_verification`, `registry_publication`,
`paid_start_safety_gate`, `guardian`, `teardown`,
`provider_absence_verification`, `healthy`, and `unknown`. Stage precedence uses
the existing lifecycle/readiness fields. Campaign safety refusal consumes the
last report retained by FO-08 admission; it does not recompute the proof.
Unhealthy results contain one safe action identifier and healthy results none.

Doctor reads local fleet, bootstrap, publisher, campaign, guardian, and
teardown artifacts. It does not contact RunPod, probe inference, publish a
registry revision, refresh a guardian heartbeat, bootstrap a worker, or mutate
capacity.
