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
scientific semantics so that higher layers — reasoning strategies, analysis
tooling, semantic organization — can be built as clients of the workspace
rather than inside it. Entity support now lives in the Semantics workflow,
and tracking scientific evidence is the responsibility of the Research
workflow.

## Workspace layout

Resources live under `var/cortex/`, separated into three namespaces:

- `conversations/` — working, exploratory research conversations. This is
  where agents reason; conversations are allowed to be messy.
- `briefs/` — reusable agent preparation. A brief is a short conversation
  that primes an agent with how it should work (e.g. "always sum with
  bash"). Briefs are never mixed with regular conversations, and an agent
  cannot be briefed with a regular conversation.
- `artifacts/` — durable research objects (claims, analyses, summaries,
  dossiers). Every write records provenance in an adjacent `<resource>.info` sidecar and
  snapshots previous versions under the resource's `<resource>.files/history/`
  directory, so nothing is silently overwritten.

Resource sidecars are adjacent to their resource: `<resource>.info` stores
metadata, and `<resource>.files/history/` stores prior versions or auxiliary
files. Missing sidecars are tolerated. Nested resources use the same convention
(for example, `claims/C42.md.info` and `claims/C42.md.files/history/`). Listing
and search filter recognized sidecars and history entries, while preserving
ordinary resources whose names merely contain `.info` or `.files`. Legacy
namespace-level `.meta/` and `.history/` layouts are unsupported, unread,
unmigrated, and unmaintained; they are not an alternative storage location.

Conversations have no Cortex-managed sidecars, and `var/jobs` Step results
have their own `.info` sidecars; those mechanisms are distinct from
resource storage.

Nested names are legal in all namespaces (`claims/C42.md`), as simple
relative paths: no absolute paths, no `~`, no `..`.

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

```yaml
    maps:
      cortex:
        dir: /home/mvazque2/git/workflows/Cortex
      ags:
        dir: /home/mvazque2/git/workflows/AGS
        read_only: true
      lib:
        dir: /home/mvazque2/git/workflows/Cortex
```

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

Additionally, the file can specify the map order. When specified any
path map not in the list will not be searched.

```yaml
    order: 
        - current 
        - lib
    maps:
      cortex:
        dir: /home/mvazque2/git/workflows/Cortex
      ags:
        dir: /home/mvazque2/git/workflows/AGS
        read_only: true
      lib:
        dir: /home/mvazque2/git/workflows/Cortex
```


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
when no `tools` are given) and saves it with an adjacent `.info` sidecar recording
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
returns a one-line confirmation. Conversations are working space;
artifacts are durable research objects — extract reusable results with
this tool.

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

