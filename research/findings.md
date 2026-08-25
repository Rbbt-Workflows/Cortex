# Findings

Consolidated findings from the Cortex workspace milestone (2026-08-24):
what was built, what was verified, what was decided, and what remains
deferred. Supporting notes live alongside: `design-decisions.md` (rationale),
`notes-refactor.md` (step 2 evidence), `notes-tools.md` (step 3 evidence),
`notes-validation.md` (step 5 evidence), `example-run.md` (recorded run),
`critique.md` (independent verification).

## Environment facts established

- `Scout.var.cortex` resolves repo-local (`<repo>/var/cortex`), so all
  workspace data is inside the repository checkout.
- scout-ai and scout-gear are read-only in this sandbox; the `agent_meta`
  Hash-result patch in `lib/scout/llm/tools/call.rb` was already present, so
  no scout-ai change was needed for this milestone.
- LLM inference is reachable; agents run for real through
  `Cortex.job(:task, ...).run`.
- The agent name `Worker` resolves through the read-only global agent tree
  (`~/chats/Agent/Worker`), not from any file in this repo.
- The repository checkout is not a git repository (no `.git`), so milestone
  commits could not be made; this note set is the record.
- Sub-agent execution tools (`bash`, `python`, `ruby` tasks) spawn a nested
  bubblewrap that this host cannot start (`bwrap: No permissions to create
  new namespace`); agents could not machine-verify arithmetic during the
  validation run and reported manual cross-checks instead.

## What was implemented

1. Namespace separation under `var/cortex/`: `conversations/`, `briefs/`
   (with `.meta/` sidecars), `artifacts/` (with `.meta/` and `.history/`).
2. Brief ergonomics: `Agent/brief` reference syntax retained, but brief
   names are decoupled from agent names; `brief_agent` gained a required
   `agent` input recorded in the sidecar; `resolve_brief` loads only from
   `briefs/` and produces actionable errors (missing brief, conversation of
   the same name, legacy `var/cortex/<Agent>/<brief>` location, available
   briefs).
3. Workspace tools as exported tasks: `cortex_list` (scoped, metadata-only),
   `cortex_search` (lexical, snippets, AND semantics), `cortex_read`
   (bounded: index default, `last`, `range`, artifact full read, 50k cap),
   `cortex_write` (provenance sidecar, `.history` snapshots, one-line
   confirmation).
4. Receipts preserved: `{agent_meta: [{role: :meta, content:
   Chat.serialize_meta({job: continue.short_path})}], content: answer}`;
   automatic `log_agent` unchanged inside `chat_task :continue`.
5. Documentation: `doc/StartHere.md`, `doc/user/{Workspace, Conversations,
   WorkspaceTools, Receipts}.md`, `doc/developer/{Architecture, Workspace,
   ToolExposure, Receipts}.md`, plus this research folder.

## What was verified (see per-step notes for transcripts)

- Brief `bash-math` created for agent `Worker` under a non-prefixed name;
  sidecar records agent/job/timestamp.
- `agent: "Worker/bash-math"` resolves from `briefs/`; missing brief
  (`Worker/nope`) errors with `No brief nope for agent Worker. Available
  briefs: bash-math`.
- Conversation `Summing` created and continued by two different agents
  (unbriefed `Worker`, then `Worker/bash-math`), each turn carrying
  `meta: job=Cortex/continue/...`.
- `cortex_list` returns the three namespaces with metadata only (message
  counts, bytes, mtimes) and excludes `.meta`/`.history`.
- `cortex_search "8,976,431"` and `"bash"` return compact matches with
  message-index snippets from conversation content.
- `cortex_read` works in index mode, `range` mode, briefs mode, and artifact
  mode.
- `cortex_write` produced v1 then v2 of `summing/answer.md`; v1 content
  survives verbatim in `.history/summing/answer.md/20260824231352.1`; the
  meta sidecar accumulates both version records with job/agent/mode/
  timestamp/size; the tool returned one line each time.
- Tool schema check: `LLM.workflow_tools(Cortex)` shows all six tools with
  the expected `required` sets, including the newly required `agent` on
  `brief_agent`.

## Decisions (rationale in design-decisions.md)

- Clean break for legacy data: old `var/cortex/Summing` and
  `var/cortex/Worker/math` are disposable; detection of the legacy brief
  location is an error message, not a migration.
- Briefs record the target agent in a sidecar rather than in the file name;
  file names are free-form and stable.
- Conversation content is normalized (empty messages dropped) everywhere so
  indices are stable across saves despite the `Chat.load` leading-empty
  quirk.
- Artifact versioning is append-only at the metadata layer and snapshot-
  based at the content layer; no in-place rewrites.
- Task names are `cortex_`-prefixed to avoid cross-workflow tool-name
  collisions; `continue_chat`/`brief_agent` keep historical names.
- Docs follow the scout-ai layout: `doc/StartHere.md`, `doc/user`,
  `doc/developer`, research at repo root.

## Known limitations / deferred

- Search is lexical substring only; semantic/embedding search deferred.
- No entity layer (genes, TFs, composites, claims)  -  deliberately deferred
  until agents produce enough AGS material to know which entity operations
  pay off.
- No automatic relevance injection of prior claims into prompts; agents pull
  context themselves via search/read.
- ChatAnalyst integration (a single `analyze_conversation` wrapper) was
  optional/stretch and was not added this pass; receipts and `meta:` lines
  already give analysts explicit edges to follow.
- The `cortex_read` "sections" concept from the design conversation (read a
  named section of an artifact) was not implemented; range reads on chats
  and full reads on artifacts cover current needs.
- `cortex_list` for conversations shows message counts, not token counts;
  token accounting lives in chat meta lines.
- Legacy error-path behavior for briefs that exist but are empty files is
  treated as "no brief" (load_brief returns nil), which is the correct
  affordance for agents.

## Sandbox caveats for reproducing the run

- Run from the repository root so `Scout.var.cortex` stays repo-local.
- The recorded run used the public task interface
  (`Cortex.job(...).run`), not helper shortcuts.
- Original transcripts: `tmp/e2e_run.rb` (driver) and `tmp/e2e_out.txt`
  (raw output); trimmed copy in `example-run.md`.
