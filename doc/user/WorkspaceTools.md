# Workspace Tools

This page documents the `cortex_*` workspace tools agents use to
navigate, extend, and manage the Cortex workspace, the two named-list
tools (`cortex_write_list` / `cortex_read_list`), and the
`cortex_property*` / `cortex_result` tools for executable entity
properties.

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
7. `cortex_property_list` / `cortex_property_read` / `cortex_property_history`
   — discover and inspect entity property definitions
8. `cortex_property_define` / `_update` / `_validate` / `_remove` —
   version executable definitions (never generic write/edit)
9. `cortex_property_run` — execute a property for an entity or a named
   list and get the run receipt (address + materialized evidence)
10. `cortex_result` — resolve a result address to its value, info, or
    path (never re-executes)
11. `cortex_list type=properties` — see the materialized results under
    var/jobs (current evidence) and legacy execution records (history)
12. `cortex_write_list` / `cortex_read_list` — name entity lists once and
    run properties over them by reference
13. `cortex_activity` — deterministic recall of everything already known
    about ONE entity (defined properties, materialized results, legacy
    records, containing lists, mentions); no LLM, no recomputation

Rules of thumb:

- Conversations are working/reasoning space; briefs are reusable agent
  preparation; artifacts are durable research objects.
- Do not assume an artifact exists because a conversation mentions it:
  verify with `cortex_list` / `cortex_read`.
- Never rely on an important conclusion living only in a conversation:
  extract it into an artifact.
- Large resources are read incrementally (line pagination); listings are
  paged with `offset`/`limit`.
- **Multi-entity work is list-first**: define a named list once
  (`cortex_write_list`, discover existing ones with
  `cortex_list type=lists`) and pass it as `list:`. A `:single` property
  over a list fans out to one materialized result per member, each with
  its own address (`<member>_<md5>`); `:array`/`:both` produce one
  vector result labeled `Default_<md5>`.
- Resolve evidence by address, never by hand: `cortex_result(address)`
  returns value, info, or path; a mangled address prefix is recovered by
  its hex tail (16..32 hex digits) and reported loudly.
- Execution is timeout-bounded (per-call `timeout:` input; config key
  `timeout` with tokens `entity_property`/`cortex`; env
  `CORTEX_ENTITY_PROPERTY_TIMEOUT`; default 3600s; `0`/`false`/`none`
  runs unbounded). A timeout hit leaves the Step in `error` with no
  result file — rerun with a larger bound to recompute. The same bound
  applies to the optional smoke executions of `cortex_property_define`,
  `cortex_property_update` and `cortex_property_validate`: a hanging
  candidate body fails those checks instead of wedging the task.

### Property vocabulary (one line each)

- **entity type** — an anonymous Workflow module named exactly `<Type>`;
  its results live under `var/jobs/<Type>/`.
- **entity** — a plain String id; the readable prefix of a result
  address.
- **property** — a named, versioned, executable transformation of an
  entity into a typed result.
- **definition identity** — the `(version, digest)` pair; travels as
  three hidden task inputs so every address embeds it.
- **argument set** — the exact non-default argument values of one run;
  digested into the address suffix.
- **result kind** — the declared serialization (`string`, `tsv`,
  `json`, ...); structured kinds add the file extension.
- **materialized result** — the Step the run produced: result file +
  `.info` sidecar + `.files/` aux directory.
