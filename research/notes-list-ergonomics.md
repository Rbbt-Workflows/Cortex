# List-ergonomics implementation notes (2026-08-29)

## What changed (commits 11a4c44, 2d82798, 700080b)

### D8 — model-facing schema was empty where it mattered
`desc` bodies live in `lib/Cortex/tasks/*.rb` and flow into
`task_info[:description]` → `LLM.task_tool_definition`. At HEAD `5aa3d48`
every entity/list tool exported **empty descriptions**; only the `input`
descriptions existed, and `entity`'s said "or a JSON array", actively
endorsing the inline-array habit.

Fixes (commit `11a4c44`):
- `cortex_entity_property`: `desc` added (list-first first sentence);
  `list` input re-declared **before** `entity`, description now carries the
  address format (`<entity_type>/<list>`), the `cortex_write_list` /
  `cortex_list type=lists` pointers, and "Preferred over entity for any
  multi-entity work".
- `entity` input: "Single entity identifier"; multi-entity work is pointed
  at named lists.
- `cortex_write_list` / `cortex_read_list`: `desc` added ("canonical way to
  run a property over multiple entities", redeclare=replaces).
- `cortex_list` / `cortex_search`: `desc` added; both now present
  `lists`/`properties` as the check-before-run step.

### D9 — guidance note instead of silent acceptance
`cortex_entity_property` now returns `note:` in the receipt when `entity`
parses as an inline JSON array of more than 3 members: it still executes,
but the receipt names `cortex_write_list` + `list:` and `cortex_list
type=lists` as the canonical path. Scalar and ≤3-member arrays: no note.
Two registry-suite tests assert both branches (37 tests / 154 assertions
green).

All description text is static; no tool description contains workspace
inventory, so the stable-prefix cache property is preserved.

## Suites after the change (all green, `BWRAP=false`)
- entities 24/105 · property_registry 37/154 · lists 9/30 · storage ·
  workspace 31 checks.

## Socialized before/after trials (see `after-trials.md`)
Harness: delegate the same prompt through the real `Cortex/continue`
chat_task to a `Worker`, then classify every `cortex_entity_property`
call in the worker's `log/agent.chat`.

- **Before** (surface at `5aa3d48`): 0/3 trials opened with a named list;
  4 inline-array calls, 1 discarded `cortex_property_define`, 1
  agent-created list only as a failure fallback.
- **After**: 3/3 trials checked or created the list before executing;
  4 `list:` executions, 0 inline arrays.

## Shared blocker found by both conditions (D10, engine, out of scope here)
The trial property `TF/len` declares **no arguments**, so
`cortex_entity_property(..., arguments: {treatment: ...})` raises
`ScoutException` from `entity_validate_arguments!`
(`lib/Cortex/entities.rb:1241`) — by design: only declared arguments may be
passed. Verified with a probe: declaring `treatment` on the property makes
the identical call succeed; a bogus extra argument on either property still
fails. This is why the trials' workers could not complete the task in
either condition — it is orthogonal to list ergonomics and should be
handled by (a) defining real AGS properties with declared arguments, or
(b) a separate decision on whether undeclared-argument rejection should
soften to a warning. Not changed in this pass.
