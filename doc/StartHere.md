# Start Here

Cortex is a persistent research workspace for Scout-AI agents. It keeps named
conversations, agent briefs, durable artifacts, and executable entity
properties under `var/cortex/` organized in four namespaces
(`conversations/`, `briefs/`, `artifacts/`, `entities/` with `.meta/`
provenance and `.history/` versions), and exposes eighteen tools
(`cortex_continue`, `cortex_brief`, `cortex_list`, `cortex_search`,
`cortex_read`, `cortex_write`, `cortex_edit`, `cortex_rename`,
`cortex_remove`, `cortex_move`, plus the property tools
`cortex_property_list`, `cortex_property_read`, `cortex_property_history`,
`cortex_property_validate`, `cortex_property_define`,
`cortex_property_update`, `cortex_property_remove`, and
`cortex_entity_property`) that any agent gets automatically when working
through Cortex. `continue_chat` and `brief_agent` remain as compatibility
aliases of the first two.

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
provenance, tool exposure, the receipt mechanism, and the
[Cortex-managed entities](developer/Entities.md) engine.

### I want to know why it looks like this

Read [research/](research/): design decisions (including the
workspace-management pass), findings, the archived invariant test run, and
the critique record.