- **address** — `<Type>/<property>/<label>` (the Step's `short_path`);
  the canonical reference to a materialized result.
- **dependency** — a declared upstream property; its address is
  digested into the downstream address.
- **receipt** — the JSON envelope of a run; every field is copied
  mechanically from the Step (address, definition, materialized
  path/bytes, status, bounded value).
- **named list** — a versioned set of entity ids; the receiver of
  list runs.

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
- `agent`: agent the brief is for; recorded in the `briefs/.meta` sidecar
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
`artifacts`, `entities` (property definitions), `lists`, `properties`
(materialized results + legacy execution records). Never returns
contents; every row carries the path map in its own column.

For `type=properties` the rows combine **current evidence** — one row per
materialized result under `var/jobs`, tagged `step_info`, with its
status and definition version/digest — and **history** — one row per
legacy registry record, tagged `registry_history`. The execution
registry store itself is retired: nothing writes it, the records stay
on disk untouched.

## `cortex_search`  -  lexical search

Case-insensitive multi-term (AND) search over conversation messages,
briefs, artifacts, lists and properties records. Returns compact
matches with short snippets only. Over `properties` it matches the
current Step evidence (address + identity) and the legacy record
contents.

## `cortex_read`  -  bounded read

Reads conversations (index or slices), briefs, artifacts (line-paginated),
entity lists, and property records:

- `type=properties`, `name=<Type>/<property>/<label-or-receiver>`:
  resolves the address **first against var/jobs** (current evidence: the
  rendered sidecar summary, tagged `CURRENT`) and falls back to the
  legacy record (tagged `LEGACY`, `registry_history`) when no
  materialized result matches. Never executes anything.

## `cortex_write`  -  write or append an artifact

```
cortex_write(path:, content:, mode: "replace"|"append", agent:)
```

Creates or updates `artifacts/<path>` with full version history
(`.history` snapshots) and provenance in `.meta` (job, agent, mode,
map, timestamp, size). Append mode adds to the end, creating if absent.

## `cortex_edit`  -  exact text edit

```
cortex_edit(name:, find:, replace:, all: false, agent:)
```

Exact textual replacement. Fails with a clear error when:

- `find` does not occur in the artifact, or
- `find` occurs more than once, unless `all: true` is passed.

Previous content is snapshotted to `.history` and the `.meta` version list
grows (mode `edit`). No resending the whole artifact to change a sentence.

## `cortex_rename`  -  change logical name (same path map)

```
cortex_rename(type:, name:, to:, agent:)
```

Moves content plus `.meta` plus `.history` together as one logical object;
the source disappears. Fails if the target exists or the source is missing.
Nested names supported in all namespaces.

## `cortex_remove`  -  delete a resource

```
cortex_remove(type:, name:)
```

Removes the resource and its associated metadata/history consistently; no
orphaned `.meta`/`.history` entries remain. The namespace is always
explicit; there is no "delete anything with this name".

## `cortex_move`  -  transfer between path maps

```
cortex_move(type:, name:, to: "lib"|"current", agent:)
```

Transfers the canonical resource (content + `.meta` + `.history`) between
path maps without changing its logical name, semantics analogous to
`scout resource sync`. In a checkout where `:lib` and `:current` resolve to
the same physical directory the move is a reported no-op. Rename and move
stay conceptually distinct: rename changes the logical name, move changes
the path map.

---

## `cortex_property_define` / `cortex_property_update`  -  version a definition

`body` is the COMPLETE Ruby body as one string — whole-file semantics:
every write replaces the file; there is no in-place mutation code path.
Inputs take `result_kind` (the old `result_type` spelling is still
accepted and reported with a loud deprecation warning). The returned
definition receipt is `{entity_type, property, version, digest,
definition_path, property_type, result_kind}`. A candidate is staged in
a throwaway module and optionally smoke-run **before** anything is
written; a smoke failure blocks activation.

## `cortex_property_validate`  -  check a candidate, never mutate

Compiles the candidate (or the active definition, when `body` is
omitted) in a staging module built from the type's active manifest, and
when a `test_entity` is given ALWAYS runs the smoke in a fresh scratch
directory with `clean: true`: a cached previous run's error text is
structurally unobservable. Validate never writes the definition store.
The smoke also performs the kind check (declared result kind vs the
class actually loaded). Returns `{valid, address, checks, errors,
smoke}`; `smoke` failures carry the section 2.6 envelope (verbatim
message, bareness flag, verdict).

For a property with `dependencies`, the staging module is built from the
type's full active manifest (dependencies installed alongside the
candidate), because the dep block resolves the upstream task inside the
same module: staging the candidate alone leaves the dependency nil and
the smoke fails with `undefined method 'path' for nil`.

