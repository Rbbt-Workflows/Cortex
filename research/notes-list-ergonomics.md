# Probes: description plumbing & agent-facing schema (2026-08-25, extended 2026-08-29)

## P1 — Where do tool descriptions come from?

Executed probe: `desc` before `task` populates `task_info[:description]`, which
`LLM.task_tool_definition` places in `definition[:description]`. Confirmed live
with a temporary desc in a task file (`desc` in `lib/Cortex/tasks/*.rb` before
`task`):

```
probe task description: "List entity property executions: ..."
```

**Finding D8 (diagnosis confirmed):** after the README migration milestone
removed all inline `desc` blocks, no `desc` exists anywhere for the
entity/list/listing tasks. Every exported tool therefore has an empty
description in the JSON schema the model sees:

```
cortex_entity_property: nil
cortex_write_list: nil
cortex_read_list: nil
cortex_list: nil
cortex_search: nil
cortex_read: nil
cortex_property_list: nil
```

The model-facing surface is input descriptions only, and those teach the wrong
pattern:

- `entity`: "Entity identifier, **or a JSON array of identifiers**" — the
  inline-array path is the first documented multi-entity option, in input
  position 3, before `list`.
- `list` exists but comes after `entity`, has no worked example in a tool
  description, and nothing says a list must be *created first*.
- `cortex_write_list` has an empty description, so nothing links it to property
  execution.

Matches observed usage: 0/136 calls used `list:`; 10 inline arrays; sets
smuggled via `arguments`.

## P2 — List anomaly resolution

Two historical `cortex_write_list` calls exist (`TF/valid`, `TF/dynamic-505`,
plus `Composite/P3-C01`). They are not in the current workspace because those
runs predate the current workspace or used probes that were cleaned up; the
write path itself is verified live (probe wrote `TF/probe-list` and
`cortex_list` lists it).

**D9 — resolved: not a defect (stale cached job), plus one real CLI footgun.**

`scout workflow task Cortex cortex_list --type lists` printed `lists 0/0
entries` while the on-disk workspace and the same job built from Ruby showed
`TF/probe-list current 3`. Root cause: the CLI job is content-addressed
(`Default_<digest>`), and a *cached* result from an earlier `cortex_list`
run (produced when the probe list did not exist / under a different anchor)
was being served. Deleting the cached job files made the CLI immediately
print the correct listing:

```
$ rm ~/.scout/var/jobs/Cortex/cortex_list/Default_fb85280e7398ebb8fb4d78475763b54e*
$ scout workflow task Cortex cortex_list --type lists --log 0
lists	1/1 entry
  #name	map	entities	mtime
  TF/probe-list	current	3	17	2026-08-29 11:38
```

Anchor resolution is correct in both venues: `chat_anchor` returns the repo
both under `SCOUT_CHAT_DIR` and via the PWD marker climb, and
`namespace_entries(:lists)` finds the file in both. No fix needed in the
storage layer.

Genuine footguns found (documentation fixes, not engine fixes):

1. The `-t` short flag: the historical `Unknown Cortex namespace type "true"`
   error shows `-t lists` is parsed as a boolean flag (value `true`), not as
   `type`. Agents must use `--type`. Document explicitly.
2. `cortex_list` results are content-addressed and cached: a freshly written
   list may not appear until the listing job is cleaned/updated. Document
   ("use `--update`, or expect cached listings within the same job digest").

## Conclusion of the probe phase

The fix belongs in the model-facing layer: `desc` blocks for
entity/list/listing tasks + reordered/reworded inputs + runtime guidance for
large inline arrays. Engine is correct. D9 resolved as above.
