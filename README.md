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

Resources live under `var/cortex/`, separated into six namespaces:

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
- `lists/` — named entity lists, addressed `lists/<entity_type>/<list>`
  (e.g. `lists/TF/C01`, `lists/Composite/cell-cycle.md`). The file body is
  a newline-separated list of entity ids; a `.meta` sidecar stores
  `description`, `entity_options`, and provenance (`created_by`,
  `created_at`, `job`). Lists are read and written with
  `cortex_write_list`/`cortex_read_list` (and `cortex_read type=lists`),
  through the same path resolution as every other namespace.
- `properties/` — the RETIRED execution registry, kept as read-only
  history. Nothing writes it anymore: current evidence is the
  `var/jobs` Step tree (each result's `.info` sidecar carries the
  argument set, the definition identity, upstream addresses and
  status). Legacy records (`properties/<Type>/<property>/<receiver>.json`,
  with their legacy `examinations` arrays and legacy
  `list:<Type>_<list>` receiver spelling) stay on disk untouched and
  are read as history (`source: registry_history`) by
  `cortex_list type=properties`, `cortex_read type=properties
  <Type>/<property>/<label-or-receiver>` and `cortex_search
  type=properties`, alongside the current materialized results
  (`source: step_info`).

Dot-directories (`.meta`, `.history`) are internal and never listed.

Nested names are legal in all namespaces (`claims/C42.md`,
`TF/TP53`), as simple relative paths: no absolute paths, no `~`, no `..`.

## Path maps

Each namespace can exist in more than one location, or path map. Cortex
resolves resources across readable maps and writes to a designated write
map.

Resolution is full-path based: a resource is addressed as
`(namespace, relative path)` and looked up as `CORTEX[namespace][path]`
followed by `.find`, which traverses every readable map in order (so an
element present only in a secondary map is still found, at any nesting
depth). First match wins.

Cortex never introduces a map of its own: it only pins
`CORTEX.libdir` (which `:lib` resolves from) and locates
`cortex_path_map.yaml`.

- `:current` — `{PWD}/var/cortex/...`, Scout's own semantics. It is never
  overridden by Cortex and is always the default write map. Note that
  under `exec`/bwrap job execution the process PWD is the workflow
  checkout root, not the chat dir, so with a foreign chat anchor
  `:current` is the workflow checkout's store and `:lib` is the chat
  repo's store; `:current` is still searched first.
- `:lib` — the library store, `{LIBDIR}/var/cortex/...`. `LIBDIR` is the
  chat anchor when Scout-AI sets `SCOUT_CHAT_DIR` (the libdir of the chat
  being executed, inherited by job subprocesses). When `SCOUT_CHAT_DIR`
  is absent the anchor falls back to the repository containing the PWD
  (marker-based climb, so a subdirectory still resolves its project) and
  is nil-safe: a PWD inside no repository leaves `:lib` with Scout's lazy
  semantics. From a repository root `:current` and `:lib` collapse onto
  the same directory; from a subdirectory they diverge (`:current` = the
  subdirectory store, `:lib` = the repository store).
- Read order: `[:current, :lib, :user]`, then the yaml-defined maps (below)
  in file order, then the rest of Scout's base `Path.map_order` table.
  `Scout::Config` keys `cortex.write_map` and `cortex.read_maps` override
  the write map and the read order in every mode.

Additional maps come from a per-project `cortex_path_map.yaml` (project
root or `etc/`), which attaches other projects' cortex stores to this
one. Each entry names a map and points at the project root:

    maps:
      cortex:
        dir: /home/mvazque2/git/workflows/Cortex
      ags:
        dir: /home/mvazque2/git/workflows/AGS
        read_only: true
      lib:
        dir: /home/mvazque2/git/workflows/Cortex

Yaml entries become instance-level maps attached to `CORTEX`; they never
touch the global `Path.path_maps` table. Entries can redefine `:lib` and
introduce any number of new maps. `read_only: true` marks a map that is
searched for reads but rejected as a `cortex_move` target, so shared
stores can be consumed without being modified. Yaml maps are searched
after `[:current, :lib, :user]` and before the rest of the base hierarchy.

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
7. **Compute evidence** — `cortex_property_run` to execute a property for
   an entity or a named list and get the run receipt (address +
   materialized evidence); `cortex_result` to resolve any address to its
   value, info, or path; `cortex_write_list` / `cortex_read_list` to name
   entity sets once and run properties over them by reference.
