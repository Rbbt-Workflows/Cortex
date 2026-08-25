# Start Here

Cortex is a persistent research workspace for Scout-AI agents. It keeps named
conversations, agent briefs, and durable artifacts under `var/cortex/`
organized in three namespaces (`conversations/`, `briefs/`, `artifacts/`
with `.meta/` provenance and `.history/` versions), and exposes ten tools
(`cortex_continue`, `cortex_brief`, `cortex_list`, `cortex_search`,
`cortex_read`, `cortex_write`, `cortex_edit`, `cortex_rename`,
`cortex_remove`, `cortex_move`) that any agent gets automatically when
working through Cortex. `continue_chat` and `brief_agent` remain as
compatibility aliases of the first two.

Cortex is a thin layer over scout-ai's `AgentWorkflow`: the only inference
primitive is a `chat_task` called `continue`; everything else is storage,
navigation, management, and provenance.

## Choose your path

### I want to run agents inside Cortex conversations

Read the [user documentation](user/). It explains the workspace layout,
briefing agents, continuing conversations, searching and reading research
objects, writing and managing artifacts, and following delegation receipts.

### I want to change how Cortex works

Read the [developer documentation](developer/). It covers the architecture,
the path-map storage abstraction behind all tools, artifact versioning and
provenance, tool exposure, and the receipt mechanism.

### I want to know why it looks like this

Read [research/](research/): design decisions (including the
workspace-management pass), findings, the archived invariant test run, and
the critique record.
