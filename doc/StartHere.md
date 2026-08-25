# Start Here

Cortex is a persistent research workspace for Scout-AI agents. It keeps named
conversations, agent briefs, and durable artifacts under
`var/cortex/`, and exposes a small set of tools (`continue_chat`,
`brief_agent`, `cortex_list`, `cortex_search`, `cortex_read`, `cortex_write`)
that any agent gets automatically when working through Cortex.

Cortex is a thin layer over scout-ai's `AgentWorkflow`: the only inference
primitive is a `chat_task` called `continue`; everything else is storage,
navigation, and provenance.

## Choose your path

### I want to run agents inside Cortex conversations

Read the [user documentation](user/). It explains the workspace layout,
briefing agents, continuing conversations, searching and reading research
objects, writing artifacts, and following delegation receipts.

**Start with:**
1. [user/Workspace.md](user/Workspace.md)  -  the three namespaces and where
   things live.
2. [user/Conversations.md](user/Conversations.md)  -  briefing agents and
   continuing conversations.
3. [user/WorkspaceTools.md](user/WorkspaceTools.md)  -  list, search, read,
   write.
4. [user/Receipts.md](user/Receipts.md)  -  the `agent_meta` job receipts and
   how to follow them.

### I want to modify or extend Cortex

Read the [developer documentation](developer/). It documents the workflow
structure, namespace implementation, artifact provenance and versioning,
tool-exposure mechanics, and the frozen receipt contract.

**Start with:**
1. [developer/Architecture.md](developer/Architecture.md)  -  module layout,
   module methods vs. helpers, execution flow.
2. [developer/Workspace.md](developer/Workspace.md)  -  namespaces, listings,
   search, bounded reads, artifact writes.
3. [developer/ToolExposure.md](developer/ToolExposure.md)  -  how tasks become
   agent tools.
4. [developer/Receipts.md](developer/Receipts.md)  -  the receipt contract and
   provenance chain.

### I want to understand how Cortex was designed and why

Read the `research/` notes at the repository root. They are investigation records from
the design and implementation of the workspace milestone: design decisions,
refactor notes, tool notes, the recorded end-to-end validation run, and the
critique. They are not maintained documentation.
