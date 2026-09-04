# Cortex design decisions (workspace milestone)

> Historical note: early records in this file use the original task names
> `continue_chat`/`brief_agent`; those were renamed to `cortex_continue`/
> `cortex_brief` and the old names no longer exist. Read them as the
> canonical names.

This note records the design decisions taken for the Cortex workspace
milestone. It is a research note, not maintained documentation; user and
developer docs come later in their own work items.

## Scope

Cortex is a thin, filesystem-like research layer over `AgentWorkflow`. It holds
named conversations, agent briefs, and (next work item) artifacts. It exposes
`continue_chat` and `brief_agent` as agent-facing tools and keeps the
`agent_meta` receipt contract frozen. Out of scope: entity/ontology tooling,
semantic search, auto-injection of context, NER, AGS tooling (see deferred
items).

## Namespace layout under `var/cortex/`

- `conversations/<name>` : regular research conversations (plain chat files,
  current format, one file per conversation).
- `briefs/<name>` : agent briefs (chat files). Alongside them,
  `briefs/.meta/<name>.json` records the agent name the brief was created for
  plus provenance (creating/updating job short_path and timestamp).
- `artifacts/<name>` + `artifacts/.meta/<name>.json` +
  `artifacts/.history/<name>/<version>` : durable research objects with
  provenance sidecar and non-destructive version history. Implemented in the
  NEXT work item; recorded here for completeness.
- Dot-directories (`.meta`, `.history`) are excluded from any listing produced
  by future workspace tools.

Names are used verbatim in their namespace. In particular, brief names no
longer embed the agent name: the agent is recorded in the `.meta` sidecar, not
in the stored file name.

## Brief resolution rules

- The `agent` input keeps the `Agent/brief` syntax (e.g. `Worker/math` = agent
  `Worker`, brief `math`). It is parsed with `partition('/')`.
- The brief is loaded ONLY from `briefs/<brief>`. There is NEVER a fallback to
  regular conversations.
- If `briefs/<brief>` is missing or empty, raise `ScoutException` with an
  actionable message:
  - `No brief <name> for agent <agent>. Available briefs: <names>` when other
    briefs exist;
  - `No brief <name> for agent <agent>. No briefs exist yet; create one with brief_agent (workflow Cortex, task brief_agent)` when none exist.
- If `var/cortex/conversations/<brief>` exists but `briefs/<brief>` does not,
  the error says so explicitly (a conversation is not a brief).
- Legacy tolerance is ERROR-ONLY: if `briefs/<brief>` is missing but an
  old-style `var/cortex/<Agent>/<brief>` file exists, the error message mentions
  it ("legacy location found; recreate the brief with brief_agent") but the
  legacy file is never loaded silently.

## Task semantics

- `brief_agent(conversation:, prompt:, agent:)` creates or updates
  `briefs/<conversation>` and its `.meta` sidecar. Its dependency chat is
  prompt-only on CREATION; on update it grows with the existing brief.
- `continue_chat(conversation:, prompt:, agent:)` reads and writes
  `conversations/<conversation>` only.
- The duplicated `dep :continue, chat: :placeholder` block is factored into a
  single helper that builds the dependency chat from the right namespace
  (loads `conversations/<name>` for `continue_chat`; for `brief_agent` it is
  prompt-only on creation and grows with the existing brief on update).

## Input descriptions (they become tool docs)

- `agent`: `Agent name; optionally Agent/brief_name to load a brief stored in the Cortex briefs namespace (e.g. Worker/math loads brief math for agent Worker)`
- `continue_chat` conversation: `Conversation name in the Cortex conversations namespace`
- `brief_agent` conversation: `Brief name in the Cortex briefs namespace; it does not need to contain the agent name`

## Clean break, no migration

The pre-existing data `var/cortex/Summing` and `var/cortex/Worker/math` was
disposable test data produced while the brief name had to be prefixed with the
agent name. Carrying it forward would require migration code that silently
rewrites names across namespaces for data with no value. Decision: clean break.
Old-style `var/cortex/<Agent>/<brief>` files are NOT migrated and NOT loaded;
they are only mentioned in error hints. No migration code is added.

## Frozen receipt contract

`continue_chat` and `brief_agent` return exactly:

```
{agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
```

No new fields. `job` remains the foreign key used by
`Chat.agent_meta_job_references` and the scout-ai tool-call bookkeeping. This
is a contract with scout-ai (read-only here) and must not be enlarged in this
repo.

## Cache topology

Unchanged: stable agent prefix (tooling + brief), then conversation content,
then prompt. No dynamic inventories in the prefix. The dependency job name
derives from `(conversation, prompt)`; namespace directories do not enter the
job name, so job addressing stays flat and stable.

## Planned cortex_* tool surface (next work item)

Brief descriptions only; names are prefixed `cortex_` to avoid collisions:

- `cortex_list` : list conversations/briefs/artifacts with compact metadata
  (name, size, date, message count) and scoping filters; excludes dot-dirs.
- `cortex_read` : bounded reads of a conversation or artifact
  (from/to/last N).
- `cortex_search` : lexical search over stored content, compact snippets.
- `cortex_write` : write an artifact with automatic provenance sidecar and
  non-destructive version history; returns a tiny confirmation (path, size),
  never re-injects content.

## Deferred items

- Entities/ontology, semantic search, auto-injection of context, NER, AGS
  tooling: explicitly out of scope for this milestone.
- Full `doc/user` and `doc/developer` documentation: separate work item.
- End-to-end LLM validation (brief_agent then continue_chat with the brief):
  validation work item; this item smoke-tests helpers and error paths without
  inference unless a cheap call is available.
