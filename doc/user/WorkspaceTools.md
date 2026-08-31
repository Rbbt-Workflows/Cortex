# Workspace Tools

This page documents the `cortex_*` workspace tools agents use to
navigate, extend, and manage the Cortex workspace, the two named-list
tools (`cortex_write_list` / `cortex_read_list`), and the eight
`cortex_property*` / `cortex_entity_property` tools for executable entity
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
7. `cortex_property_list` / `cortex_property_read` / `cortex_property_validate`
   — discover and inspect entity properties
8. `cortex_property_define` / `_update` / `_remove` — version executable
   definitions (never generic write/edit)
9. `cortex_entity_property` — execute a property and get an evidence receipt
   citing the producing job
10. `cortex_list type=properties` — see which entities/properties have
    already been investigated, with which arguments
11. `cortex_write_list` / `cortex_read_list` — name entity lists once and
    run properties over them by reference
12. `cortex_activity` — deterministic recall of everything already known
    about ONE entity (defined properties, examinations, containing lists,
    mentions); no LLM, no recomputation

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
  `cortex_list type=lists`) and pass it as `list:`. Inline JSON arrays
  still execute, but for more than three members the receipt carries a
  `note` steering you back to named lists: they keep execution records
  legible, carry `entity_options`, and are indexed per member.
- Before running anything, check `cortex_list type=properties`: an
  already-investigated question shows up there with its arguments and
  producing jobs.

---

## `cortex_continue`  -  contribute to a conversation

Continues a named research conversation. This is the canonical name of the
task previously called `cortex_continue` (kept as an alias with identical
behavior and receipts).

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
cortex_brief(conversation:, prompt:, agent:)
```

`conversation` is the brief name (stored in `briefs/`, never mixed with
regular conversations). Same receipt contract as `cortex_continue`.
Previous canonical name: `cortex_brief`.

## `cortex_list`  -  compact inventory

Lists namespaces and their entries with metadata only. Never returns
contents.

```
cortex_list(type: "all", prefix: "", offset: 0, limit: 50)
```

- `type`: `conversations`, `briefs`, `artifacts`, or `all` (explicit; briefs
  are never implicitly included in `conversations`).
- `prefix`: only entries whose name starts with it.
- `offset` / `limit`: pagination. The section header reports
  `<shown>/<total> entries` and, when more exist, `(more: offset=N)`.

Output shape (the path map is always its own `map` column, right after
`#name`; the `name` column holds the clean logical name, so an entry
existing in several maps simply appears once per map):

```
conversations\t1 entry
  #name\tmap\tmessages\tbytes\tmtime
  Summing\tcurrent\t14\t34578\t2026-08-24 23:10
briefs\t1 entry
  #name\tmap\tmessages\tbytes\tmtime
  bash-math\tcurrent\t3\t391\t2026-08-24 23:09
artifacts\t1 entry
  #name\tmap\tbytes\tmtime
  summing/answer.md\tcurrent\t278\t2026-08-24 23:10
```

## `cortex_search`  -  find material by content

Lexical, case-insensitive, multi-term AND. Single term matches substring;
several terms must all appear in the same resource. Searches all readable
path maps (`:lib`, `:current`).

```
cortex_search(query:, type: "all", limit: 20)
```

- `type`: `all | conversations | briefs | artifacts` (exact interface, no
  implicit expansion).
- `limit`: maximum number of matches.

Returns compact snippets (`#type\tname\tmap\tsnippet`), not full evidence.
Read the resource for the full context.

## `cortex_read`  -  bounded read

Artifacts and conversations, always bounded.

```
cortex_read(type:, name:, last: nil, range: nil, start_line: 1, line_count: 200)
```

- Artifacts: line-based pagination. Response header reports
  `# lines A-B of T (next: B+1)` or `(end)`, plus total byte size; a
  50,000-character safety cap applies on top.
- Conversations: compact per-message index by default; `last` or `range`
  (`"a-b"`, capped at 50k chars) fetch full message content.
- Resolution: readable maps in `[:lib, :current]` order; deterministic
  `:lib` precedence. When a name exists in both maps, the read states the
  ambiguity and shows all physical paths instead of hiding it.

## `cortex_write`  -  create/update an artifact

```
cortex_write(path:, content:, mode: "replace", agent:)
```

- Creates a missing artifact or updates an existing one.
- `mode: "replace"` snapshots the previous version to
  `artifacts/.history/<name>/<timestamp>.<n>`; `mode: "append"` adds to the
  end, creating if absent.
- Records provenance in `artifacts/.meta/<name>.json`: job, agent, mode,
  timestamp, size. No second provenance system — the workflow job is the
  source of truth.
- Returns a one-line confirmation (never the whole content).

## `cortex_edit`  -  surgical text replacement

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

## `cortex_activity`  -  recall everything around one entity

Read-only join over existing stores: for one `entity_type`/`entity` it
reports the properties defined for that type, which of them have already
been examined for that exact entity (with argument combinations, run
counts and the producing job reference), the named lists of that type
containing the entity, and the conversations/briefs/artifacts that mention
the entity id. Result payloads are never included: follow up with
`cortex_entity_property` to obtain them. `facets` selects sections
(comma-separated; empty means all, in a fixed order), `limit` caps items
per section. Identical inputs over an identical workspace produce
identical output. Deterministic text matching only: no LLM, no semantic
ranking, no entity extraction.

Reading the result:

- Section meta: `total` is the facet's full count, `shown` is what the
  `limit` actually returned, `has_more` is true when shown < total. This
  is how you tell "only three investigations exist" from "twenty exist,
  three shown" (raise `limit` or query `cortex_list type=properties` for
  the rest).
- `investigations[].status` separates the historical fact from the current
  capability: `active` (re-runnable now, recorded version is current),
  `older` (a newer definition version is current; the recorded
  `definition_digest` identifies the code that produced the recorded
  evidence), `removed` (definition was removed; the record is history
  only, re-define before re-running).
- `mentions` are raw lexical matches and a discovery hint only: hits
  include incidental occurrences (tool-call transcripts, table rows).
  Never infer presence, absence, importance or scientific relevance from
  the mention count — read the underlying resource.
- Map identifiers are bare (`current`, `lib`, ...), the same
  representation as the `map` column of `cortex_list`.

## Caching note

Like every Scout task, results are cached per input combination. If the
workspace changed since a previous identical call, use a different input
(e.g. a different `offset`/`limit`) or clear the job.

Named-list exceptions: if a `cortex_write_list`-managed list file changes
after a `cortex_entity_property` run, the next identical call detects the
stale jobs by mtime and recomputes automatically.
