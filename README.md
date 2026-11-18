Cortex: persistent research workspace for agent conversations, briefs, and artifacts

Cortex organizes the work of Scout-AI agents into a persistent, navigable
workspace: named conversations for ongoing reasoning, reusable briefs that
give an agent standing instructions and provisioned tooling, and versioned
artifacts for durable results. Every agent turn produces a provenance
receipt pointing at the workflow job that produced it, so work can always
be traced back to the actual execution.

Cortex is a thin layer over scout-ai's `AgentWorkflow`: the only inference
primitive is the internal `continue` chat task; everything else is storage,
navigation, management, and provenance. It deliberately contains no
scientific semantics — entity support lives in the Semantics workflow, and
tracking scientific evidence is the responsibility of the Research
workflow.

Resources live under `var/cortex/` in three namespaces: `conversations/`
(working, exploratory chats), `briefs/` (reusable agent preparation), and
`artifacts/` (durable research objects). Briefs and artifacts carry
adjacent `.info` metadata sidecars and `.files/history/` version snapshots,
so nothing is silently overwritten. A namespace can be reachable through
several path maps (`:current`, `:lib`, plus project-configured maps from
`cortex_path_map.yaml`): reads resolve first-match across maps in a fixed
order, and ambiguities are always reported, never hidden.

Eleven tasks are registered: the internal `continue` inference step and the
ten workspace tools `cortex_continue`, `cortex_brief`, `cortex_list`,
`cortex_search`, `cortex_read`, `cortex_write`, `cortex_edit`,
`cortex_rename`, `cortex_remove`, `cortex_move` — every agent working
through Cortex receives them automatically. `cortex_continue` and
`cortex_brief` return the delegation receipt `{meta: [{job: ...}],
content: ...}`, whose `job` reference is the provenance edge into the full
child execution.

**Where to go**

- `doc/user/` — the recommended use cycle (discover, locate, inspect,
  contribute, consolidate, manage), briefing mechanics and the full
  tool-spec grammar, worked examples, and Cortex etiquette. Start at
  `doc/user/README.md`.
- `doc/developer/` — architecture, the storage and path-map implementation,
  the receipt contract, tool exposure, and pending improvements.
- `skills/cortex-workspace-persistence/SKILL.md` — when work belongs in
  Cortex (conversation, brief, artifact) versus project files.
- `skills/cortex-receipts-provenance/SKILL.md` — reading delegation
  receipts and following artifact provenance.

# Tasks

## continue
Run the AgentWorkflow inference step behind every Cortex agent turn

This is the internal `chat_task` that performs the actual LLM execution
for `cortex_continue` and `cortex_brief`: it loads the agent (optionally
briefed from the `briefs` namespace), attaches the Cortex tooling, runs
the conversation, and logs the agent automatically through the standard
AgentWorkflow machinery. The grown conversation is returned so callers
can persist it. It is normally not invoked directly; the receipt jobs
referenced by `meta` point at `continue` jobs.

## cortex_continue
Contribute a turn to a named research conversation

Appends the prompt to `conversations/<conversation>`, runs the `continue`
inference task on the grown conversation, persists the result back to the
conversation file, and returns the receipt `{meta: [{job: ...}], content: ...}`
plus the answer text. The full content stays in the conversation file; only
the receipt and answer come back. The optional `Agent/brief` form of `agent`
loads a brief from the `briefs` namespace (e.g. `Worker/math` loads brief
`math` for agent `Worker`); a brief that does not exist produces an
actionable error listing available briefs.

## cortex_brief
Create or update a reusable agent brief

Grows `briefs/<name>` with the prompt (a fresh brief starts prompt-only
when no `tools` are given) and saves it with an adjacent `.info` sidecar
recording the target agent, the producing job, and a timestamp. The brief
name does not need to contain the agent name. Use this before
`cortex_continue` whenever an agent needs consistent preparation, then
reference the agent as `Agent/brief`. With `reply: true` (the default is
`false`: no inference pass) it returns the same `{meta: [{job: ...}],
content: ...}` receipt as `cortex_continue`; with `reply: false` it
returns `{content: "Conversation saved"}`.

