# Entity executions, annotation, and named lists — completion notes

Recovery of the two interrupted sessions, then the defect repairs needed
to make their work verifiable. All evidence below comes from executed
commands in this working tree.

## Stocktake (from the interrupted sessions)

The interrupted sessions delivered, uncommitted: the `properties/`
execution registry (engine-level recording in
`Cortex.run_entity_property`), the `lists/` namespace with
`cortex_write_list` / `cortex_read_list`, the `list` input on
`cortex_entity_property`, `annotate_receiver` (AnnotatedArray +
entity-type annotation), and test suites (`test_property_registry.rb`,
`test_lists.rb`). Two commits recorded the state:

- `e23d84b` — WIP recovery of the interrupted work (labeled unverified)
- `5d2b639` — test-side reconciliation (stale registry suite removed;
  row/examination shape fixes)

## Defects found by probing (D1–D7 from the stocktake)

- **D1 (fixed, commit `f2680d0`)**: managed entity modules did not
  declare their entity-type annotations, so `entity_options` reached
  `Entity#setup` but never survived into property bodies: the
  `entity`/`entity_list` helpers rebuild receivers from
  `inputs.to_hash`, and an annotation that is not a job input is lost.
  Probes showed `organism: "nil"` inside `:single`, `:both`, and list
  bodies while `mod.setup(...).organism` was correct.
  Fix: `entity_new_module` now declares `annotation entity_name`; the
  annotation therefore participates in job inputs and survives rebuild.
- **D3 (fixed, same commit)**: `entity_vector_job` passed raw entity
  identifiers to the job args instead of the annotated receiver, so list
  dispatch ran on unannotated arrays. Fix: fan-out and vector jobs now
  receive `annotate_receiver(...)` output, and `entity_options` are
  merged into args.
- **D2 (fixed by test-side `IndiferentHash.setup` + documented rule)**:
  result Hashes loaded from `:json` Steps arrive with string keys while
  in-process results keep symbol keys; the helper normalizes.
- **D4 (already correct after D1/D3)**: per-examination `list` field
  present on records.
- D5/D6/D7 were test-side issues fixed in `5d2b639`.

## Verification

Suites (`BWRAP=false ruby -Itest -Ilib ...`):

- `test/Cortex/test_entities.rb` — 24 tests, 105 assertions, 0 failures
- `test/Cortex/test_property_registry.rb` — 34 tests, 138 assertions, 0
  failures
- `test/Cortex/test_lists.rb` — 9 tests, 30 assertions, 0 failures
- `test/Cortex/test_storage.rb` — 10 tests, 22 assertions, 0 failures
- `test/test_cortex_workspace.rb` — SUITE: 31 passed, 0 failed, 0 errored

Scenario probes (`tmp/verify_*.rb`, `BWRAP=false ruby`):

- `verify_user_scenario.rb` — defined `TF/activity_in_experiment`, ran it
  for `FOXO1` under `PD`, `PI`, `PD_PI`:
  `ROWS=[["TF/activity_in_experiment/FOXO1","",3,"",...]]`, `EXAMS=3`,
  treatments `[["FOXO1","PD"],["FOXO1","PI"],["FOXO1","PD_PI"]]`.
- `verify_list_scenario.rb` — named list `foxo-family`:
  `LISTEX=1 list="foxo-family" runs=1`, `MEMBEREX=2`.
- `verify_reexec.rb` — re-running same arguments increments runs
  (`EXAMS=2 runsPD=2`); new arguments create a new examination.
- `verify_inline.rb` — inline JSON arrays and scalar receivers still
  work alongside named lists.
- `verify_receipt.rb` — execution record's `property_job`
  (`TF/actv/FOXO1_...json`) starts with the property Step path: the
  property Step, not the outer task, is the recorded evidence producer.

## Docs

- `README.md`: new `properties listing` section; `list:` input and
  `entity_list`/`entity_count` documented on `cortex_entity_property`;
  named-list guidance on `cortex_read_list`.
- `doc/user/WorkspaceTools.md`: workflow steps 10–11, list-first rule,
  check-before-run rule.
- `doc/developer/Entities.md`: registry layout, D1 root cause
  (annotations must be job inputs), list dispatch contract.
