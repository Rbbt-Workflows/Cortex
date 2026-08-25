# Conversations and Briefs

This page explains how to create agent briefs and how to run conversations in
Cortex.

**You should read this if:** you delegate work to agents through Cortex
(`brief_agent`, `continue_chat`).

---

## Briefing an agent

`brief_agent` creates (or extends) a named brief and runs the agent on it
once so the brief is an actual accepted conversation, not just a wish:

```
brief_agent(
  conversation: "bash-math",
  prompt: "You are a math worker. When asked to compute any sum, always use bash arithmetic rather than mental math.",
  agent: "Worker"
)
```

- `conversation` is the brief name. It does not need to contain the agent
  name  -  store it under whatever name you will remember.
- `agent` is the agent that will hold the brief and that the brief is
  recorded for in `briefs/.meta/<name>.json`.
- The task returns `{agent_meta: [...job...], content: <answer>}`: a receipt
  pointing at the `Cortex/continue` job that produced the brief, plus the
  agent's acknowledgment.

The brief is saved to `var/cortex/briefs/<name>` and is never read from the
conversations namespace.

## Continuing a conversation

`continue_chat` appends a prompt to a named conversation, runs an agent on
it, and persists the grown conversation:

```
continue_chat(
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
  `bash-math` from `briefs/`.

If the brief does not exist, the call fails with `No brief 'bash-math'`
(plus the list of existing briefs) rather than silently running an unbriefed
agent or falling back to a conversation of the same name.

### Multiple agents in one conversation

A conversation is not owned by one agent; each turn states which agent
contributed:

```
continue_chat(conversation: "Summing", prompt: "Propose a sum, do not solve it", agent: "Worker")
continue_chat(conversation: "Summing", prompt: "Solve the sum", agent: "Worker/bash-math")
```

The conversation accumulates both turns, each with its own `meta: job=` line.

## What NOT to expect

- Briefs are not conversations. You cannot continue a brief with
  `continue_chat` (it would look in `conversations/` and not find it), and
  you cannot brief an agent with a regular conversation (explicit error).
- A conversation is not provenance on its own. The `meta: job=` lines inside
  it are the links to the full child executions; see
  [Receipts.md](Receipts.md).

## Where things land

| Call | Writes to | Sidecar |
|------|-----------|---------|
| `brief_agent` | `var/cortex/briefs/<name>` | `briefs/.meta/<name>.json` (agent, job, timestamp) |
| `continue_chat` | `var/cortex/conversations/<name>` | none (provenance is the `meta:` lines inside) |
| `cortex_write` | `var/cortex/artifacts/<path>` | `artifacts/.meta/<path>.json` + `.history/` snapshots |
