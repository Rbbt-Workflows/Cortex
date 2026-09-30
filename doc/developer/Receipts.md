# Receipts and Provenance

This page documents the delegation receipt contract, its implementation, and
the provenance chains across conversations, briefs, artifacts, and jobs.

**You should read this if:** you are changing `cortex_continue`, `cortex_brief`,
or anything that touches continuation receipt metadata.

---

## The contract

`cortex_continue` returns this task-result Hash. `cortex_brief` returns the
same shape with `reply: true`:

```ruby
{meta: [{job: continue.short_path}], content: res.answer}
```

The continuation task returns a Hash with `content` (the agent's answer) and
`meta` (an array of plain field Hashes carrying the `continue` dependency's
job reference). This is the task return value, before caller-side tool-output
normalization.

When invoked through Scout-AI's workflow tool dispatcher, the caller receives
a `function_call_output` message whose JSON `content` is an envelope. For this
continuation result, the envelope carries the answer under `content` and the
receipt under `meta`; the dispatcher also supplies the tool `name` and call
`id`, and for a workflow Step supplies `step`, `start_timestamp`, and
`timestamp`. The receipt's child-job reference and the `step` wrapper-job
reference are distinct. This documents the caller tool-output envelope, not
any subsequent user-facing assistant response.

With `cortex_brief` and `reply: false`, the task saves the brief without
inference and returns `{content: 'Conversation saved'}` instead.

The continuation `job` is a foreign key. The child job holds the complete
execution: the full chat including every tool call and output, the nested tool
jobs it spawned, its `log/` directory (written by `AgentWorkflow#log_agent`),
and its `.files/` artifacts. The continuation task receipt contains the
child-job reference; caller-side envelope fields such as timestamps and the
wrapper `step` are supplied by the dispatcher.

## Why `job` points at `continue`, not the wrapper

`cortex_continue` and `cortex_brief` with `reply: true` are thin projections
over `dep :continue`. The inference, and therefore the provenance, happens
inside `continue` (`Cortex/continue/<id>.chat`). `cortex_brief` with
`reply: false` does not use the inference dependency; it saves the prompt-only
brief and returns `{content: 'Conversation saved'}`. The wrapper's own job
(`Cortex/cortex_continue/<id>.json`) exists too, and its step path is surfaced
by the tool-call machinery as `step:` in the function output; the task receipt's
`meta[0].job` names the execution, not the wrapper projection.

## Where receipts land

1. Tool call: the caller agent's conversation records the function call and
   its output. `lib/scout/llm/tools/call.rb` (scout-ai) recognizes the task-
   result Hash with exactly `content` and `meta`, extracts the answer, and
   attaches the receipt under `meta` in the `function_call_output` envelope,
   so the caller's chat carries the edge to the child job.
2. Workspace conversation: `save_conversation` appends to
   `conversations/<name>` the prompt, then the new messages  -  which include
   a `meta:` message with the same `job=` reference, projected there by
   `Chat.project` inside `chat_task`.
3. Briefs: `save_brief` additionally writes adjacent `briefs/<name>.info`
   (`agent`, `job`, `timestamp`).
4. Artifacts: `write_artifact` appends a version record
   (`job` = the `cortex_write` job, `agent`, `mode`, `timestamp`, `size`)
   to adjacent `artifacts/<path>.info` and snapshots prior content under
   `artifacts/<path>.files/history/`.

So four independent surfaces reference the same jobs: caller chat, workspace
conversation, brief sidecar, artifact meta.

## Following provenance (implementation notes)

- `Chat.serialize_meta(job: short_path)` produces the `key=value` string;
  `Chat.parse_meta` reverses it. Scout-AI also has chat evidence helpers for
  harvesting job references from a chat programmatically.
- A `job=Cortex/continue/<id>.chat` string relocates with
  `Step.load('Cortex/continue/<id>.chat')`, which resolves under
  `Scout.var.jobs`; from there `.info`, `.dependencies`, `.load`, and the
  sibling job directory (`.files/`, `log/`) are available.
- The `continue` chat file is saved as the job's `:chat` result; loading it
  gives the full child conversation.
- `update_info :dependencies` runs inside `log_agent`, tying the agent log
  to the workflow dependency graph.

## Invariants

- The continuation task result uses `{meta: [{job: short_path}], content: answer}`;
  the workflow-tool caller envelope carries its receipt under `meta` and adds
  caller fields such as the wrapper `step` and timestamps.
- Only `chat_task :continue` performs inference; projections must not create
  agents, so every receipted answer traces to exactly one logged agent
  execution.
- Never persist the full child chat into the parent conversation  -  the edge
  suffices; bounded retrieval (`cortex_read`) fetches content on demand.
