# Architecture

This page maps the Cortex module: what lives where, which parts are module
methods, which are helpers, and how an agent turn flows through the system.

**You should read this if:** you are modifying `workflow.rb` or wiring Cortex
into other workflows.

---

## Position in the stack

Cortex is a thin layer over scout-ai's `AgentWorkflow`:

```
Cortex (this repo)
  |- storage:   var/cortex/{conversations,briefs,artifacts}
  |- tools:     cortex_list / cortex_search / cortex_read / cortex_write
  \- execution: chat_task :continue  (the ONLY inference primitive)
       \- AgentWorkflow (scout-ai, read-only)
            |- helper :agent   (start_chat assembly + brief + tooling)
            |- chat_task       (run -> log_agent -> Chat.project)
            \- LLM::Agent      (model calls, tool execution)
```

Cortex never calls the model itself. `cortex_continue` and `cortex_brief` are
thin projections over the shared `continue` dependency: they load the
workspace chat, run `continue` on it, persist the grown chat, and return a
receipt. `log_agent` therefore always runs, unchanged.

## Module layout (`workflow.rb`)

The file has three zones:

1. `class << self` block  -  **module methods**, the workspace engine:
   namespace path resolution (`conversation_path`, `brief_path`,
   `artifact_path`), loading (`load_conversation`, `load_brief`,
   `resolve_brief`), persistence (`save_conversation`, `save_brief`,
   `write_artifact`), and the dep-chat builder
   (`conversation_prompt_chat`). Everything here is plain Ruby callable
   without a running job, which makes it unit-testable without LLM access.
2. A middle section of module-level methods (listing, search, bounded read,
   path sanitation) also on the module itself. (Note: they are defined after
   the `class << self` block ends, so they are `Cortex.instance`-style
   methods on the module object; the helper block below re-exposes them.)
3. `helper` declarations  -  thin delegators that make the module methods
   available inside task blocks (`self` inside a task). One line each; they
   exist so task bodies read naturally and stay in sync with the module
   methods.

Constants: `CORTEX` (= `Scout.var.cortex`), `VALID_TYPES`,
`READ_CAP` (50 000 chars for bounded reads).

## Task inventory

| Task | Type | Purpose |
|------|------|---------|
| `continue` | `chat_task :continue` (`:chat`) | The only place an agent is built and run; brief resolution happens here |
| `cortex_continue` | `:json` | Conversation turn: dep on `continue`, persist to `conversations/`, return receipt |
| `cortex_brief` | `:json` | Brief creation: dep on `continue`, persist to `briefs/` + `.meta` sidecar, return receipt; optional `tools` input provisions the brief's tooling (`lib/Cortex/briefs.rb`) |
| `cortex_list` | `:text` | Compact namespace inventory |
| `cortex_search` | `:text` | Lexical content search with snippets |
| `cortex_read` | `:text` | Bounded reads (index / last / range / artifact) |
| `cortex_write` | `:text` | Artifact write with provenance and versioning |

All six non-`continue` tasks are `export`ed, which is what makes them agent
tools (see [ToolExposure.md](ToolExposure.md)).

## Anatomy of one `cortex_continue` turn

1. The caller (an agent using the Cortex tool, or a Ruby driver) invokes the
   task with `conversation`, `prompt`, and `agent`.
2. The `dep :continue, chat: :placeholder` block builds the input chat:
   `Cortex.conversation_prompt_chat(conversation, prompt,
   namespace: :conversations)`  -  loads `conversations/<name>` if present,
   appends the prompt as a user turn. This is a *separate* chat from the
   workspace file until saving.
3. `continue` (a `chat_task`) builds the agent:
   `load_agent_conversation(agent, chat)` parses `Agent[/brief]`, resolves
   the brief **only** from `briefs/`, `AgentWorkflow#agent` builds the
   agent, the brief is followed into `start_chat`,
   `agent.start_chat.tool 'Cortex'` attaches the toolset, and the task
   body does `agent.follow chat` (the full dep chat is the per-turn tail,
   tooling included).
4. `chat_task` runs the agent (LLM + nested tools), calls `log_agent`
   (writes `log/agent.chat` under the job), and projects the result with
   `Chat.project`.
5. `cortex_continue` loads that result, `save_conversation` appends the prompt
   and the new messages to `conversations/<name>`, and the task returns
   `{agent_meta: [...job...], content: answer}`.

`cortex_brief` is the same flow with `namespace: :briefs`, `save_brief`, and a
required `agent` input recorded in the brief sidecar. Its optional `tools`
input (engine in `lib/Cortex/briefs.rb`) is expanded by `tool_messages` into
a `tool:`/`introduce:` message block that `save_brief` prepends to the top
of the brief body after `strip_brief_tooling` has removed any previous
tooling  -  replace semantics: `tools` given replaces the block, `tools: []`
strips all tooling, `tools` omitted keeps it. The dep chat receives the
same specs: `brief_prompt_chat` pastes each string verbatim as a `tool:`
message (whole-workflow specs also emit `introduce:`) before the user
prompt, so the brief-producing agent sees the provisioned tools while
drafting. Provisioning reaches a consuming agent when the brief is loaded
through `Agent/brief` in `cortex_continue`, where the followed brief
contributes exactly the provisioned tools plus the mandatory
`tool: Cortex`. The spec grammar, validation, and examples are
documented in [ToolExposure.md](ToolExposure.md) and
[../user/WorkspaceTools.md](../user/WorkspaceTools.md).

## Error philosophy

Workspace errors are `ScoutException`s with actionable messages that name
the namespace, list what does exist, and suggest the fixing call  -  for
example a missing brief lists available briefs, detects a same-named
conversation (and says conversations are not briefs), and detects the legacy
`var/cortex/<Agent>/<brief>` location. See `resolve_brief`.

## Related pages

- [Workspace.md](Workspace.md)  -  storage, listings, search, reads, writes.
- [ToolExposure.md](ToolExposure.md)  -  how tasks become model-visible tools.
- [Receipts.md](Receipts.md)  -  the receipt contract and provenance chain.
- [../research/design-decisions.md](../../research/design-decisions.md)  -  why it
  is shaped this way.
