# Receipts and Provenance

This page documents the delegation receipt contract, its implementation, and
the provenance chains across conversations, briefs, artifacts, and jobs.

**You should read this if:** you are changing `continue_chat`, `brief_agent`,
or anything that touches `agent_meta`.

---

## The contract

`continue_chat` and `brief_agent` return exactly this JSON:

```ruby
{agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
```

- `content`  -  the semantic result (the agent's answer).
- `agent_meta`  -  a single meta message whose content is the serialized
  `job=` reference to the `continue` dependency's job.

The `job` is a foreign key. The child job holds the complete execution: the
full chat including every tool call and output, the nested tool jobs it
spawned, its `log/` directory (written by `AgentWorkflow#log_agent`), and
its `.files/` artifacts. The receipt adds nothing else  -  no timestamps, no
agent name, no artifact list  -  deliberately: everything is one `Step.load`
away.

## Why `job` points at `continue`, not the wrapper

`continue_chat` and `brief_agent` are thin projections over
`dep :continue`. The inference, and therefore the provenance, happens inside
`continue` (`Cortex/continue/<id>.chat`). The wrapper's own job
(`Cortex/continue_chat/<id>.json`) exists too, and its step path is surfaced
by the tool-call machinery as `step:` in the function output  -  but the
receipt's `job=` always names the execution, not the projection.

## Where receipts land

1. Tool call: the caller agent's conversation records the function call and
   its output. `lib/scout/llm/tools/call.rb` (scout-ai) recognizes the Hash
   result, extracts `agent_meta`, and attaches it to the
   `function_call_output` message, so the caller's chat carries the edge to
   the child job.
2. Workspace conversation: `save_conversation` appends to
   `conversations/<name>` the prompt, then the new messages  -  which include
   a `meta:` message with the same `job=` reference, projected there by
   `Chat.project` inside `chat_task`.
3. Briefs: `save_brief` additionally writes `briefs/.meta/<name>.json`
   (`agent`, `job`, `timestamp`).
4. Artifacts: `write_artifact` appends a version record
   (`job` = the `cortex_write` job, `agent`, `mode`, `timestamp`, `size`)
   to `artifacts/.meta/<path>.json` and snapshots prior content under
   `artifacts/.history/<path>/`.

So four independent surfaces reference the same jobs: caller chat, workspace
conversation, brief sidecar, artifact meta.

## Following provenance (implementation notes)

- `Chat.serialize_meta(job: short_path)` produces the `key=value` string;
  `Chat.parse_meta` reverses it. `Chat.agent_meta_job_references` /
  `Chat.agent_meta_evidence` (scout-ai) can harvest job references from a
  chat programmatically.
- A `job=Cortex/continue/<id>.chat` string relocates with
  `Step.load('Cortex/continue/<id>.chat')`, which resolves under
  `Scout.var.jobs`; from there `.info`, `.dependencies`, `.load`, and the
  sibling job directory (`.files/`, `log/`) are available.
- The `continue` chat file is saved as the job's `:chat` result; loading it
  gives the full child conversation.
- `update_info :dependencies` runs inside `log_agent`, tying the agent log
  to the workflow dependency graph.

## Invariants

- Receipt shape is frozen: `{agent_meta: [one meta message], content: string}`.
  Enlarging it leaks execution semantics into every caller.
- Only `chat_task :continue` performs inference; projections must not create
  agents, so every receipted answer traces to exactly one logged agent
  execution.
- Never persist the full child chat into the parent conversation  -  the edge
  suffices; bounded retrieval (`cortex_read`) fetches content on demand.
