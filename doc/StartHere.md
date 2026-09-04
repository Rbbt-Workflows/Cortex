# Start Here

Cortex is a persistent research workspace for Scout-AI agents. It keeps named
conversations, agent briefs, durable artifacts, and executable entity
properties under `var/cortex/` organized in namespaces
(`conversations/`, `briefs/`, `artifacts/`, `entities/`, `lists/` with
`.meta/` provenance and `.history/` versions), and exposes twenty-one tools
(`cortex_continue`, `cortex_brief`, `cortex_list`, `cortex_search`,
`cortex_read`, `cortex_write`, `cortex_edit`, `cortex_rename`,
`cortex_remove`, `cortex_move`, plus the property tools
`cortex_property_list`, `cortex_property_read`, `cortex_property_history`,
`cortex_property_validate`, `cortex_property_define`,
`cortex_property_update`, `cortex_property_remove`, and
`cortex_entity_property`, plus `cortex_write_list`/`cortex_read_list` for
named entity lists and `cortex_activity` for read-only recall around one
entity) that any agent gets automatically when working through Cortex.

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
[Cortex-managed entities](developer/Entities.md) engine. Known gaps and
deliberately deferred work are tracked in
[Improvements](developer/Improvements.md).

### I want to know why it looks like this

Read [research/](research/): design decisions (including the
workspace-management pass), findings, the archived invariant test run, and
the critique record.
