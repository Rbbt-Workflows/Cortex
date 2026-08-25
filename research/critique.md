# Critique — Cortex workspace milestone

Independent verification of the milestone deliverables (workflow.rb, docs,
research notes, live workspace, recorded e2e run) against the acceptance
tests. Performed by reading the code and files and re-running cheap,
non-LLM checks (`Cortex.job(...).run`, helper calls, disk inspection).
No LLM-backed check was needed: brief resolution, error paths, and receipt
shape were all provable at file/job level, and the recorded e2e already
covers the LLM path.

## Verdict

PASS.

All 12 acceptance tests are satisfied on current evidence. No functional
defects were found. The gaps listed below are documentation-only
(low severity); none changes behavior or provenance semantics.

## Checks performed

1. AT1 brief decoupled from agent-name prefix — PASS.
   `var/cortex/briefs/bash-math` exists (name contains no agent prefix);
   `var/cortex/briefs/.meta/bash-math.json` records
   `{"agent":"Worker","job":"Cortex/continue/Default_ee732390....chat","timestamp":"2026-08-24 23:09:16"}`.
2. AT2 brief resolution and strict errors — PASS.
   Live: `Cortex.resolve_brief("Worker","Summing")` raises
   "No brief Summing for agent Worker. A conversation named Summing exists in
   the conversations namespace; conversations are not briefs. Available
   briefs: bash-math" (no fallback). Live: `Cortex.job(:continue, chat:
   "user:\n\nOK", agent: "Worker/nope").run` completes without an LLM call and
   returns the exception message "No brief nope for agent Worker. Available
   briefs: bash-math" — the Cortex error surfaces before agent loading.
   Namespaces distinct on disk: `briefs/` = [bash-math], `conversations/` =
   [Summing]; no `conversations/bash-math`, no `briefs/Summing`.
3. AT3 namespace write separation — PASS.
   Code: `save_brief` writes only `brief_path`/`brief_meta_path`;
   `save_conversation` writes only `conversation_path`; the two dep blocks
   pass `namespace: :briefs` vs `namespace: :conversations` to the shared
   `conversation_prompt_chat`. Disk agrees (see check 2).
4. AT4 cortex_list — PASS (with caching caveat, see gaps).
   Fresh run `type=all, prefix="S"`: three labeled sections, metadata rows
   only (name/messages/bytes/mtime for chats; name/bytes/mtime for
   artifacts), dot-directories (`.meta`, `.history`) invisible. Re-running
   the recorded input combination returns the cached job snapshot (standard
   Scout Step caching), so a fresh input combination was used to prove
   current behavior.
5. AT5 cortex_search — PASS.
   Fresh-ish run `query "8,976,431"`: two compact conversation hits in the
   documented `index:role: snippet` format. Helper-level
   `search_artifacts("8,976,431", ...)` also returns the
   `summing/answer.md` artifact hit, proving artifact content is searched.
6. AT6 cortex_read — PASS.
   `Summing` range `0-1` returns prompt + `meta: job=...` line; `last: 1`
   returns the trailing assistant summary; artifact reads
   (`summing/answer.md`, `critique-probe.md`) return full content.
7. AT7 cortex_write — PASS.
   Fresh probe: wrote `critique-probe.md` v1 (15 B) then v2 (30 B). Response
   each time exactly one line ("Artifact written: critique-probe.md (15
   bytes, v1)"). `artifacts/.meta/critique-probe.md.json` accumulates a
   `versions` array with `job`, `agent` (Critic), `mode`, `timestamp`,
   `size`; `artifacts/.history/critique-probe.md/20260824232453.1` holds the
   v1 text; current file holds v2. Existing evidence matches:
   `summing/answer.md` v2 (494 B) with history snapshot
   `20260824231352.1` (278 B v1). The probe artifact is left in place as
   documentation of this check.
8. AT8 receipt contract — PASS.
   Both `continue_chat` and `brief_agent` return exactly
   `{agent_meta: [{role: :meta, content: Chat.serialize_meta({job:
   continue.short_path})}], content: res.answer}` (code read); recorded
   receipts in `tmp/e2e_out.txt` and the `meta: job=Cortex/continue/...`
   lines inside `conversations/Summing` and `briefs/bash-math` carry the
   same job ids (`Default_6c8b...`, `Default_965e...`, `Default_ee73...`).
9. AT9 example run fidelity — PASS.
   Spot-checked `research/example-run.md` against disk and transcript:
   brief = 3 messages / 391 B; conversation = 14 messages / 34 578 B;
   artifact v1 278 B then v2 494 B with history; sum 8,976,431 + 2,895,764
   = 11,872,195; job ids match the live files. All consistent.
10. AT10 documentation — PASS (minor gaps below).
    All files present: `doc/StartHere.md`, `doc/user/{Workspace,
    Conversations, WorkspaceTools, Receipts}.md`, `doc/developer/
    {Architecture, Workspace, ToolExposure, Receipts}.md`, and the six
    `research/` notes. Output examples in `WorkspaceTools.md` byte-match
    live tool outputs. The "verified tool surface" table in
    `ToolExposure.md` was re-verified via `LLM.workflow_tools(Cortex)`:
    exact match (6 tools, required arrays identical). No emoji anywhere;
    see gaps for non-ASCII typography and two broken relative links.
11. AT11 no scout-ai/scout-gear changes — PASS.
    `git status` in both checkouts shows only `.vimproject` (editor state,
    unrelated to this work); no source modifications. No vendored scout
    code in this repo (`lib/` is empty). `workflow.rb` depends only on
    documented scout-ai/AgentWorkflow APIs; the `agent_meta` handling in
    scout-ai's `lib/scout/llm/tools/call.rb` is pre-existing and
    untouched.
12. AT12 cache-friendly topology — PASS.
    `load_agent_conversation` order: parse `Agent[/brief]` → resolve brief
    (briefs namespace only) → load agent → `start_chat.follow brief` →
    `start_chat.tool 'Cortex'` (static export list). The dep chat is prior
    conversation turns + the new prompt; nothing dynamic (no workspace
    inventory) is injected into the prefix. `workflow.rb` is 531 lines as
    described; single `chat_task :continue` inference primitive; export
    line matches docs.

## Failures or gaps

No functional failures. Documentation-only gaps:

1. LOW — broken relative link in `doc/developer/Architecture.md` (line
   ~107): `[../research/design-decisions.md](../research/...)` resolves to
   `doc/research/`, which does not exist. Smallest fix: change to
   `../../research/design-decisions.md`.
2. LOW — broken relative link in `doc/StartHere.md` (line 9):
   `[AgentWorkflow](../scout-ai)` assumes a sibling `scout-ai` checkout
   that does not exist under this workflows directory. Smallest fix: use
   the scout-ai repository URL or plain code formatting (`AgentWorkflow`)
   instead of a relative link.
3. LOW — non-ASCII typography in docs: em-dashes (U+2014), arrows (U+2192),
   and box-drawing characters in the `Architecture.md` diagram. No emoji
   or decorative symbols were found; if "plain markdown" is meant strictly
   as ASCII, replace these (smallest fix: a sed pass), otherwise accept.
4. LOW — the docs do not mention that `cortex_list`/`cortex_search`
   results are Scout jobs cached per input combination: an identical
   repeated call returns the snapshot from when that job first ran (e.g.
   `type=all, prefix=nil` still returns the pre-cleanup 22:41 snapshot:
   0 conversations). Behavior is standard Scout Step caching, not a
   regression, and the recorded run is accurate for its moment. Smallest
   fix: one sentence in `doc/user/WorkspaceTools.md` ("listings are cached
   per input combination; vary an input such as `prefix` after workspace
   changes").
5. OBSERVATION — repo residue unrelated to correctness: `recon-findings.md`
   at repo root (step-1 recon note; research notes otherwise live under
   `research/`), several `tmp/apply_*.rb` scratch scripts, and the
   `.vimproject` modifications in the scout-ai/scout-gear checkouts.
   Optional cleanup; no action required for this milestone.

## Residual risks

- Result caching (gap 4) can mislead an agent that re-issues an identical
  listing call after workspace changes. Bounded reads of actual files
  (`cortex_read`) are unaffected, so provenance chains remain trustworthy.
- `conversations/Summing` is 34.5 KB after two turns because full
  function-call outputs (including large sandbox error dumps) are
  persisted. Already documented by the Worker; bounded reads and the index
  default mitigate it.
- The validation environment could not run sub-agent exec tools (nested
  bwrap restriction), so the brief's "compute with bash" behavior was
  exercised but its tool calls failed; the agent fell back to manual
  arithmetic. Expected, recorded honestly, and outside Cortex's control.
- This checkout is not a git repository, so no commit history exists;
  `research/` notes plus the live workspace are the only audit trail.

## Sign-off

Date: 2026-08-24
Agent: Critic
Verdict: PASS — milestone accepted; the four low-severity doc gaps above
may be addressed in a follow-up documentation pass.

## Post-verdict follow-up (same date)

The four low-severity documentation gaps listed above were fixed immediately
after the verdict, by the Manager:

1. Broken link `doc/developer/Architecture.md` -> `../research/...` corrected
   to `../../research/design-decisions.md`.
2. Broken sibling link in `doc/StartHere.md` (to a nonexistent `../scout-ai`
   directory) replaced with a plain-text reference to scout-ai's
   `AgentWorkflow`; the research-notes link now points to `research/` at the
   repository root in prose.
3. Non-ASCII typography (em-dashes, arrows, box-drawing characters) replaced
   with ASCII equivalents across all docs and the two main research notes;
   verified with a character scan (no code points above U+007E remain).
4. Caching caveat added to `doc/user/WorkspaceTools.md` for `cortex_list`
   and `cortex_search` (results are cached per input combination; vary the
   input to force a re-run after workspace changes).

Verdict remains PASS.
