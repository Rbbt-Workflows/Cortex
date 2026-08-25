# Tool Exposure

This page documents how Cortex tasks become tools that LLM agents can call.

**You should read this if:** you are adding a task meant to be used by
agents, or wondering why a task is not showing up as a tool.

---

## The mechanism

`load_agent_conversation` ends with:

```ruby
agent.start_chat.tool 'Cortex'
```

That emits a `tool` annotation into the agent's `start_chat`. Scout-AI
parses tool tokens as `[workflow_name, task_name, *inputs]`:

- `tool 'Cortex'` (no task) -> `LLM.workflow_tools(Cortex)` -> **all
  `export`ed tasks become tools**.
- `tool 'Cortex', :task` -> only that task.

So the export line in `workflow.rb` is the tool registry:

```ruby
export :cortex_continue, :cortex_brief, :cortex_list, :cortex_search, :cortex_read, :cortex_write
```

Because every Cortex agent gets `tool 'Cortex'`, every agent working through
Cortex has the full workspace toolset  -  the "all agents always incorporate
Cortex tooling" requirement from the design conversation.

## Tool definitions come from task metadata

`LLM.task_tool_definition` builds each tool's JSON schema from the workflow
definition itself:

- the task `desc` block becomes the tool `description`;
- each `input` becomes a parameter whose description is the input
  description;
- `required: true` inputs land in the schema's `required` array;
- `:select` inputs surface their `select_options` as an enum.

Consequence: `desc` and `input` descriptions ARE the model-facing
documentation. They are written to be self-contained (what it does, what the
output looks like, what to use instead for related needs), and they must not
drift from the implementation.

Verified current tool surface (`LLM.workflow_tools(Cortex)`):

```
cortex_continue: required=[:conversation, :prompt]
cortex_brief:   required=[:conversation, :prompt, :agent]
cortex_list:   required=[]
cortex_search: required=[:query]
cortex_read:   required=[:name, :type]
cortex_write:  required=[:path, :content]
```

## Exported tasks automatically gain `return_path`

Every exported (non-`exec_export`ed) task automatically gains a boolean
`return_path` input. When an agent sets it, the tool returns the persisted
job path instead of the loaded result. This costs nothing to maintain and is
how a caller can obtain a stable reference to a workspace operation.

Tool calls run as real jobs (`LLM.call_workflow`), so every `cortex_*` call
has a `var/jobs/Cortex/<task>/...` job with its own provenance  -  the
`job:` recorded in artifact meta refers to that job.

## Why the toolset must stay stable

The agent prefix (instructions + tooling) is built before the conversation
and is expected to be byte-identical across turns of the same agent so that
providers can cache it. Renaming, removing, or reordering tools (or editing
their descriptions) invalidates that prefix for every cached conversation.
So:

- add tools, do not churn them;
- keep `desc` text stable once agents depend on it;
- never inject dynamic inventories (current workspace listings) into the
  prefix  -  the workspace is discovered through `cortex_list`/`cortex_search`
  instead. This is also why listings live behind tools rather than in the
  prompt.

## Naming conventions

Tasks are prefixed `cortex_` so that a model that has loaded several
workflows' tools sees unambiguous names (`cortex_read` vs a hypothetical
`Workflow/read`). `cortex_continue` and `cortex_brief` keep their historical
names because they predate the convention and are referenced across
conversations and docs.

Adding a task checklist:

1. Write a `desc` that a model can act on without reading the code.
2. Declare `input`s with precise descriptions; mark `required: true` for
  anything the model must supply.
3. Prefer `:select` over free strings for closed vocabularies (`type`,
  `mode`).
4. Keep outputs compact (metadata, snippets, confirmations)  -  tool outputs
  enter the caller's context.
5. Add the task to `export` once; do not remove it later.
6. Update `doc/user/WorkspaceTools.md` in the same change.
