# Persistent research workspace for agent conversations, briefs, and durable artifacts

Cortex organizes the work of Scout-AI agents into a persistent, navigable
workspace. Instead of losing research progress inside one-off chats, agents
contribute to named conversations, keep reusable agent briefs, extract
durable results as versioned artifacts, and share executable evidence as
versioned entity properties. Every agent turn produces a provenance receipt
pointing at the workflow job that produced it, so the work can always be
traced back to the actual execution.

Cortex is a thin layer over scout-ai's `AgentWorkflow`: the only inference
primitive is the internal `continue` chat task; everything else is storage,
navigation, management, and provenance. It deliberately contains no
scientific semantics (no entities, no ontology, no relevance injection) so
that higher layers — reasoning strategies, analysis tooling, semantic
organization — can be built as clients of the workspace rather than inside
it.

## Workspace layout

Resources live under `var/cortex/`, separated into four namespaces:

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
- `entities/` — **executable** entity properties, addressed
  `entities/<Type>/<property>` (e.g. `Gene/activity_in_treatment`). A
  property is trusted Ruby code plus a metadata schema; running it for an
  entity produces a real, cacheable Scout Step with full provenance. Like
  artifacts, every definition is versioned (`.meta/` + `.history/`). Unlike
  artifacts, definitions are managed exclusively by the property tools
  (`cortex_property_define`/`_update`/`_remove`); the generic
  `cortex_write`/`_edit`/`_rename`/`_move`/`_remove` do not apply to them.
  Discovery is `cortex_property_list`, not `cortex_search` (definitions are
  not indexed for search).

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

## cortex_property_list
List entity property definitions with versions and digests

Grouped by entity type; each row gives the property name, active version,
short digest, arity (`single`/`array`/`both`), result type, argument and
dependency counts, and active flag. `include_inactive` also shows
tombstoned (removed) properties with their last version. `prefix` filters
by property name; `offset`/`limit` paginate. Definitions are executable
code, so ambiguity across path maps is an error here, not a warning.

## cortex_property_read
Read an entity property definition (interface + body), never executing it

Prints the interface first: arity, result type, every argument with its
Scout input type, description, required flag and default, the
dependencies, and the active version, digest and identity. Then the Ruby
body, paginated with `start_line`/`lines` exactly like `cortex_read` for
artifacts. Reading never executes the body; the property task is compiled
only when executed.

## cortex_property_history
Show the version history of an entity property

Compact per-version listing combining the `.meta` versions array with the
`.history/<Type>/<property>/` snapshots: version, action (`define`,
`update`, `remove`), short digest, producing job, agent, and timestamp.
Every change to executable code is attributable.

## cortex_property_validate
Validate a property definition without activating it

Runs the same checks as `cortex_property_define` but activates nothing:
names and schema, dependency graph (exists + acyclic), compilation in a
scratch module, and an optional smoke execution against `test_entity` with
`test_arguments` (the smoke job runs in a throwaway directory and is
cleaned). Returns `{valid, address, checks, errors, smoke}`. Omit `body`
to validate the currently active definition. Use this before updating a
production property.

## cortex_property_define
Define a new executable entity property

Creates `<Type>/<property>` at version 1: the Ruby `body` (the annotated
entity is the receiver; declared `arguments` arrive as task inputs and as
locals), the `property_type` arity (`single`, `array`, `both`),
`result_type`, argument specs and same-type `dependencies`. Refuses if an
active property exists at that address. The candidate is compiled in a
staging module before anything is written, and optionally smoke-tested.
Bodies are trusted executable Ruby: definitions are written by agents with
write access to the workspace, not sandboxed.

## cortex_property_update
Update an entity property at a known version

Requires `expected_version` matching the active version (optimistic
locking: a mismatch is an error listing both versions). Omitted fields
keep their current value. The current body and metadata are snapshotted to
`.history/<Type>/<property>/NNNNNN.{rb,json}`, the candidate is staged,
and only then is the new version activated. Changing `body`, `arguments`,
`dependencies` or the arity changes the definition digest, which
invalidates every job of that property — that is the intended behavior for
executable evidence. Description-only updates keep the digest (docs do not
invalidate caches).

## cortex_property_remove
Remove an entity property, keeping its history

Requires `expected_version`. Snapshots the active definition to
`.history/`, writes a tombstone (metadata with `active: false`,
`removed: true`) and deletes the active `.rb` so the property is no longer
executable or resolvable. The metadata and all history are preserved, and
the address can be redefined later. Removal of executable evidence is
always deliberate and reversible in intent: nothing is silently dropped.

## cortex_entity_property
Execute an entity property and return an evidence receipt

Runs the active definition for `entity` (a scalar, or a JSON array for a
list of entities) with `arguments`, and returns exactly:

```json
{
  "entity_type": "Gene",
  "entity": "Tp53",
  "property": "activity_in_treatment",
  "arguments": {"treatment": "DMBA"},
  "definition_version": 1,
  "definition_digest": "…64 hex…",
  "property_job": "Gene/activity_in_treatment/Tp53_…",
  "result": "…"
}
```

`property_job` is the `short_path` of the Scout Step that produced the
result: it is the provenance, so the receipt carries no separate agent
metadata. The step is content-addressed on the entity, the arguments, and
the definition identity (version/digest), so an identical call replays
from cache, while any change to the definition or a dependency invalidates
the path. `update: true` cleans and recomputes the property job at the
same path.

Discipline: never transcribe numerical evidence when a property can return
it — claims and artifacts should cite the property job that produced their
evidence.

## entity_property (removed)
Old demonstrator task, removed

The pre-milestone demonstrator `entity_property` was removed. Use
`cortex_entity_property`; its old `entity_type` input carried entity
*options* (not a type name), so it does not alias cleanly.