8. **Recall** — `cortex_activity` to join everything the workspace already
   holds about ONE entity (defined properties, materialized results, legacy
   records, containing lists, mentions) before deciding what to investigate
   next.

Two disciplines make this work well:

- Never rely on an important conclusion living only in a conversation:
  conversations are working space; extract durable results as artifacts.
- Do not assume an artifact exists because a conversation mentions it:
  verify with `cortex_list` / `cortex_read`.

Briefing is decoupled from agent naming. A brief is stored under its own
name in `briefs/` (it does not need to contain the agent name), and is
referenced as `Agent/brief` — e.g. `Worker/bash-math` means agent
`Worker` prepared by brief `bash-math`.

Briefs define their own tooling: `cortex_brief` accepts a `tools` array of
spec strings that are expanded into `tool:` / `introduce:` chat messages
persisted at the top of the brief body, so an agent invoked as
`Agent/<brief>` through `cortex_continue` receives exactly the provisioned
tools (plus the framework's own mandatory `tool: Cortex` entry). Each spec
follows `"Workflow [task [input|name=value ...]]"`; `tools:
["ScoutCoder help_workflow", "Boolean trap_spaces network cft=default",
"Baking"]` persists, in array order:

```
tool: ScoutCoder help_workflow
tool: Boolean trap_spaces network cft=default
introduce: Baking
tool: Baking
```

A whole-workflow spec (`Baking`) is persisted as BOTH an `introduce: Baking`
message (the workflow documentation) AND a `tool: Baking` message (every
task of the workflow as a tool, full inputs). A task-level spec persists
one `tool:` line with the spec pasted verbatim: `Workflow task` accepts all
task inputs, appending bare input names (`Workflow task net`) restricts the
accepted inputs to those names, `name=value` tokens
(`Workflow task net=lab`) pre-fill the input at call time and hide it from
the model, and `noinputs` (or `none`) as the sole input token exposes the
task with no inputs. Specs are validated for syntax only and resolved when
the brief is used. Giving `tools` replaces the brief's entire tool block
(`tools: []` strips all tooling); omitting `tools` leaves the existing
tooling untouched. Briefing runs no inference pass by default: the prompt
(and the tool block) is stored as-is and nothing executes, so a brief can
be prepared without spending a model call; pass `reply: true` when the
agent should instead draft the briefing text itself and its answer should
be appended to the brief. The full behavior is documented with the
`cortex_brief` parameters in
[doc/user/WorkspaceTools.md](doc/user/WorkspaceTools.md).

## Entities and evidence

Cortex deliberately ships no scientific semantics of its own, but it does
provide the substrate for them: **executable entity properties**. An entity
type exists implicitly from its first property; a property is trusted Ruby
code plus a metadata schema, addressed `entities/<Type>/<property>`. Running
it for a concrete entity or list produces a real, cacheable Scout Step with
full provenance — so numerical claims can cite a job instead of
transcribing numbers.

The intended evidence workflow is:

1. Define (or discover) a property: `cortex_property_define`, after checking
   `cortex_property_list` (definitions) and `cortex_property_validate`
   (candidate checks + optional smoke run).
2. Name the entity set: `cortex_write_list` (discover with
   `cortex_list type=lists`).
3. Execute: `cortex_property_run` with `entity:` for one entity or
   `list:` for the named set; the receipt carries the result `address`,
   the `definition` `{version, digest}`, and the `materialized`
   `{path, bytes}`. Resolve the address with `cortex_result` (value,
   info, or path — a mangled prefix is recovered by its hex tail).
4. Check what is already known: `cortex_list type=properties` (current
   materialized results plus legacy execution records, per entity and
   list) and `cortex_activity` (the same joined around ONE entity, plus
   the lists containing it and the conversations/briefs/artifacts that
   mention it).

Versioning mirrors artifacts: definitions carry `.meta` (active version,
digest, history) and `.history` snapshots; changes bump the digest, which
moves every result address of that property (the definition identity is
digested into each address). Executions of a mutated named list are also
invalidated: a done result older than the list file is cleaned and
recomputed, so list edits never serve stale evidence. Result addresses
are a pure function of (definition identity, argument set, receiver,
dependencies): identical inputs always land on the same address, and a
done result replays from cache.

**Foreign entity types are adopted, not rejected.** A pre-existing
`EntityWorkflow` module (e.g. `Security` from an external workflow) is
usable through `cortex_property_run` in three regimes: (A) no active
Cortex definition → the plain method runs on the entity object and the
receipt reports `definition: {version: 0, digest: null}` with no address
(there is no Step); (B) an active definition (whatever wrote it) → the
task path, a real Step with the 3-segment address; (C) define/update on
the adopted module → the task path serving the NEW body at a moved
address. Failures surface as structured error envelopes, never a silent
fallback; non-Entity pre-existing constants are still rejected.
Validation: `research/impl-step11-foreign-adoption-validation.md`.

**Invalidation one-liner.** A definition change invalidates through the
definition-identity inputs, which are digested into BOTH the Task memo
key and the result address (new key + new address on every change, so
stale replay is impossible); the eviction hook called after define/
update is same-process memory hygiene only.

Job placement: every entity module Cortex builds — managed and adopted —
has its job directory PINNED to the checkout `var/jobs/<Type>/...`
(`pin_module_directory!`, an absolute template), so placement is
independent of the process CWD. `Path#find` is still first-existing-wins,
so labels whose old-root directories already exist (e.g. foreign types
with pre-change evidence under `~/.scout`) keep replaying there: same
definition, two roots, both resolvable through `cortex_result`.
Validated in `research/impl-step9-current-placement-validation.md` and
`research/impl-step11-foreign-adoption-validation.md`.

Discipline: never transcribe numerical evidence when a property can return
it — claims and artifacts should cite the address that produced their
evidence.

## Receipts and provenance

`cortex_continue` and `cortex_brief` return a JSON receipt
`{agent_meta: [{role: :meta, content: "job=Cortex/continue/..."}],
content: <answer>}`. The `job=` field is a provenance edge from the
parent conversation into the child execution (its full chat, tool calls,
and logs). Because these edges are recorded in the conversation itself,
downstream analysis can reconstruct the execution graph without scanning
the workspace.

## Examples

Every example below is also available as a dedicated `scout cortex`
subcommand (see `scout cortex --help`), e.g. `scout cortex brief --conversation
bash-math ...`. The subcommands take the same inputs as their tasks and print
the task result; `scout cortex task <task> ...` is the generic passthrough.

Brief an agent for later reuse:

```bash
scout workflow task Cortex cortex_brief --conversation bash-math \
    --agent Worker \
    --prompt "You are a math worker; always compute sums with bash arithmetic."
```

Provision the brief's tooling so the agent receives exactly these tools:

```bash
scout workflow task Cortex cortex_brief --conversation bash-math \
    --agent Worker \
    --tools '["ScoutCoder help_workflow", "Baking"]' \
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

Run a property for one entity and for a named list:

```bash
scout workflow task Cortex cortex_property_run --entity_type Gene \
    --property activity_in_treatment --entity TP53 \
    --arguments '{"treatment": "DMBA"}'

scout workflow task Cortex cortex_result \
    --address Gene/activity_in_treatment/TP53_<md5> --projection path
```

Recall everything known about one entity before investigating it:

```bash
scout workflow task Cortex cortex_activity --entity_type TF --entity TP53
```

### Cortex etiquette

Whenever you need to establish that something works, **open an investigation**
and leave the results for those who come after you. An investigation should
conclude when the issue is clear and understood. At that point, consider what
should be done with the information: consolidate it, turn it into
documentation, update an existing artifact, or otherwise clean it up so that
future work becomes simpler.

Maintain **named Cortex conversations** for different areas of work, and
recruit the appropriate agents for each. When a new line of work branches
off an established conversation, start a new named conversation and carry
over only the conclusions that matter (preferably as artifacts the new
conversation can cite).

For tasks that require substantial preparation—such as writing workflow tasks,
debugging complex errors, or developing tests—consider **briefing a specialist
agent first**. Give it additional instructions about what it needs to
investigate, and, when appropriate, have it perform a simple task first. This
can verify that the agent has acquired the necessary context and understanding
before it is trusted with a sequence of more complicated tasks.

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

Grows `briefs/<name>` with the prompt (a fresh brief starts prompt-only
when no `tools` are given) and saves it with a `.meta` sidecar recording
the target agent, the producing job, and a timestamp. The brief name does
not need to contain the agent name. Use this before `cortex_continue`
whenever an agent needs consistent preparation, then reference the agent
as `Agent/brief`. Same receipt contract as `cortex_continue`.

The `tools` input (a JSON array of spec strings, never comma-split)
provisions the brief's tooling: specs follow `"Workflow [task
[input|name=value ...]]"` and are persisted as `tool:`/`introduce:` chat
messages at the top of the brief body, so the briefed agent receives
exactly those tools. A whole-workflow spec persists BOTH an
`introduce: Workflow` message (documentation) AND a `tool: Workflow`
message (every task, full inputs); a task-level spec persists one verbatim
`tool:` line where bare input names restrict the accepted inputs,
`name=value` pre-fills and hides an input, and `noinputs`/`none` as the
sole input token exposes the task with no inputs. Validation is syntax
only; workflows and tasks are resolved when the brief is used. Giving
`tools` replaces the whole existing tool block, `tools: []` strips all
tooling, and omitting `tools` keeps the existing tooling. See
doc/user/WorkspaceTools.md for the full grammar and examples.

