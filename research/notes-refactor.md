# Refactor notes: Cortex namespace milestone (implementation evidence)

## What changed

`workflow.rb` only (plus this note and `research/design-decisions.md`). No
scout-ai changes; no other repo files touched.

- Namespaces under `var/cortex/`: `conversations/`, `briefs/` (+ `briefs/.meta/
  <name>.json` sidecars), `artifacts/` (path helper only; usage comes in the
  next work item).
- Brief ergonomics: `agent` input keeps `Agent/brief` syntax; brief is loaded
  ONLY from `briefs/<brief>`; strict errors; legacy location mentioned in the
  error but never loaded.
- `brief_agent` writes `briefs/<name>` + `.meta` sidecar (agent name, job
  short_path, timestamp). `continue_chat` reads/writes
  `conversations/<name>` only. No agent-name prefix in stored names.
- DRY: single `Cortex.conversation_prompt_chat(conversation, prompt, namespace:)`
  builds the `continue` dep chat for both tasks (`:conversations` loads prior
  turns; `:briefs` is prompt-only on creation and grows with the existing
  brief on update).
- Path helpers exposed both as module methods (`Cortex.brief_path(...)` etc.)
  and workflow helpers (so dep blocks, which run in module context, and task
  bodies, which run in `step_module` context, share one implementation).
- Input descriptions updated to the exact agreed texts (they become tool docs).
- `load_agent_conversation` resolves the brief BEFORE loading the agent, so a
  typo'd brief name surfaces the Cortex error, not scout-ai's
  `No agent found with name Agent/brief` (see task-context check below).
- Receipt contract unchanged: `{agent_meta: [...], content: res.answer}` with
  `Chat.serialize_meta({job: continue.short_path})`. No new fields.
- Disposable legacy data (`var/cortex/Summing`, `var/cortex/Worker/math`,
  `var/cortex/probe`) deleted; clean break, no migration code (see
  `research/design-decisions.md`).

## Deviations from the brief

- `File.exists?` is not available in this Ruby (3.3); used `File.exist?`.
  No behavioral difference.
- The dep block runs in module context (`Cortex`), not task context, so the
  shared dep-chat helper is implemented as a `class << self` module method and
  the thin workflow helpers delegate to it. This is the only way one
  implementation serves both call sites with the installed scout-gear
  (10.12.2). Behavior is identical to the inline version.
- Brief listing in the missing-brief error lists only briefs that actually
  load non-empty (an empty file left on disk is not advertised as available).

## Smoke tests (commands + trimmed outputs)

All run from repo root. No LLM call at any point; every check below is job
construction, helper, or error-path level.

### Syntax

    $ ruby -c workflow.rb
    Syntax OK

### Task/input parsing

    $ ruby -e 'require "scout-ai"; require "./workflow"; Cortex.tasks.each ...'

    == continue
      inputs: [[:agent, :string, "Agent name; optionally Agent/brief_name to load a brief stored in the Cortex briefs namespace (e.g. Worker/math loads brief math for agent Worker)"], [:chat, :text, "Chat in Scout-AI chat-file format"]]
    == continue_chat
      inputs: [[:conversation, :string, "Conversation name in the Cortex conversations namespace"], [:prompt, :text, "Prompt to continue the conversation"]]
    == brief_agent
      inputs: [[:conversation, :string, "Brief name in the Cortex briefs namespace; it does not need to contain the agent name"], [:prompt, :text, "Prompt for the agent that will produce the brief"]]

### Brief resolution (helpers via `Cortex.step_module`)

Workspace fixture: `var/cortex/briefs/math` written by hand
(`user:\n\nYou are a math worker. Use bash to sum.`).

    $ ruby -e 'require "scout-ai"; require "./workflow"; o = Object.new; o.extend Cortex.step_module; ...'

    ghost: No brief ghost for agent Worker. Available briefs: math
    legacybrief: No brief legacybrief for agent Worker. Legacy location found (var/cortex/Worker/legacybrief); recreate the brief with brief_agent (workflow Cortex, task brief_agent). Available briefs: math
    notabrief: No brief notabrief for agent Worker. A conversation named notabrief exists in the conversations namespace; conversations are not briefs. Available briefs: math
    empty: No brief empty for agent Worker. Available briefs: math
    loaded math: 2 messages
    names: ["math"]
    names conversations: ["notabrief"]

