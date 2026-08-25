# Cortex work item 5 — end-to-end validation run

Date: 2026-08-24
Scope: full LLM e2e through the real Cortex tasks (no helper shortcuts),
replacing the earlier hand-written fixtures; plus the sandbox limitations found
during the run.

## Environment notes

- LLM inference IS reachable from this sandbox (contrary to earlier work items
  that deferred the e2e for that reason): `Cortex.job(:continue, ...)` runs to
  `done` and returns real assistant content. The agent name `Worker` resolves
  through `Scout.chats.Agent` (repo-local `chats/` is `Scout.chats`; there is a
  global `Worker` agent definition in the read-only `~/chats/Agent` tree).
- The repo checkout is NOT a git repository (mounted without `.git`), so the
  plan's "commit at each milestone" step could not be performed; artifacts and
  notes in `research/` are the record instead.
- Exec tools (`bash`/`python`/`ruby`) available to sub-agents run inside a
  nested bubblewrap that this sandbox cannot start (`bwrap: No permissions to
  create new namespace`). The Worker therefore could not machine-verify the
  arithmetic and fell back to two manual methods that agreed — recorded
  honestly in its own execution summary inside the conversation.

## Fix for `brief_agent` (found by the first e2e attempt)

The `agent` parameter was missing from `brief_agent`'s declared inputs, so it
was never part of the task signature and the briefs `.meta` sidecar recorded
`"agent": ""`. Two-line fix in `workflow.rb`:

- `input :agent, :string, 'Agent the brief is for (e.g. Worker); recorded in the briefs .meta sidecar and used to produce the brief', nil, required: true` added to `brief_agent`;
- task body now reads the task input `agent` instead of re-parsing `inputs[:agent]`.

Verified after the fix: `briefs/.meta/bash-math.json` records
`{"agent":"Worker","job":"Cortex/continue/Default_ee73...","timestamp":...}`.

A stale `briefs/bash-math` left over from the broken first attempt (containing
two exception turns from `No agent found with name Worker`) was deleted before
the clean run.

## Run 1 — recorded transcript (`tmp/e2e_out.txt`, trimmed into `research/example-run.md`)

Steps (all through the public task interface `Cortex.job(...).run`):

1. `brief_agent` — brief name `bash-math` (NOT prefixed with the agent name),
   agent `Worker`. STATUS done; receipt
   `{agent_meta:[{role:"meta",content:"job=Cortex/continue/Default_ee73..."}],
   content:"Acknowledged: ... use the bash tool ..."}`;
   saved to `var/cortex/briefs/bash-math` + sidecar.
2. `continue_chat` conversation `Summing`, agent `Worker` (unbriefed) —
   proposed `**8,976,431 + 2,895,764**` without solving; receipt job
   `Cortex/continue/Default_6c8b...`.
3. `continue_chat` conversation `Summing`, agent `Worker/bash-math` — solved
   the sum (11,872,195), attempting `bash`/`python`/`ruby` first per its brief
   (all failed in the nested sandbox) and reporting manual cross-checks;
   receipt job `Cortex/continue/Default_965e...`. The brief resolved from the
   briefs namespace with no agent-name-prefix coupling and no
   `Worker/Worker/math`-style confusion.
4. Workspace tools exercised:
   - `cortex_list type=all` → conversations: `Summing` (14 messages, 34578 B);
     briefs: `bash-math` (3 messages, 391 B); artifacts: `summing/answer.md`.
   - `cortex_search "8,976,431"` → 2 compact matches in `conversations/Summing`
     (message indices 4 and 13 with snippets).
   - `cortex_search "bash" type=conversations` → 3 matches (function calls and
     summary).
   - `cortex_read Summing range=0-1` → prompt + `meta: job=...` line.
   - `cortex_read bash-math type=briefs range=0-0` → brief user message.
5. `cortex_write summing/answer.md` (replace, agent Manager) →
   `Artifact written: summing/answer.md (278 bytes, v1)`; sidecar
   `artifacts/.meta/summing/answer.md.json` records
   `{job:"Cortex/cortex_write/Default_33f0...", agent:"Manager", mode, timestamp, size}`.
6. `cortex_write` again with corrected content → `v2`, and
   `.history/summing/answer.md/20260824231352.1` holds the v1 text
   (verified by reading both files).
7. `cortex_read` of the artifact returns the current (v2) content.

Every step `STATUS: done`; no step errored.

## Observations worth keeping

- **`agent_meta` receipts are intact end-to-end**: each `continue_chat` turn
  saved into `conversations/Summing` carries a `meta: job=Cortex/continue/...`
  line, and the JSON returned to the caller keeps exactly
  `{agent_meta:[{role::meta, content:...}], content:...}`.
- **Brief loading order works as designed**: the brief is resolved before the
  agent is loaded, and a non-prefixed brief name (`bash-math`) works for agent
  `Worker` through the `Worker/bash-math` syntax.
- **Artifact provenance and versioning behave as specified**: `.meta` sidecar
  accumulates a `versions` array; `.history/<name>/<ts>.<seq>` keeps the prior
  text on replace; the tool returns a single confirmation line.
- **Conversation content can be large**: `conversations/Summing` is 34.5 KB
  after only two turns, because function-call outputs (including a huge bwrap
  error dump) are persisted in full. Bounded reads (`last`/`range`) and the
  index default of `cortex_read` are therefore load-bearing, exactly as the
  design predicted.
- **Job-name addressing**: `cortex_list`/`cortex_search`/`cortex_write` get
  `Default_<md5>` names (no `jobname` input); `cortex_read` uses
  `jobname: true` on its required inputs, giving stable per-item names
  (`conversations_<md5>`, `briefs_<md5>`, `artifacts_<md5>`). Both forms are
  fine for provenance purposes.

## Acceptance-test mapping

- Brief decoupled from agent name prefix: run 1 steps 1 and 3. PASS.
- Briefs/conversations/artifacts separation, listing with metadata only:
  step 4 `cortex_list`. PASS.
- Search over conversation AND artifact content with snippets: step 4
  (`8,976,431`, `bash`) and the earlier work-item probes (`TP53 PD_PI`). PASS.
- Bounded reads (range/last, briefs and conversations) and full artifact
  reads: step 4. PASS.
- `cortex_write` provenance + non-destructive versioning + tiny confirmation:
  steps 5-7. PASS.
- Receipt contract `{agent_meta, content}` unchanged, jobs visible in the
  parent conversation: steps 1-3. PASS.
- Example run recorded: `research/example-run.md`. PASS.
- Missing-brief / conversation-as-brief error paths: covered earlier in
  `research/notes-refactor.md` (unit level); unchanged by this work item.
