# Persistent research workspace for agent conversations, briefs, and durable artifacts

Cortex organizes the work of Scout-AI agents into a persistent, navigable
workspace. Instead of losing research progress inside one-off chats, agents
contribute to named conversations, keep reusable agent briefs, and extract
durable results as versioned artifacts. Every agent turn produces a
provenance receipt pointing at the workflow job that produced it, so the
work can always be traced back to the actual execution.

Cortex is a thin layer over scout-ai's `AgentWorkflow`: the only inference
primitive is the internal `continue` chat task; everything else is storage,
navigation, management, and provenance. It deliberately contains no
scientific semantics (no entities, no ontology, no relevance injection) so
that higher layers — reasoning strategies, analysis tooling, semantic
organization — can be built as clients of the workspace rather than inside
it.

## Workspace layout

Resources live under `var/cortex/`, separated into three namespaces:

- `conversations/` — working, exploratory research conversations. This is
  where agents reason; conversations are allowed to be messy.
- `briefs/` — reusable agent preparation. A brief is a short conversation
  that primes an agent with how it should work (e.g. "always sum with
  bash"). Briefs are never mixed with regular conversations, and an agent
  cannot be briefed with a regular conversation.
- `artifacts/` — durable research objects (claims, analyses, summaries,
  dossiers). Every write records provenance (producing job, agent,
  timestamp) in a `.meta/` sidecar and snapshots previous versions to
  `.history/`, so nothing is silently overwritten.

Dot-directories (`.meta`, `.history`) are internal and never listed.

Nested names are legal in all namespaces (`claims/C42.md`,
`TF/TP53`), as simple relative paths: no absolute paths, no `~`, no `..`.

## Path maps

Each namespace can exist in more than one location, or path map. Cortex
resolves resources across readable maps (by default `:lib` then
`:current` and `:user`) and writes to a designated write map (`:current`, configurable
via `Scout::Config`, keys `cortex.write_map` and `cortex.read_maps`).
When the same logical name exists in more than one map, reads resolve
deterministically to the first map but say so explicitly, and listings
tag the name with its map; ambiguity is always visible, never hidden.
`cortex_move` transfers a resource between maps (rename and move are
distinct operations: rename changes the logical name, move changes the
map).

## Recommended use

The intended agent workflow over the workspace is:

1. **Discover** — `cortex_list` to see what exists (metadata only, always
   small and paginated).
2. **Locate** — `cortex_search` to find material by content, across all
   readable maps.
3. **Inspect** — `cortex_read` to fetch only the parts you need:
   conversation index plus `last`/`range` slices, or line-paginated
   artifact pages.
4. **Contribute** — `cortex_continue` to add a turn to a conversation
   (optionally through a briefed agent), `cortex_brief` to prepare or
   refresh a reusable brief.
5. **Consolidate** — `cortex_write` to extract reusable results into
   artifacts, `cortex_edit` for targeted corrections without resending
   whole documents.
6. **Manage** — `cortex_rename`, `cortex_move`, `cortex_remove` only when
   deliberately reorganizing existing resources.

Two disciplines make this work well:

- Never rely on an important conclusion living only in a conversation:
  conversations are working space; extract durable results as artifacts.
- Do not assume an artifact exists because a conversation mentions it:
  verify with `cortex_list` / `cortex_read`.

Briefing is decoupled from agent naming. A brief is stored under its own
name in `briefs/` (it does not need to contain the agent name), and is
referenced as `Agent/brief` — e.g. `Worker/bash-math` means agent
`Worker` prepared by brief `bash-math`.

## Receipts and provenance

`cortex_continue` and `cortex_brief` return a JSON receipt
`{agent_meta: [{role: :meta, content: "job=Cortex/continue/..."}],
content: <answer>}`. The `job=` field is a provenance edge from the
parent conversation into the child execution (its full chat, tool calls,
and logs). Because these edges are recorded in the conversation itself,
downstream analysis can reconstruct the execution graph without scanning
the workspace. `continue_chat` and `brief_agent` remain as compatibility
aliases with identical behavior and receipts.

## Examples

Brief an agent for later reuse:

```bash
scout workflow task Cortex cortex_brief --conversation bash-math \
    --agent Worker \
    --prompt "You are a math worker; always compute sums with bash arithmetic."
```

Continue a conversation with the briefed agent:

```bash
scout workflow task Cortex cortex_continue --conversation Summing \
    --agent Worker/bash-math \
    --prompt "Compute S = 1 + 12 + 123 + 1234 exactly."
```

Find and read prior material:

```bash
scout workflow task Cortex cortex_search --query TP53 PD_PI --type artifacts
scout workflow task Cortex cortex_read --type artifacts --name claims/C42.md --start_line 1 --lines 100
```

Extract a durable result:

```bash
scout workflow task Cortex cortex_write --path claims/C42.md \
    --content "Claim: ... (evidence, context, caveats)"
```

# Tasks

## continue
Run the AgentWorkflow inference step behind every Cortex agent turn

This is the internal `chat_task` that performs the actual LLM execution
for `cortex_continue` and `cortex_brief`: it loads the agent (optionally
briefed from the `briefs` namespace), attaches the Cortex tooling, runs
the conversation, and logs the agent automatically through the standard
AgentWorkflow machinery. The grown conversation is returned so callers
can persist it. It is normally not invoked directly; the receipt jobs
referenced by `agent_meta` point at `continue` jobs.

## cortex_continue
Contribute a turn to a named research conversation

Appends the prompt to `conversations/<conversation>`, runs the `continue`
inference task on the grown conversation, persists the result back to the
conversation file, and returns a receipt with `agent_meta` pointing at
the producing job plus the answer text. The full content stays in the
conversation file; only the receipt and answer come back. The optional
`Agent/brief` form of `agent` loads a brief from the `briefs` namespace
(e.g. `Worker/math` loads brief `math` for agent `Worker`); a brief that
does not exist produces an actionable error listing available briefs.

## cortex_brief
Create or update a reusable agent brief

Grows `briefs/<name>` with the prompt (a fresh brief starts prompt-only)
and saves it with a `.meta` sidecar recording the target agent, the
producing job, and a timestamp. The brief name does not need to contain
the agent name. Use this before `cortex_continue` whenever an agent needs
consistent preparation, then reference the agent as `Agent/brief`. Same
receipt contract as `cortex_continue`.

## cortex_list
List workspace namespaces with metadata only

Lists `conversations`, `briefs`, `artifacts`, or `all`, showing name,
size, mtime (and message count for chats). Contents are never returned.
Dot-directories are hidden. Names present in more than one readable path
map are tagged with their map. Supports `offset`/`limit` pagination; the
section header reports shown/total entries and the footer reports the
next offset when more exist. Use `cortex_read` for content and
`cortex_search` to find material by keyword.

## cortex_search
Lexically search conversation, brief, and artifact contents

Case-insensitive search over chat messages and artifact file contents
across all readable path maps. Single-term queries use substring match;
multi-term queries require every term (AND). Returns compact matches
with short snippets (~200 chars) only, never whole files; hits whose
name exists in more than one path map carry the map tag. Raise the limit
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
the previous version is snapshotted to `artifacts/.history` and a
version record (job, agent, mode, map, timestamp, size) is accumulated
in `artifacts/.meta/<name>.json`. Append mode adds to the end, creating
the artifact if absent. The content is never echoed back; the tool
returns a one-line confirmation. Conversations are working space;
artifacts are durable research objects — extract reusable results with
this tool.

## cortex_edit
Make a targeted, exact text edit to an existing artifact

Every occurrence of `find` (or the single occurrence, unless `all` is
true) is replaced by `replace`. Fails rather than guessing when `find`
is missing or occurs more than once without `all`. The previous version
is snapshotted to `.history` and a version record (mode `edit`) is
appended to `.meta`, exactly like a replace write. Do not resend whole
artifacts for small fixes; use this tool.

## cortex_rename
Rename a resource without changing its path map

Works on conversations, briefs, and artifacts. Artifacts and briefs take
their sidecar metadata and history along, so provenance and prior
versions stay attached; artifact `.meta` gets a version record (mode
`rename`). The target name must not already exist. Use only for
deliberate workspace management.

## cortex_remove
Remove a resource explicitly and completely

For artifacts and briefs the associated `.meta` metadata and `.history`
snapshots are removed together, so no orphaned provenance is left
behind. The namespace is required; there is no implicit
delete-anything. This is irreversible; use only for deliberate workspace
management.

## cortex_move
Move a resource between path maps keeping its logical name

Transfers the canonical resource (e.g. `:current` to `:lib` or `:user`)
following resource-sync semantics: content, `.meta` metadata, and `.history`
snapshots travel together as one logical object; the source disappears.
Artifact `.meta` gets a version record (mode `move`) with from/to maps. The
target must not already exist. Rename changes the logical name, move changes
the path map — the two stay distinct.

## continue_chat
Compatibility alias of cortex_continue

Older name for `cortex_continue`; identical inputs, behavior, and
receipts. Prefer the canonical name in new code and prompts.

## brief_agent
Compatibility alias of cortex_brief

Older name for `cortex_brief`; identical inputs, behavior, and receipts.
Prefer the canonical name in new code and prompts.