## cortex_list
List workspace namespaces with metadata only

Lists `conversations`, `briefs`, `artifacts`, `entities`, `lists`, or
`all`, showing name, size, mtime (and message count for chats). Contents
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

Case-insensitive search over chat messages, artifact and entity-list
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
map resolve to the first readable map and report the ambiguity. Entity
lists (`type=lists`, name `<entity_type>/<list>`) are returned the same
way as artifacts: the newline-separated entity ids, with a
`start_line`/`lines` page header and a trailing meta block when
`include_meta` information exists.

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

## cortex_write_list
Write a named entity list under lists/<entity_type>/<list>

Stores a newline-separated list of entity ids at
`lists/<entity_type>/<list>` through the unified path resolution, plus a
`.meta` sidecar (`description`, `entity_options`, provenance fields such
as `created_by`/`created_at`/`job`). The list name is the file name
verbatim (`C01`, `cell-cycle.md`); nested paths are allowed. Returns the
list address and the entity count.

## cortex_read_list
Read a named entity list

Returns the newline-separated entities of
`lists/<entity_type>/<list>` resolved across all readable path maps
(first match wins; cross-map ambiguity is reported). With `include_meta`
the `.meta` sidecar (description, entity_options, provenance) is appended
below the entity count.

Named lists are the preferred way to run properties over many entities:
define the list first, then pass it to `cortex_property_run` as
`list: "<entity_type>/<list>"`. A `:single` property fans out to one
materialized result per member (each its own address
`<member>_<md5>`); `:array`/`:both` produce one vector result
(`Default_<md5>`). The list sidecar's `entity_options` are merged
into the run, and a list edit newer than a done result invalidates it
automatically.