The `tools` input (a JSON array of spec strings, never comma-split)
provisions the brief's tooling: specs follow `"Workflow [task
[input|name=value ...]]"` and are persisted as `tool:`/`introduce:` chat
messages at the top of the brief body, so the briefed agent receives
exactly those tools. Giving `tools` replaces the whole existing tool
block, `tools: []` strips all tooling, and omitting `tools` keeps it;
validation is syntax only (workflows and tasks are resolved when the brief
is used). The full grammar — whole-workflow vs task-level specs,
`name=value`, bare input names, `noinputs`/`none` — and worked examples
live in doc/user/WorkspaceTools.md.

## cortex_list
List workspace namespaces with metadata only

Lists `conversations`, `briefs`, `artifacts`, or `all`, showing name,
size, mtime (and message count for chats). Contents
are never returned.
Dot-directories are hidden. The path map of each entry is reported in its
own `map` column (right after `#name`), so the `name` column always holds
the clean logical name; an entry present in several maps appears once per
map. Supports `offset`/`limit` pagination; the
section header reports shown/total entries and the footer reports the
next offset when more exist. Use `cortex_read` for content and
`cortex_search` to find material by keyword.

## cortex_search
Lexically search conversation, brief, and artifact contents

Case-insensitive search over chat messages and artifact
file contents across all readable path maps. Single-term queries use substring match;
multi-term queries require every term (AND). Returns compact matches
with short snippets (~200 chars) only, never whole files; the path map of
each hit is reported in its own `map` column. Raise the limit
or use `cortex_read` for more.

## cortex_read
Read conversations, briefs, or artifacts with bounded output

For conversations and briefs the default is a compact per-message index
(role plus fingerprint); use `last` for the trailing N messages or
`range` for an inclusive message index slice (`"0-3"`), both capped at
50k chars. Indices exclude empty separator messages. Artifacts are read
with line-based pagination (`start_line` plus `lines`, default 200 lines
per page, same 50k cap); the header reports the returned range, total
lines, and the next start line. Resources found in more than one path
map resolve to the first readable map and report the ambiguity.

## cortex_write
Write or append a durable artifact

Creates or updates an artifact under `var/cortex/artifacts`. On replace,
the previous version is snapshotted under `artifacts/<name>.files/history/` and a
version record (job, agent, mode, map, timestamp, size) is accumulated
in the adjacent `artifacts/<name>.info`. Append mode adds to the end, creating
the artifact if absent. The content is never echoed back; the tool
returns a one-line confirmation.

## cortex_edit
Make a targeted, exact text edit to an existing artifact

Every occurrence of `find` (or the single occurrence, unless `all` is
true) is replaced by `replace`. Fails rather than guessing when `find`
is missing or occurs more than once without `all`. The previous version
is snapshotted to the resource `.files/history/` and a version record (mode `edit`) is
appended to the adjacent `.info`, exactly like a replace write. Do not resend whole
artifacts for small fixes; use this tool.

## cortex_rename
Rename a resource without changing its path map

Works on conversations, briefs, and artifacts. Artifacts and briefs take
their adjacent `.info` metadata and `.files/` history along, so provenance and prior
versions stay attached; artifact `.info` gets a version record (mode
`rename`). The target name must not already exist. Use only for
deliberate workspace management.

## cortex_remove
Remove a resource explicitly and completely

For artifacts and briefs the associated `.info` metadata and `.files/history/`
snapshots are removed together, so no orphaned provenance is left
behind. The namespace is required; there is no implicit
delete-anything. This is irreversible; use only for deliberate workspace
management.

## cortex_move
Move a resource between path maps keeping its logical name

Transfers the canonical resource (e.g. `:current` to `:lib` or `:user`)
following resource-sync semantics: content, adjacent `.info` metadata, and `.files/history/`
snapshots travel together as one logical object; the source disappears.
Artifact `.info` gets a version record (mode `move`) with from/to maps. The
target must not already exist. Rename changes the logical name, move changes
the path map — the two stay distinct.