Empty workspace case (same workflow, isolated directory):

    NOBRIEFS: No brief ghost for agent Worker. No briefs exist yet; create one with brief_agent (workflow Cortex, task brief_agent).

Notes: `Chat.load` of a one-message file yields 2 messages (an empty leading
message from the leading blank separator in the chat-file format); standard
format behavior, not a parser regression.

### Task-context check (strict resolution order)

The brief must be resolved before the agent is loaded, otherwise scout-ai's
`load_agent` reports `No agent found with name Agent/brief` first (it scans the
whole `agent` string). `load_agent_conversation` was reordered accordingly and
the missing-brief error now surfaces first.

    $ ruby -e 'require "scout-ai"; require "./workflow"; include Workflow
      job = Cortex.job(:continue, agent: "NoSuchAgent/ghost", chat: "user:\n\nhi"); job.run; ...'

    RESOLVE-BRIEF-FIRST: No brief ghost for NoSuchAgent. Available briefs: math

Also confirmed `job.dependencies.length == 0` for `:continue` (dep-free task).

### Dep chat construction (cache topology)

    $ ruby -e 'require "scout-ai"; require "./workflow"; include Workflow; ... Cortex.job(...)'

    continue_chat: dep=continue dep_inputs=["Worker/math", [{:role=>"user", :content=>"p"}]] ok
    brief_agent: dep=continue dep_inputs=["Worker/math", [{:role=>"user", :content=>"p"}]] ok
    continue_chat dep (fresh conversation): continue ["Worker", [{:role=>"user", :content=>"hello"}]]
    brief_agent dep (fresh brief): continue ["Worker", [{:role=>"user", :content=>"write a brief"}]]
    continue_chat job: Default_54116310512a973e0f2771a9a98521c7.json
    brief_agent job: Default_373499d39fd33012afa876b25377f45f.json

A continued conversation grows the dep chat with prior turns, so the job name
keeps the stable prefix (tooling + brief) → conversation → prompt topology.

### Writes: `brief_agent` storage and `continue_chat` storage

    $ ruby -e '... Cortex.save_brief "probe-brief", "Produce a brief for a math worker", [{role: :assistant, content: "Be terse. Always compute with bash."}], agent: "Worker", job: "Cortex/continue/Default_abc"'

    var/cortex/briefs/probe-brief:
    user:
    ...
    Produce a brief for a math worker

    assistant:

    Be terse. Always compute with bash.

    var/cortex/briefs/.meta/probe-brief.json:
    {
      "agent": "Worker",
      "job": "Cortex/continue/Default_abc",
      "timestamp": "2026-08-24 21:30:24"
    }

    $ ruby -e '... Cortex.save_conversation "probe-chat", "say hi", [{role: :assistant, content: "hi"}]'  (then again with "and bye")

    var/cortex/conversations/probe-chat grows across turns:
    user: say hi / assistant: hi / user: and bye / assistant: bye

Fixtures were removed after testing; `var/cortex/briefs/math` was kept only
long enough for the resolution tests (see Open issues).

### `scout workflow task ... --help`

`scout workflow task Cortex continue_chat --help` in this sandbox fails while
INSTALLING the workflow: `RuntimeError: Workflow repo does not exist:
https://github.com/Scout-Workflows/cortex.git` (the CLI tries to clone the
repo by name because this checkout is not registered as the installed
workflow). `scout workflow tasks Cortex` is not a valid subcommand here
(`Command 'tasks' not understood`; the subcommand is `list`). Task/input
introspection was therefore done programmatically (see above), which loads the
exact same `workflow.rb`.

## LLM end-to-end

Not attempted: no credentials/model configuration is reachable in this
sandbox, and any real run would also require a reachable model endpoint.
Deferred to the validation work item, as anticipated by the brief ("if a real
end-to-end LLM run is feasible ... otherwise record that the LLM e2e is
deferred").

## Open issues / next steps

- `var/cortex/briefs/math` is a hand-written fixture left in place; remove it
  or replace it with a real `brief_agent` run during validation.
- `artifacts/` namespace helpers exist but are unused until the next work
  item; `cortex_list/read/search/write` tool tasks to be added there.
- `Chat.load` leading-empty-message quirk (format artifact) is worth a look
  during the docs/validation item if briefs start with a system message.
