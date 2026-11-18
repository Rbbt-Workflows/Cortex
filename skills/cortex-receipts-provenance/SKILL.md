---
name: cortex-receipts-provenance
description: Read Cortex delegation receipts and artifact provenance records - the meta/job receipt shape returned by cortex_continue and cortex_brief, the job= meta lines inside conversations, and the .info version records beside artifacts - and follow a job reference to the full child execution. Use when you must cite who produced a result, audit a delegation chain, verify an artifact version history, or recover what a delegated agent actually did. Triggers cortex_continue receipt, cortex_brief receipt, job=Cortex/continue, meta job reference, who produced this, artifact .info, version history, provenance edge, follow the job, audit delegation.
---

# Cortex receipts and provenance

## What this skill covers

Reading and using the three provenance surfaces Cortex produces — the
delegation receipt, the `meta: job=` lines inside conversations, and the
`.info` version records beside artifacts — and following a job reference
to the complete child execution. The contract details live in
[Cortex/doc/user/Receipts.md](../../doc/user/Receipts.md); this skill is
the when-and-how operational guidance.

## The receipt shape (read it correctly)

`cortex_continue` and `cortex_brief` (with `reply: true`) return:

```json
{ "content": "The agent's answer text.", "meta": [{"job": "Cortex/continue/Default_….chat"}] }
```

- `content` is the answer; `meta[0].job` is the provenance edge — a foreign
  key into `var/jobs/Cortex/continue/…`, not a summary of the work.
- `cortex_brief` with `reply: false` (the default) runs no inference and
  returns `{content: "Conversation saved"}` — there is no `meta` to follow.
- A receipt proves *where* a result came from, not that it is correct;
  consequential results still need their own verification.

## Where receipts land (all reference the same jobs)

1. **Caller chat** — the `function_call_output` envelope carries the
   receipt under `meta`, so an orchestrating conversation records the edge.
2. **Workspace conversation** — each persisted turn includes a
   `meta: job=Cortex/continue/…` line; provenance is inline in the file.
3. **Brief sidecar** — `briefs/<name>.info` records agent, job, timestamp.
4. **Artifact sidecar** — `artifacts/<path>.info` accumulates one version
   record per write/edit/rename/move: `{job, agent, mode, timestamp, size}`,
   with prior content snapshotted under `<path>.files/history/`.

## Following a job reference

Given `job=Cortex/continue/Default_965e….chat`:

1. The path resolves under the jobs tree (`Scout.var.jobs`; chat jobs
   typically `~/.scout/var/jobs` on a workstation, the checkout `var/jobs`
   in a sandboxed checkout).
2. The `.chat` file is the full child conversation — every nested tool
   call and output the delegated agent made.
3. The sibling job directory (`….files/`, `log/`) holds artifacts the
   child wrote and the agent log.
4. Programmatically: `Step.load('Cortex/continue/Default_965e….chat')`
   gives `.info`, `.dependencies`, `.load`.

For a tool-call view without replaying anything, ChatAnalyst's
`job_overview` / `chat_tool_calls` work directly on such job roots.

## Attribution discipline

- Cite the job reference (or the artifact `.info` version) when reporting a
  delegated result — `content` alone is a transcription, not provenance.
- Artifact versions are cumulative: an `.info` with several records means
   several edits; the *last* record names the current content's producer,
   and history entries hold the earlier texts.
- Two jobs are distinct in every receipt: `meta[0].job` names the `continue`
  execution (the agent run); the wrapper `Cortex/cortex_continue/…json` is
  a projection around it. Attribute the work to the `continue` job.

## Common mistakes

- Calling the receipt `agent_meta` — the task result uses `meta`; the older
  envelope vocabulary predates the current scout-ai dispatcher.
- Expecting `reply: false` briefs to return a job — nothing ran.
- Copying the child's answer into the parent conversation wholesale — the
  edge suffices; retrieve with bounded reads when needed.
- Reading `content` as proof of correctness — the job proves execution,
  not validity.
- Hand-inspecting `var/cortex/artifacts/*.info` and expecting chat
  semantics — `.info` is JSON sidecar metadata, not a conversation.

## Going deeper (repo-relative pointers, optional)

- [Cortex/doc/user/Receipts.md](../../doc/user/Receipts.md) — the full
  contract, worked examples, following receipts.
- [Cortex/doc/developer/Receipts.md](../../doc/developer/Receipts.md) —
  implementation, all four landing surfaces, invariants.
- [Cortex/doc/user/Conversations.md](../../doc/user/Conversations.md) —
  `meta:` lines inside conversations, where each call writes.