## cortex_move
Move a resource between path maps keeping its logical name

Transfers the canonical resource (e.g. `:current` to `:lib` or `:user`)
following resource-sync semantics: content, `.meta` metadata, and `.history`
snapshots travel together as one logical object; the source disappears.
Artifact `.meta` gets a version record (mode `move`) with from/to maps. The
target must not already exist. Rename changes the logical name, move changes
the path map — the two stay distinct.

## properties listing (cortex_list / cortex_search / cortex_read)
See which entity properties have already been investigated

`cortex_list type=properties` returns one row per result, from TWO
sources: **current evidence** — one row per materialized result under
`var/jobs` (tagged `step_info`), with its step status and definition
version/digest — and **history** — one row per legacy registry record
(tagged `registry_history`), with the legacy receiver spelling and
last-run timestamp. `cortex_search type=properties <term>` matches both
(current addresses and identities, legacy record contents).
`cortex_read type=properties <Type>/<property>/<label-or-receiver>`
resolves the address first against `var/jobs` (rendered sidecar
summary, tagged `CURRENT`), falling back to the legacy record (tagged
`LEGACY`) when no materialized result matches. So "FOXO1 of type TF
has had activity_in_experiment run for PD, PI and PD_PI" is a listing
query, not a re-run.

## cortex_property_list
List entity property definitions with versions and digests

