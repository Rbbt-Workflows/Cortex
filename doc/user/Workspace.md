# The Cortex Workspace

This page explains the Cortex workspace: what lives where, and what the three
kinds of research objects are.

**You should read this if:** you use `cortex_continue`, `cortex_brief`, or any
`cortex_*` tool, or you want to inspect `var/cortex/` directly.

---

## Four namespaces

Cortex keeps everything under `var/cortex/`:

| Namespace | Directory | What it is |
|-----------|-----------|------------|
| **Conversations** | `var/cortex/conversations/` | Working space: named chats that agents extend turn by turn |
| **Briefs** | `var/cortex/briefs/` | Standing instructions that make an agent work a certain way |
| **Artifacts** | `var/cortex/artifacts/` | Durable research objects: results extracted from conversations |
| **Entities** | `var/cortex/entities/` | Executable entity properties: versioned code that computes evidence |

The separation is enforced by the code:

- A brief can only be loaded from `briefs/`. Using a regular conversation as
  a brief fails with an explicit error; there is no fallback.
- `cortex_brief` writes only to `briefs/`. `cortex_continue` writes only to
  `conversations/`.
- Artifacts can only be created with `cortex_write` (or by hand under
  `artifacts/`); they are never chat files.
- Entity properties are defined and updated only through the property tools
  (`cortex_property_define`, `_update`, `_remove`); the generic write/edit
  tools do not apply to executable definitions.

## Conversations

A conversation is a plain Scout chat file. Each turn saved by `cortex_continue`
appends a `meta:` line carrying the job that produced it, so a conversation is
self-documenting provenance:

```
user:
Investigate the composite C42.
meta:
job=Cortex/continue/Default_6c8b....chat
assistant:
...
```

Conversations grow without bound and can become large. Use the bounded read
options (`last`, `range`) instead of reading them whole.

## Briefs

A brief is a standing instruction set for an agent, e.g. "always compute sums
with bash, not mental math". A brief is created once with `cortex_brief` and
then referenced whenever that behavior is wanted:

```
agent: "Worker/bash-math"
```

The brief name does not need to contain the agent name. `Worker/bash-math`
means "agent `Worker`, briefed with the brief named `bash-math`", and
`bash-math` is stored in `briefs/` regardless of which agent it was written
for. The agent the brief was created for is recorded in the sidecar
`briefs/.meta/<name>.json`:

```json
{"agent":"Worker","job":"Cortex/continue/Default_ee73....chat","timestamp":"2026-08-24 23:09:16"}
```

## Artifacts

An artifact is a durable result: a claim, a dossier, a table, a report. The
rule of thumb:

> Conversations are working space. Artifacts are durable research objects.
> When an investigation produces a reusable result, write it as an artifact.

Artifacts are plain files under `artifacts/`, with automatic provenance
sidecars under `artifacts/.meta/` and version snapshots under
`artifacts/.history/`:

```
var/cortex/artifacts/
  summing/answer.md            <- current content
  .meta/summing/answer.md.json <- who wrote each version (job, agent, timestamp)
  .history/summing/answer.md/  <- prior versions, never discarded
```

## Entities

An entity property is *executable* evidence: versioned Ruby code plus a
metadata interface, addressed `entities/<Type>/<property>` (e.g.
`Gene/activity_in_treatment`). Executing it for an entity produces a real,
cacheable Scout Step; the receipt names that step as the provenance of the
number.

```
var/cortex/entities/
  Gene/activity_in_treatment.rb        <- trusted Ruby body
  .meta/Gene/activity_in_treatment.json <- schema v1: arguments, deps, digest
  .history/Gene/activity_in_treatment/  <- prior versions, never discarded
```

Discovery is `cortex_property_list` (definitions are not in `cortex_search`).
The discipline: never transcribe a number by hand when a property can return
it — cite the property job instead.

## The rule of thumb for growing research

1. Brief your agents once (`cortex_brief`) so they have standing instructions.
2. Work in conversations (`cortex_continue`); let them accumulate turns and
   `meta: job=` provenance lines.
3. Extract durable results with `cortex_write`.
4. Navigate with `cortex_list` and `cortex_search`; retrieve with
   `cortex_read`.

## A word on caching

Cortex builds each agent's context as: stable agent prefix (instructions,
brief, Cortex tools), then the conversation, then the current prompt. The
prefix stays identical across turns of the same agent, so providers that
cache request prefixes reuse it. That is why Cortex never injects workspace
listings into prompts; the workspace is discovered through tools instead.
