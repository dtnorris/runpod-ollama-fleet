# Step 4 migration notes

## Included

The source import manifest contains the thirteen library components assigned wholesale to RPOF by the frozen split contract, the six existing provider CLI helper families, three provider-side shell helpers, and the deterministic provider-focused tests that can move without AdventureFinder experiment/backlog semantics.

## Deliberately excluded

The seed does not copy:

- `runpod_ready.rb` — bridge component; split into AFIO requirements and RPOF generic capability verification in the bridge step.
- `runpod_provenance.rb` — bridge component for the same reason.
- `bin/lme` — AFIO compatibility façade, not RPOF implementation.
- `runpod_gpu_cli_test.rb` — currently exercises `bin/lme runpod-create`; move/replace when RPOF operator create is cut over.
- `runpod_ready_test.rb` and `runpod_provenance_test.rb` — bridge tests, not wholesale RPOF tests.
- `runpod_gpu_qualification_script_test.rb` / `bin/lme-qualify-gpu` — qualification intent remains AFIO-owned.
- AdventureFinder experiments, production backlogs, scoring, source, matcher, or catalog code.

## Why the old Ruby namespace remains

Changing `LocalModelEvaluation::*` class names while also moving repository ownership would mix topology change with implementation rename. v0.1 explicitly treats these historical names as migration compatibility. Namespace cleanup can happen only after behavior and bridge evidence are green.

## Next bridge step

After this repo passes its extracted deterministic suite, implement the frozen AFIO-facing `capability-check` and `dispatch` contracts and then replace LME provider implementations with thin CLI/file-contract shims. Only after that cutover is proven should duplicated provider code be removed from LME.
