# Conversations and Briefs

This page explains how to create agent briefs and how to run conversations in
Cortex.

**You should read this if:** you delegate work to agents through Cortex
(`cortex_brief`, `cortex_continue`).



> **Naming:** `cortex_continue`/`cortex_brief` were originally called
> `continue_chat`/`brief_agent` during development; the current names are
> the only ones ever exported.
---

## Briefing an agent

`cortex_brief` creates (or extends) a named brief and runs the agent on it
once so the brief is an actual accepted conversation, not just a wish:

```
cortex_brief(
  conversation: "bash-math",
  prompt: "You are a math worker. When asked to compute any sum, always use bash arithmetic rather than mental math.",
  agent: "Worker"
)
```

- `conversation` is the brief name. It does not need to contain the agent
  name  -  store it under whatever name you will remember.
- `agent` is the agent that will hold the brief and that the brief is
  recorded for in `briefs/.meta/<name>.json`.
- `tools` (optional) provisions the brief's tooling: a JSON array of spec
  strings in `"Workflow [task [input|name=value ...]]"` form, e.g.
  `["ScoutCoder help_workflow", "Baking"]`. The specs are expanded into
  `tool:` / `introduce:` chat messages persisted at the top of the brief
  body, so the agent later invoked as `Agent/<brief>` through
  `cortex_continue` receives exactly the provisioned tools (plus the
  framework's own mandatory `tool: Cortex` entry). Giving `tools` replaces
  the brief's entire tool block; `tools: []` strips all tooling; omitting
  `tools` leaves the existing tooling untouched. The full grammar (whole
  workflow, one task, input restriction, `name=value` defaults,
  `noinputs`) is documented with the `cortex_brief` parameters in
  [WorkspaceTools.md](WorkspaceTools.md).
- The task returns `{agent_meta: [...job...], content: <answer>}`: a receipt
  pointing at the `Cortex/continue` job that produced the brief, plus the
  agent's acknowledgment.

The brief is saved to `var/cortex/briefs/<name>` and is never read from the
conversations namespace.

## Continuing a conversation

`cortex_continue` appends a prompt to a named conversation, runs an agent on
it, and persists the grown conversation:

```
cortex_continue(
  conversation: "Summing",
  prompt: "Propose an interesting arithmetic sum. Do NOT solve it.",
  agent: "Worker"
)
```

If the conversation does not exist it is created. Each call returns
`{agent_meta: [...job...], content: <answer>}` and appends to
`conversations/<name>` a user turn, a `meta: job=Cortex/continue/...` line,
and the agent's messages.

### Choosing the agent

The `agent` parameter accepts:

- `"Worker"`  -  run agent `Worker` with no brief.
- `"Worker/bash-math"`  -  run agent `Worker` with the brief named
  `bash-math` from `briefs/`; the brief's provisioned tooling (if any)
  travels with it, so the agent carries exactly those tools plus the
  framework's own mandatory `tool: Cortex` entry.

If the brief does not exist, the call fails with `No brief 'bash-math'`
(plus the list of existing briefs) rather than silently running an unbriefed
agent or falling back to a conversation of the same name.

### Multiple agents in one conversation

A conversation is not owned by one agent; each turn states which agent
contributed:

```
cortex_continue(conversation: "Summing", prompt: "Propose a sum, do not solve it", agent: "Worker")
cortex_continue(conversation: "Summing", prompt: "Solve the sum", agent: "Worker/bash-math")
```

The conversation accumulates both turns, each with its own `meta: job=` line.

## What NOT to expect

- Briefs are not conversations. You cannot continue a brief with
  `cortex_continue` (it would look in `conversations/` and not find it), and
  you cannot brief an agent with a regular conversation (explicit error).
- A conversation is not provenance on its own. The `meta: job=` lines inside
  it are the links to the full child executions; see
  [Receipts.md](Receipts.md).

## Where things land

| Call | Writes to | Sidecar |
|------|-----------|---------|
| `cortex_brief` | `var/cortex/briefs/<name>` | `briefs/.meta/<name>.json` (agent, job, timestamp) |
| `cortex_continue` | `var/cortex/conversations/<name>` | none (provenance is the `meta:` lines inside) |
| `cortex_write` | `var/cortex/artifacts/<path>` | `artifacts/.meta/<path>.json` + `.history/` snapshots |