## `cortex_property_run`  -  execute and get the receipt

```
cortex_property_run(entity_type:, property:, entity: | list:,
                    arguments: {}, update: false, timeout:, agent:)
```

`entity` or `list` (never both; `list` is `<type>/<list>`). Inline JSON
array entity payloads are accepted and fan out. Dispatch: `:single`
arity produces ONE Step per receiver member (a list run yields N
receipts, each address `<member>_<md5>[.ext]`); `:array`/`:both`
produce ONE vector Step labeled `Default_<md5>` (built with the `list:`
receiver). A member that fails does not fail the run: its receipt
carries the error envelope and `failed_members`/`total_members` counts.
`update: true` cleans and recomputes at the same address; a named-list
run whose list file is newer than a done Step is stale and recomputes
automatically.

The receipt (section 2.7) is `{entity_type, property, receiver,
arguments, definition:{version,digest}, address, result_kind, status,
value (bounded), materialized:{path,bytes}, info_path}` — every field
mechanically derived from the produced Step or the call inputs.

## `cortex_result`  -  resolve an address (never executes)

```
cortex_result(address:, projection: :value|:info|:path, max_bytes: 5000)
```

Resolution: exact literal path → `var/jobs`-prefixed short_path
(`Step.load`) → one recovery pass matching the address's hex tail
(16..32 hex digits) inside `var/jobs/<Type>/<property>/`, reported
loudly in the output (`recovered: true`, `recovered_from: <tail>`) →
structured `ParameterException` listing the candidate labels found in
the directory. Ambiguous tails error with both candidates. Projections
of the SAME resolved Step: `:value` (bounded payload), `:info` (the
full `.info` sidecar, including the identity inputs), `:path` (the PATH
STRING itself, not file content — hand it to a probe or a downstream
`dep`).

---

## `cortex_activity`  -  recall everything around one entity

Read-only join over existing stores: for one `entity_type`/`entity` it
reports the properties defined for that type, the materialized results
under `var/jobs` for that exact entity (current evidence, tagged
`step_info`), the legacy execution records that mention it (history,
tagged `registry_history`), the named lists of that type containing the
entity, and the conversations/briefs/artifacts that mention the entity
id. Result payloads are never included: follow up with
`cortex_result(address)` to inspect the evidence. `facets` selects
sections (comma-separated; empty means all, in a fixed order), `limit`
caps items per section. Identical inputs over an identical workspace
produce identical output. Deterministic text matching only: no LLM, no
semantic ranking, no entity extraction.

Reading the result:

- Section meta: `total` is the facet's full count, `shown` is what the
  `limit` actually returned, `has_more` is true when shown < total. This
  is how you tell "only three investigations exist" from "twenty exist,
  three shown" (raise `limit` or query `cortex_list type=properties` for
  the rest).
- `investigations[].status` separates the historical fact from the
  current capability: `active` (re-runnable now, recorded definition
  version is current), `older` (a newer definition version is current;
  the recorded `definition_digest` identifies the code that produced the
  recorded evidence), `removed` (definition was removed; the record is
  history only, re-define before re-running).
- `mentions` are raw lexical matches and a discovery hint only: hits
  include incidental occurrences (tool-call transcripts, table rows).
  Never infer presence, absence, importance or scientific relevance from
  the mention count — read the underlying resource.
- Map identifiers are bare (`current`, `lib`, ...), the same
  representation as the `map` column of `cortex_list`.

## Caching note

Like every Scout task, results are cached per input combination. Property
results are content-addressed: the same (definition identity, argument
set, receiver, dependencies) always lands on the same address, and a
done Step is reused without recomputation. If the workspace changed
since a previous identical call, use a different input (e.g. a
different `offset`/`limit`) or clear the job.

Named-list exceptions: if a `cortex_write_list`-managed list file
changes after a `cortex_property_run` run, the next identical call
detects the stale jobs by mtime and recomputes automatically.
