---
name: cortex-workspace-persistence
description: Decide where work should live in the Cortex persistent workspace - named conversations for ongoing reasoning, briefs for reusable agent preparation and provisioned tooling, artifacts for durable versioned results - versus ordinary project files. Use when an agent bout produces findings worth keeping across sessions, when preparing a specialist agent for repeated delegation, or when deciding whether to consolidate, promote, or retire workspace material. Triggers cortex_continue, cortex_brief, cortex_write, cortex_edit, cortex_list, cortex_search, cortex_read, cortex_rename, cortex_move, cortex_remove, persist this, save for later sessions, durable result, agent preparation, brief an agent, cross-session, workspace upkeep.
---

# Cortex workspace persistence decisions

## What this skill covers

Operational decision guidance for the ten `cortex_*` tools: which resource
kind a piece of work belongs in, when to use the workspace at all versus
project files, and the promotion ladder between tiers. It does not repeat
the tool reference — that lives in
[Cortex/doc/user/WorkspaceTools.md](../../doc/user/WorkspaceTools.md).

## The default test: will anyone need this again?

- **No** (routine answer, one-off computation inside an approved scope):
  reply and finish. Persistence is not a virtue by itself.
- **Yes, by me in this investigation** (working reasoning, hypotheses,
  failed branches) → a **conversation** (`cortex_continue` appends the turn
  plus its `meta: job=` provenance line).
- **Yes, by another agent or a later session** (finding, decision, dossier,
  analysis) → an **artifact** (`cortex_write`), then reference the artifact
  from the conversation instead of restating the content.
- **Yes, every time I delegate to this agent** (standing instructions,
  provisioned tooling) → a **brief** (`cortex_brief`), then invoke the
  agent as `Agent/<brief>`.

The rule of thumb: conversations are working space; artifacts are durable
research objects. An important conclusion that lives only in a
conversation is at risk — extract it.

## Conversations vs artifacts vs project files

| Signal | Destination |
|---|---|
| Messy exploratory reasoning, still changing | conversation |
| Settled finding with evidence paths | artifact |
| Discussion of *how* an agent should work | brief |
| Code, tests, workflow definitions, config | project files (git), not Cortex |
| Reviewed operating authority | `doc/` in the repo, not Cortex |

Never store project source or configuration as Cortex artifacts: those have
their own review and version-control path. Cortex artifacts carry research
meaning (findings, claims, analyses) with provenance, not file backups.

## Conversation hygiene

- One investigation per named conversation; a new unrelated question gets a
  new conversation. Carry over only conclusions, preferably as artifact
  references.
- A conversation is not owned by one agent: each `cortex_continue` turn
  states which agent (optionally `Agent/<brief>`) contributed, and every
  turn appends its own `meta: job=` line.
- Conversations grow unboundedly — read with `last`/`range` slices, never
  whole-file reads of a long chat.

## When to consolidate (upkeep triggers)

Run upkeep when: a topic concludes; a new bout of work starts and prior
material must be trusted; duplicates or divergent artifacts have appeared.

1. `cortex_list` the namespace, then `cortex_read` the candidates — never
   trust a conversation's mention of an artifact as proof it exists.
2. Extract anything still only-in-a-conversation into an artifact.
3. `cortex_edit` stale statements rather than rewriting whole artifacts;
   history is snapshotted automatically under `<name>.files/history/`.
4. Merge duplicates by keeping the better name, then `cortex_remove` the
   loser — removal is irreversible and also deletes `.info`/history.
5. Retire obsolete material deliberately; do not bulk-delete on suspicion.

Briefs and artifacts move with their metadata: `cortex_rename` (same map,
new logical name) and `cortex_move` (between path maps) carry `.info` and
`.files/` along.

## Common mistakes

- Persisting every routine answer — workspace overhead without reuse value.
- Transcribing findings into chat only, then losing them at compaction.
- Writing an artifact by hand under `var/cortex/artifacts/` instead of
  using `cortex_write` — no `.info` provenance, no history.
- Continuing a *brief* with `cortex_continue` — briefs and conversations
  are separate namespaces; both confusions raise explicit errors.
- Editing storage directly instead of through the tools (rename/move/remove
  semantics keep sidecars consistent; hand edits orphan them).

## Going deeper (repo-relative pointers, optional)

- [Cortex/doc/user/Conversations.md](../../doc/user/Conversations.md) —
  briefing, continuing, multi-agent conversations, where things land.
- [Cortex/doc/user/Workspace.md](../../doc/user/Workspace.md) — the three
  namespaces, sidecars, growth pattern, caching.
- [Cortex/doc/user/WorkspaceTools.md](../../doc/user/WorkspaceTools.md) —
  full tool reference and the tool-spec grammar.