Grouped by entity type; each row gives the property name, its path map,
active version, short digest, arity (`single`/`array`/`both`), result
kind, argument and dependency counts, and active flag. `include_inactive` also shows
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
throwaway scratch module, and an optional smoke execution against
`test_entity` with `test_arguments`. The smoke ALWAYS runs `clean: true`
in a fresh scratch directory, so a previous run's cached error text is
structurally unobservable; it also performs the result-kind check
(declared kind vs the class actually loaded). Returns `{valid, address,
checks, errors, smoke}` where `smoke` failures carry the structured
error envelope. Omit `body` to validate the currently active
definition. Use this before updating a production property.

## cortex_property_define
Define a new executable entity property

Creates `<Type>/<property>` at version 1: the Ruby `body` (one complete
string — whole-file semantics, no in-place mutation path; the annotated
entity is the receiver; declared `arguments` arrive as task inputs and
as locals), the `property_type` arity (`single`, `array`, `both`),
`result_kind` (the old `result_type` spelling is accepted and reported
with a deprecation warning), argument specs and same-type
`dependencies`. Refuses if an active property exists at that address.
The candidate is compiled in a staging module before anything is
written, and optionally smoke-tested.
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

## cortex_property_run
Execute an entity property and return the run receipt

Runs the active definition for an entity or entity list with `arguments`,
and returns the section 2.7 receipt:

```json
{
  "entity_type": "Gene",
  "property": "activity_in_treatment",
  "receiver": "Tp53",
  "arguments": {"treatment": "DMBA"},
  "definition": {"version": 1, "digest": "…64 hex…"},
  "address": "Gene/activity_in_treatment/Tp53_<md5>",
  "result_kind": "string",
  "status": "done",
  "value": "…",
  "materialized": {"path": "…/var/jobs/Gene/activity_in_treatment/Tp53_<md5>",
                   "bytes": 12},
  "info_path": "…/Tp53_<md5>.info"
}
```

Every field is mechanically derived from the produced Step or the call
inputs. The `address` is the Step `short_path`: the canonical reference
to the materialized result, resolvable later with `cortex_result`. The
Step is content-addressed on the entity, the arguments, and the
definition identity (version/digest), so an identical call replays from
cache, while any change to the definition or a dependency invalidates
the path. `update: true` cleans and recomputes at the same address.
Named-list runs self-invalidate: when the list file is newer than a
done result computed from it, that result is cleaned and recomputed.

Dispatch: arity `single` produces ONE receipt per receiver member (a
list run returns an ARRAY of receipts, each address
`<member>_<md5>[.ext]`); arity `array`/`both` produce ONE vector
receipt labeled `Default_<md5>`. A member that fails does not fail the
run: its receipt carries the structured error envelope and
`failed_members`/`total_members` counts.

**The canonical multi-entity workflow is list-first**: define a named
list with `cortex_write_list` once (discover existing ones with
`cortex_list type=lists`), then pass it through
`list: "<entity_type>/<list>"` and omit `entity`. The list is resolved
before execution and its `entity_options` are merged in.

`entity` takes a single identifier; an inline JSON array is accepted
and fans out exactly like a list receiver.

Discipline: never transcribe numerical evidence when a property can
return it — claims and artifacts should cite the address that produced
their evidence.

## cortex_result
Resolve a materialized result address; never executes

`address` (short_path `<Type>/<property>/<label>` or a full path),
`projection` (`value`, `info`, or `path`; default `value`), `max_bytes`
(bounding for `value`). Resolution order: exact literal path →
`var/jobs`-prefixed short_path (`Step.load`) → one recovery pass
matching the address's hex tail (16..32 hex digits — a mangled prefix
with an intact hash recovers), reported loudly (`recovered: true`,
`recovered_from: <tail>`) → structured `ParameterException` listing the
candidate labels in the directory; an ambiguous tail errors with all
candidates. Projections of the SAME resolved Step: `value` (bounded
payload), `info` (the full `.info` sidecar, including the definition
identity), `path` (the PATH STRING itself, not file content — hand it
to a probe or a downstream `dep`).

