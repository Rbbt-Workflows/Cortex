# Receipts and Provenance

This page explains the delegation receipt contract and how to follow
provenance from a conversation back to the job that produced each turn.

**You should read this if:** you call `cortex_continue`/`cortex_brief` from
another agent and want to account for the work performed, or you audit
Cortex conversations.



> **Naming:** `cortex_continue`/`cortex_brief` were originally called
> `continue_chat`/`brief_agent` during development; the current names are
> the only ones ever exported.
---

## The receipt contract

`cortex_continue` and `cortex_brief` return exactly:

```json
{
  "agent_meta": [{"role": "meta", "content": "job=Cortex/continue/Default_....chat"}],
  "content": "The agent's answer text."
}
```

- `content` is the semantic result: the agent's answer.
- `agent_meta` carries the **job** that produced it. The job is a foreign
  key; everything else (the full child chat, tool calls, artifacts, token
  counts) can be obtained by following it.

The receipt is deliberately minimal. Do not add timestamps or artifact lists
to it; the job knows all of that.

## How receipts appear to a calling agent

When `cortex_continue` is used as a tool, the caller's conversation records a
function call and its output carrying the receipt:

```
function_call: {"name":"cortex_continue","arguments":{...},"id":"call_..."}
function_call_output: {"name":"cortex_continue","content":"The agent's answer...",
  "agent_meta":[{"role":"meta","content":"job=Cortex/continue/Default_....chat"}],
  "step":"Cortex/cortex_continue/Default_....json"}
```

This is what makes an orchestrating conversation auditable: every delegation
leaves an explicit edge to its execution.

## Provenance inside conversations

Each turn persisted by `cortex_continue` into `conversations/<name>` also
carries the producing job inline:

```
user:
Solve the sum proposed earlier in this conversation.
meta:
job=Cortex/continue/Default_965e....chat
assistant:
...
```

So both directions work: from a receipt in the caller, and from a `meta:`
line inside the conversation.

## Following a receipt

Given `job=Cortex/continue/Default_965e....chat`:

1. The path is under `Scout.var.jobs` (typically `~/.scout/var/jobs`).
2. The chat file itself is the full child conversation including all tool
   calls and outputs.
3. The sibling job directory (`.../Default_965e....files/`) holds artifacts
   the child wrote during that turn, and `.../log/` holds agent logs written
   automatically by `chat_task`'s `log_agent`.
4. `Step.load(short_path)` loads the step in Ruby for programmatic
   inspection (`.info`, `.dependencies`, `.load`).

Artifact provenance works the same way: `artifacts/.meta/<path>.json`
records the `job` of each version, e.g. the `cortex_write` job, along with
`agent`, `mode`, `timestamp`, and `size`.

## What this buys you

- An orchestrator can report "this conclusion came from job X" without
  loading the child's context.
- An analyst can reconstruct the full work graph by following `meta:` lines
  and receipts; no directory scanning or guessing.
- Conversations stay compact: they reference work rather than embed it.
