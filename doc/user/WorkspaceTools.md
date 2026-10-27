# Workspace Tools

This page documents the `cortex_*` workspace tools agents use to
navigate, extend, and manage the Cortex workspace. Entity support
(entity properties, named entity lists, the execution registry) now
lives in the Semantics workflow, and tracking scientific evidence is
the responsibility of the Research workflow.

**You should read this if:** you are writing prompts for agents that work
inside Cortex, or you are an agent that just got the Cortex tools.

---

## Intended workflow

1. `cortex_list` — discover workspace structure (metadata only)
2. `cortex_search` — locate potentially relevant material (snippets only)
3. `cortex_read` — inspect only the required portions (paginated)
4. `cortex_write` — create durable artifacts
5. `cortex_edit` — targeted corrections
6. `cortex_rename` / `cortex_move` / `cortex_remove` — deliberate
   management of existing resources

Rules of thumb:

- Conversations are working/reasoning space; briefs are reusable agent
  preparation; artifacts are durable research objects.
- Do not assume an artifact exists because a conversation mentions it:
  verify with `cortex_list` / `cortex_read`.
- Never rely on an important conclusion living only in a conversation:
  extract it into an artifact.
- Large resources are read incrementally (line pagination); listings are
  paged with `offset`/`limit`.

---

## `cortex_continue`  -  contribute to a conversation

Continues a named research conversation.

```
cortex_continue(conversation:, prompt:, agent:)
```

- `conversation`: name of the conversation (nested names allowed).
- `prompt`: what the contributing agent should do now.
- `agent`: agent name, optionally `Agent/brief` to load a brief from the
  `briefs` namespace (e.g. `Worker/bash-math`).
Returns `{agent_meta: [{role: :meta, content: "job=Cortex/continue/..."}],
content: <answer>}`; the `job=` receipt is the provenance edge into the
child execution.

## `cortex_brief`  -  create/update an agent brief

```
cortex_brief(conversation:, prompt:, agent:, tools: [], reply: false)
```

- `conversation`: the brief name (stored in `briefs/`, never mixed with
  regular conversations).
- `prompt`: prompt for the agent producing the brief.
- `agent`: agent the brief is for; recorded in the adjacent `briefs/<name>.info` sidecar
  and used to produce the brief.
- `tools`: JSON array of tool-spec strings, never comma-split. Each spec
  follows `"Workflow [task [input|name=value ...]]"` and is expanded into
  `tool:` / `introduce:` chat messages persisted at the top of the brief
  body, so an agent invoked as `Agent/<brief>` through `cortex_continue`
  receives exactly the provisioned tools (plus the framework's own
  mandatory `tool: Cortex` entry).
- `reply`: `false` (default) stores the prompt (and the tool block when
  given) without running any inference; `true` has the agent draft the
  briefing text and appends its answer.

## `cortex_list`  -  metadata-only listing

Paginated listing of one namespace (or `all`): `conversations`, `briefs`,
`artifacts`. Never returns contents; every row carries the path map in its
own column.

## `cortex_search`  -  lexical search

Case-insensitive multi-term (AND) search over conversation messages,
briefs, and artifacts. Returns compact matches with short snippets only.

## `cortex_read`  -  bounded read

Reads conversations (index or slices), briefs, and artifacts
(line-paginated).

## `cortex_write`  -  write or append an artifact

```
cortex_write(path:, content:, mode: "replace"|"append", agent:)
```

Creates or updates `artifacts/<path>` with full version history under the
resource's `<path>.files/history/` directory and provenance in the adjacent
`<path>.info` sidecar (job, agent, mode, map, timestamp, size). Missing
sidecars are tolerated and created when metadata is written. Append mode adds
to the end, creating the resource if absent.

## `cortex_edit`  -  exact text edit

```
cortex_edit(name:, find:, replace:, all: false, agent:)
```

Exact textual replacement. Fails with a clear error when:

- `find` does not occur in the artifact, or
- `find` occurs more than once, unless `all: true` is passed.

Previous content is snapshotted to the resource's `.files/history/` and the
adjacent `.info` version list
grows (mode `edit`). No resending the whole artifact to change a sentence.

## `cortex_rename`  -  change logical name (same path map)

```
cortex_rename(type:, name:, to:, agent:)
```

Moves content plus adjacent `.info` and `.files/` sidecars together as one
logical object;
the source disappears. Fails if the target exists or the source is missing.
Nested names supported in all namespaces.

## `cortex_remove`  -  delete a resource

```
cortex_remove(type:, name:)
```

Removes the resource and its associated metadata/history consistently; no
orphaned sidecar/history entries remain. Legacy namespace-level `.meta`/`.history`
layouts are unsupported, unread, unmigrated, and unmaintained. The namespace is always
explicit; there is no "delete anything with this name".

## `cortex_move`  -  transfer between path maps

```
cortex_move(type:, name:, to: "lib"|"current", agent:)
```

Transfers the canonical resource (content + adjacent `.info` + `.files/`) between
path maps without changing its logical name, semantics analogous to
`scout resource sync`. In a checkout where `:lib` and `:current` resolve to
the same physical directory the move is a reported no-op. Rename and move
stay conceptually distinct: rename changes the logical name, move changes
the path map.

---

## Caching note

Like every Scout task, results are cached per input combination. If the
workspace changed since a previous identical call, use a different input
(e.g. a different `offset`/`limit`) or clear the job.