### Execution timeout

Property execution is bounded by a timeout, mirroring the ComputerUse
sandbox (`sandbox_run`):

* explicit per-call: `timeout:` on `cortex_property_run` (seconds).
  `0`, `"false"` or `"none"` runs unbounded;
* config: key `timeout`, tokens `entity_property`/`cortex` (lowest
  numeric priority wins), e.g. a config line `timeout entity_property 900`
  or `Scout::Config.set({'timeout' => '900'}, :entity_property, :cortex)`;
* env: `CORTEX_ENTITY_PROPERTY_TIMEOUT` (or `ENTITY_PROPERTY_TIMEOUT`);
* default 3600s.

The bound covers execution only — `Step#run` and, for list receivers, the
per-member loop — not the cache-hit fast path or the invalidation
bookkeeping. A hit leaves the interrupted Step with status
`error` and no result file, so a later run (with a larger bound or
unbounded) recomputes at the same path.

The same bound applies to the optional smoke executions of
`cortex_property_define`, `cortex_property_update` and
`cortex_property_validate`: a hanging candidate body surfaces as a smoke
failure (and, for define/update, no definition is written) instead of
wedging the task.

## cortex_activity
Report accumulated workspace activity around ONE entity

Structured, deterministic join over what the Cortex workspace already knows
about a single entity: no LLM, no new results, read-only recall. Sections
(facets): `properties` (defined and active properties for the entity type),
`investigations` (the materialized results under `var/jobs` for this exact
entity — current evidence, tagged `step_info` — plus the legacy execution
records that mention it — history, tagged `registry_history`; result
payloads are never included; use `cortex_result` to inspect them),
`lists` (named entity lists of this type containing the entity), and
`mentions` (conversations, briefs and artifacts that mention the entity id).

The `facets` input accepts a comma-separated list; empty means all, in a
fixed order. Identical inputs over an identical workspace always produce
identical output. The report is a JSON object `{entity, facets, facet_names}` where each
facet section is `{facet, title, items, meta}`; `meta.total` is the facet's
full count, `meta.shown` what the `limit` (default 10) actually returned,
and `meta.has_more` is true when shown < total, so an agent can always tell
"only three exist" from "twenty exist, three shown". The four
registered facets:

- `properties` — every defined property for the entity type: name, result
  kind, arity (`single`/`array`/`both`), definition version and digest,
  active flag, and path map. This is the inventory of dimensions through
  which the entity can be examined, regardless of whether it has been.
- `investigations` — current evidence: every materialized result under
  `var/jobs` whose receiver is exactly this entity (fan-out list runs
  produce one such result per member, so a list run on `TF/panel`
  surfaces inside the report of each member). Each item carries the
  result `address`, the argument set, the definition version/digest in
  force, the step status and timestamps. Legacy registry records
  mentioning the entity appear as separate history items (tagged
  `registry_history`, carrying their legacy run counts and job
  references). Result payloads are never included; resolve an item's
  address with `cortex_result` to inspect it. Each item carries a
  `status` separating the historical fact (the property was executed)
  from the current capability: `active` (the recorded version is the
  current active definition and can be re-run), `older` (a newer
  definition version is current; the recorded `definition_digest`
  identifies the code that actually produced the recorded evidence), and
  `removed` (no active definition exists anymore; the record is kept as
  history only).
- `lists` — named lists of this entity type that contain the entity, with
  member counts and descriptions.
- `mentions` — conversations, briefs, and artifacts that mention the entity
  id, with short match snippets (the same index `cortex_search` uses).
  Raw lexical matches are a discovery hint ONLY: hits include incidental
  occurrences (tool-call transcripts, table rows), so never infer presence,
  absence, importance or scientific relevance from the mention count — read
  the underlying resource.

Use it where you would otherwise run several listing/search queries by
hand: before designing a new investigation, to avoid re-examining a
question and to spot an unexplored property or an unexpected list
membership. It complements `cortex_list type=properties` (workspace-wide,
all receivers) with an entity-centric view, and complements
`cortex_property_run` (computation) with pure recall.

The facet set is extendable without touching the dispatcher: add a file
under `lib/Cortex/activity/` (see `doc/developer/Entities.md`).
