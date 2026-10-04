# Provider and cost measurements v0.1

`bin/rpof-measurements` emits the read-only
`rpof-provider-cost-measurements/v0.1` contract for one budget identity. It
uses the existing budget ledger and generation-bound FO-11 bring-up evidence.
It makes no provider calls and performs no lifecycle, admission, capacity, or
pricing mutation.

Tracked provider-resource start/stop timestamps define paid duration. Cold
start runs from provider-resource start until all FO-11 bring-up prerequisites
pass, or until a retained terminal bring-up failure. Time after prerequisites
pass is a usable-capacity estimate; it does not prove registry publication,
worker activity, or useful WLO command execution. Continuous READY and idle
intervals are not retained, so READY duration, paid-idle duration, and exact
useful-work cost remain explicitly unavailable.
The contract exposes tracked resource intervals, rates, and generic worker /
generation identity for explicit cross-owner composition. RPOF itself does not
read workload state or infer throughput.

Accrued compute and committed/pending liability come from the existing budget
accounting snapshot. Billing scope is limited to tracked RunPod compute; it is
not described as the total provider bill. Historical resources without current
bring-up timing remain readable and appear as unallocated coverage.
