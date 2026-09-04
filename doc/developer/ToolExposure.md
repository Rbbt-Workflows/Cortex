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

- the task description (from the `desc` block or, as in Cortex, from the
  task entry in `README.md`'s `# Tasks` section) becomes the tool
  `description`;
- each `input` becomes a parameter whose description is the input
  description;
- `required: true` inputs land in the schema's `required` array;
- `:select` inputs surface their `select_options` as an enum.

Consequence: task and `input` descriptions ARE the model-facing
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

## `cortex_activity`

Read-only recall task (`lib/Cortex/tasks/activity.rb`, engine in
`lib/Cortex/activity.rb`). It joins what the workspace already holds about
ONE entity: defined properties, recorded examinations, containing named
lists, and text mentions. No LLM, no result payloads (job references only),
fully deterministic. Exported through `export_exec` (see `workflow.rb`), so
it is CLI-reachable via the generic `scout cortex_activity ...` command and
does not gain a `return_path` input. Facet selection and the extension
point are documented in the task section of `README.md` and in
`doc/developer/Entities.md`.

## Exported tasks automatically gain `return_path`

Every exported (non-`exec_export`ed) task automatically gains a boolean
`return_path` input. When an agent sets it, the tool returns the persisted
job path instead of the loaded result. This costs nothing to maintain and is
how a caller can obtain a stable reference to a workspace operation.

Tool calls run as real jobs (`LLM.call_workflow`), so every `cortex_*` call
has a `var/jobs/Cortex/<task>/...` job with its own provenance  -  the
`job:` recorded in artifact meta refers to that job.

## Briefs provision their own tooling

`cortex_brief` accepts a `tools` input: an array of spec strings in
`Workflow [task [input|name=value ...]]` form. The engine
(`lib/Cortex/briefs.rb`: `TOOL_SPEC_GRAMMAR`, `validate_tool_spec`,
`whole_workflow_spec?`, `tool_messages`) expands the specs, in array order,
into a block of `tool:` / `introduce:` chat messages and `save_brief`
prepends that block to the top of the brief body:

- a whole-workflow spec (`Baking`) emits BOTH `introduce: Baking` (the
  workflow documentation) and `tool: Baking` (every task of the workflow
  as a tool, full inputs)  -  the same shape `load_agent_conversation`
  uses for the Cortex toolset itself;
- a task-level spec emits a single `tool:` line with the spec pasted
  verbatim (whitespace tokens rejoined by single spaces).

Because the specs become ordinary chat messages, the upstream scout-ai
`tool:`/`introduce:` semantics govern them at continue time: bare input
names restrict the accepted inputs, `name=value` pre-fills the input and
hides it from the model, and `noinputs`/`none` as the sole input token
exposes the task with no inputs. The grammar table and examples live in
[../user/WorkspaceTools.md](../user/WorkspaceTools.md); the canonical
behavior statement is the `tools` input description on `cortex_brief`.

Validation is syntax only (`validate_tool_spec`): workflow/task names must
be identifier-like, input tokens must be bare identifiers or `name=value`,
and `noinputs`/`none` may only appear as the sole input token. A malformed
spec raises an actionable `ScoutException` naming the spec and the grammar.
Existence is deliberately not checked: a workflow absent at brief time may
be installed by continue time, and an unknown workflow makes scout-ai
attempt an install then. `save_brief(..., tools:)` implements the update
semantics  -  `tools` given replaces the whole existing tool block
(`strip_brief_tooling` removes every `tool:`/`introduce:`/`kb:`/`mcp:`
message, then the new block is prepended), `tools: []` strips all tooling,
and omitting `tools` leaves the tooling untouched.

Delivery happens only through `Agent/brief` in `cortex_continue`:
`resolve_brief` loads the brief, `load_agent_conversation` follows it into
`start_chat`, and the agent's chat then carries exactly the provisioned
tooling plus the framework's own mandatory `tool: Cortex` entry (verified
end to end by `test/Cortex/test_brief_tools.rb`:
`test_continue_through_brief_carries_provisioned_tools`). Provisioning is
deliberately part of the brief itself: a brief defines its own tooling, so
the prefix an agent sees is stable and reproducible from the brief file
alone. Distinct `tools` arrays produce distinct `cortex_brief` jobs, so
provisioning is part of the job identity.

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

1. Document the task in `README.md` (`## task_name` section); the
  parsed first line becomes the tool description, so write it so a model
  can act on it without reading the code.
2. Declare `input`s with precise descriptions; mark `required: true` for
  anything the model must supply.
3. Prefer `:select` over free strings for closed vocabularies (`type`,
  `mode`).
4. Keep outputs compact (metadata, snippets, confirmations)  -  tool outputs
  enter the caller's context.
5. Add the task to `export` once; do not remove it later.
6. Update `doc/user/WorkspaceTools.md` in the same change.
