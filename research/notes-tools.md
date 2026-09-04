# Cortex work item 3 — agent-facing workspace tools (implementation notes)

Date: 2026-08-24
Scope: `cortex_list`, `cortex_search`, `cortex_read`, `cortex_write` as
model-visible exported tools; desc blocks for the tasks now named
`cortex_continue`/`cortex_brief` (called `continue_chat`/`brief_agent` at
the time of writing; the old names no longer exist);
export list update; wording fixes in the research notes.

> NOTE (repair round 1): this file was accidentally overwritten during the
> repair round (a truncated payload was written over it). It has been
> reconstructed from the workflow.rb source, the smoke-run outputs still
> available under `tmp/`, and the repair-round probes below. Trimmed outputs
> are verbatim from those runs; wording is a faithful summary of the
> implementation as verified.

## What changed

1. Four exported tasks in `workflow.rb`, all implemented as module methods
   (`class << self`) plus thin `helper` wrappers, matching the step-2 pattern
   (dep blocks run in module context, task bodies in step_module context):
   - `cortex_list(type, prefix=nil)` — metadata-only listings per namespace
     (conversations/briefs: name, messages, bytes, mtime; artifacts: name,
     bytes, mtime). `type` accepts `conversations|briefs|artifacts|all`
     (default `all` → three namespace blocks with counts); unknown types raise
     a `ScoutException` listing the valid values. Dot-dirs (`.meta`,
     `.history`) are always excluded (`namespace_names` rejects dot basenames
     and artifact files reject any dot-path component).
   - `cortex_search(query, type=nil, limit=20)` — case-insensitive lexical
     search over conversation/brief messages and artifact contents. Single
     term: substring match. Multiple terms: AND semantics (every term must
     appear). Returns `#type\tname\tmatch` TSV rows with bounded snippets
     (~200 chars for artifacts, ~100 chars per matching message), never whole
     files. Empty result → one-line "No matches for ...".
   - `cortex_read(name, type, last=nil, range=nil)` — conversations/briefs
     default to a compact per-message index (role + fingerprint); `last: N`
     gives trailing messages with content; `range: "a-b"` (inclusive indices)
     gives that slice with content. Artifacts are read as full text. All
     content outputs capped at `READ_CAP` (50_000 chars) with a truncation
     note. Missing names raise a `ScoutException` naming the type and
     namespace directory.
   - `cortex_write(path, content, mode=:replace, agent=nil)` — writes/appends
     an artifact under `var/cortex/artifacts`. On replace of an existing
     artifact the current version is snapshotted to
     `artifacts/.history/<name>/<timestamp.seq>` before overwriting. A
     provenance sidecar `artifacts/.meta/<name>.json` accumulates a `versions`
     array of `{job, agent, mode, timestamp, size}` (`job` =
     `self.short_path` of the cortex_write job). Response is a single line:
     `Artifact written: <name> (<size> bytes, v<n>)` — content is never
     echoed.
2. `desc` blocks added to `continue_chat` and `brief_agent` (previously empty
   descriptions in tool definitions).
3. Export list: `continue_chat, brief_agent, cortex_list, cortex_search,
   cortex_read, cortex_write`.
4. `sanitize_artifact_path` rejects leading `/`, `~` prefix, any `..` path
   segment, and embedded newline/tab; subdirectory paths like
   `claims/C42.md` are allowed.
5. Chat quirk documented: `Chat.load` of a 1-message file yields 2 entries
   (leading empty separator). `Cortex.chat_messages` filters empty content
   messages, so message counts/indices exclude the leading separator.
6. Discipline sentence embedded in the `cortex_write` description:
   "Conversations are working space; artifacts are durable research objects.
   Extract reusable results as artifacts."
7. `research/design-decisions.md` and `research/notes-refactor.md`: corrected
   the overstated "prompt-only for brief_agent" wording — the dep chat is
   prompt-only on CREATION; on update it is grown with the existing brief.

## export vs exec_export decision

Chosen: `export` (async job tool with provenance) for all six tools. Reasons:
- The search brief documents `export` as the job-backed tool form; these tools
  are pure filesystem operations with no inline-latency requirement.
- Running as jobs gives free provenance: `cortex_write` records
  `job: self.short_path` in the `.meta` sidecar, and every tool call shows up
  as a job in the usual workflow provenance tree.
- `exec_export` was reserved in the plan for a tool that must run inline;
  none of the four qualifies.

## Deviations from the plan

- `sanitize_artifact_path` is stricter than the plan's "reject `..` or
  absolute": it also rejects `~` prefixes and embedded newline/tab (found
  during sandbox smoke tests, where a path argument containing file content
  produced multi-line error messages). Plan only asked for traversal
  rejection; the extra rejections are conservative and documented here.
- Message-count quirk handled by filtering (chosen option), documented in the
  `cortex_read` description ("Conversation indices exclude empty separator
  messages").
- `listing_tsv` helper exists but is unused by the task bodies (`listing_text`
  is used); kept because it is the natural building block for future
  structured output. No API impact.
- No parent-job discovery for `cortex_write` provenance: the plan said "record
  job: self.short_path ... keep it simple", so only the cortex_write job path
  is recorded; `agent` is recorded only when the tool caller passes it.

## Smoke test evidence (work item 3, LLM-free)

Commands were run from the repo root; scratch scripts lived under `tmp/`
and were deleted after the repair round (see below). All probes used
`Cortex.job(:cortex_list, ...).run` / `.load` style invocations.

Trimmed verbatim outputs:

```
=== cortex_list {:type=>"all"}
conversations	1 entry
  #name	messages	bytes	mtime
  probe	4	229	2026-08-24 22:05
briefs	1 entry
  #name	messages	bytes	mtime
  math	1	47	2026-08-24 21:29
artifacts	3 entries
  #name	bytes	mtime
  claims/C42.md	31	2026-08-24 22:19
  claims/hand.md	112	2026-08-24 22:08
  claims/probe.md	72	2026-08-24 22:08

=== cortex_list {:type=>"bogus"}
ERROR: Unknown Cortex namespace type "bogus"; valid types: conversations, briefs, artifacts, all

=== cortex_search {:query=>"TP53 PD_PI"}
#type	name	match
conversations	probe	0:user: We are probing the Cortex workspace. Marker: TP53 PD_PI pathway.
conversations	probe	1:assistant: Understood. TP53 and PD_PI noted.
artifacts	claims/probe.md	Probe claim about TP53 (v2) with PD_PI. Appended line about artifacts.

=== cortex_search {:query=>"nosuchtoken"}
No matches for "nosuchtoken"

=== cortex_read {:name=>"probe", :type=>"conversations", :range=>"0-1"}
user:
We are probing the Cortex workspace. Marker: TP53 PD_PI pathway.

assistant:
Understood. TP53 and PD_PI noted.

=== cortex_write {:path=>"claims/probe.md", :content=>"Probe claim about TP53 (v2) with PD_PI.\n"}
Artifact written: claims/probe.md (40 bytes, v2)

=== cortex_write {:path=>"claims/probe.md", :mode=>"append"}
Artifact written: claims/probe.md (72 bytes, v3)

=== cortex_write {:path=>"../escape.md"}
ERROR: Invalid artifact path "../escape.md": only simple relative paths under var/cortex/artifacts are allowed (no leading '/', no '..' segment, no '~' prefix, no newline or tab)
```

- Overwrite history snapshot verified: after the v2 replace,
  `artifacts/.history/claims/<timestamp>.1` contained the v1 text
  "Probe claim about TP53 (v1).".
- `.meta/claims/probe.md.json` accumulated three version records with
  `{job, agent, mode, timestamp, size}`.
- 60k-char artifact read returned 50,027 bytes ending with the truncation
  note ("big read size: 50027 truncated: true").
- Tool definitions via `LLM.workflow_tools(Cortex)`:
  `[:continue_chat, :brief_agent, :cortex_list, :cortex_search, :cortex_read, :cortex_write]`
  with non-empty descriptions and correct params/required
  (`cortex_read` requires `name,type`; `cortex_write` requires `path,content`;
  `cortex_search` requires `query`).
- `Cortex.all_exports` matched the export list.
- Receipts (`continue_chat`/`brief_agent` bodies) unchanged: both still
  `dep :continue, chat: :placeholder` + `agent_meta` receipt; only `desc`
  text was added.

## Repair round 1 (2026-08-24)

Critique findings on the first cut: one crash-path defect plus two minor
error-message issues. Minimal patch only; no new tasks, no API or export
changes.

### Defect (reproduced first)

`Cortex.conversation_slice` clamped `b` but not `a`. A range starting past
the end (`"5-9"` on the 4-message `probe` conversation) produced
`msgs[5..3] == nil` and then `NoMethodError: undefined method 'collect' for
nil` inside the task body.

Reproduction (repo root, before the fix):

```
$ ruby -e 'require "scout-ai"; require "./workflow";
  j = Cortex.job(:cortex_read, name: "probe", type: "conversations", range: "5-9"); j.run; puts j.load'
RAISED: NoMethodError: undefined method `collect' for nil
```

### Fixes (three touch points, all in module methods)

1. `conversation_slice`: after clamping `b`, `return '' if a >= msgs.length`
   (plus a comment: "Range starts past the end of the conversation; return
   empty instead of nil"). Behavior: a range entirely past the end returns
   empty text, no crash.
2. `sanitize_artifact_path` error wording changed to: "only simple relative
   paths under var/cortex/artifacts are allowed (no leading '/', no '..'
   segment, no '~' prefix, no newline or tab)" — subdirectory paths are
   explicitly still allowed.
3. The same error now truncates the displayed value via
   `Log.truncate_string(path.inspect)` (rbbt's standard truncation utility;
   `Log.ellipsis` does not exist in this stack), so a file-content-valued
   path cannot flood the error message.

### Re-verification (all probes re-run from repo root)

```
=== cortex_read {:name=>"probe", :type=>"conversations", :range=>"5-9"}
(empty string)

=== cortex_read {:name=>"probe", :type=>"conversations", :range=>"0-1"}
user:
We are probing the Cortex workspace. Marker: TP53 PD_PI pathway.

assistant:
Understood. TP53 and PD_PI noted.

=== cortex_write {:path=>"../esc.md"}
ERROR: Invalid artifact path "../esc.md": only simple relative paths under var/cortex/artifacts are allowed (no leading '/', no '..' segment, no '~' prefix, no newline or tab)

=== cortex_write {:path=>"/etc/passwd"}
ERROR: Invalid artifact path "root:x:0:0:root:/root:/bin/bash\ndaemon:x:1:1:daemon:/usr/sbin:<...truncated...>rivacy-respecting metasearch engine:/usr/local/searxng:/bin/bash": only simple relative paths under var/cortex/artifacts are allowed (no leading '/', no '..' segment, no '~' prefix, no newline or tab)
   # note: the long multi-line value is shown truncated by Log.truncate_string

=== cortex_write {:path=>"~/x.md"}
ERROR: Invalid artifact path "~/x.md": only simple relative paths under var/cortex/artifacts are allowed (no leading '/', no '..' segment, no '~' prefix, no newline or tab)

=== cortex_write {:path=>"claims/C42.md"}
Artifact written: claims/C42.md (31 bytes, v3)

=== cortex_list {:type=>"all"}
conversations	1 entry
  #name	messages	bytes	mtime
  probe	4	229	2026-08-24 22:05
briefs	1 entry
  #name	messages	bytes	mtime
  math	1	47	2026-08-24 21:29
artifacts	3 entries
  #name	bytes	mtime
  claims/C42.md	31	2026-08-24 22:19
  claims/hand.md	112	2026-08-24 22:08
  claims/probe.md	72	2026-08-24 22:08

=== cortex_search {:query=>"TP53 PD_PI"}
#type	name	match
conversations	probe	0:user: We are probing the Cortex workspace. Marker: TP53 PD_PI pathway.
conversations	probe	1:assistant: Understood. TP53 and PD_PI noted.
artifacts	claims/probe.md	Probe claim about TP53 (v2) with PD_PI. Appended line about artifacts.
```

- `ruby -c workflow.rb` → `Syntax OK`.
- Receipts untouched: `grep -c receipt workflow.rb` → 2 (the two `desc`
  mentions of "receipt" in `continue_chat`/`brief_agent` descriptions); the
  task bodies still return `{agent_meta: [...], content: ...}` unchanged.
- `grep -n "Range starts" workflow.rb` → the new guard comment in
  `conversation_slice`; `grep -n "Log.truncate_string" workflow.rb` → used in
  both the message-index fingerprint fallback and the sanitize error.

### Housekeeping (repair round)

Deleted scratch files: `tmp/fix_bodies.rb`, `tmp/fix_class.rb`,
`tmp/fix_read_body.rb`, `tmp/fix_read_default.rb`, `tmp/fix_return.rb`,
`tmp/fix_sanitize.rb`, `tmp/fix_search_body.rb`, `tmp/fix_search_body2.rb`,
`tmp/fix_search_body3.rb`, `tmp/step3_helpers.rb`, `tmp/smoke_tools.rb`,
`tmp/smoke_out.txt`, `tmp/smoke_err.txt`, plus the repair-round scratch
`tmp/repair1.rb`. Kept: `tmp/search-brief.md`,
`tmp/addition_problem_ADD-001.md`, `tmp/tmp-*.chat` (prior evidence), and the
remaining `tmp/*.rb` from earlier work items (`apply_impl.rb`,
`apply_step3.rb`, `patch_baseline.rb`, `probe_chat.rb`, `probe_mi.rb`).
Deleted legacy flat conversation `var/cortex/work_A` (left over from this
session). `var/cortex/briefs/math`, `var/cortex/conversations/probe` and
`var/cortex/artifacts/*` untouched except the probe artifact
`claims/C42.md` used for the "valid path still accepted" check, which was
removed again afterwards (its `.meta` sidecar too) so the workspace contains
only `claims/hand.md` and `claims/probe.md`.

### Open issues (unchanged from work item 3 unless noted)

- No parent-job discovery for `cortex_write` provenance (plan-sanctioned
  simplification).
- `listing_tsv` helper currently unused.
- Snippet/window sizes are fixed constants (200 chars artifact window, 100
  chars message snippet) rather than tool inputs.
- A path longer than the filesystem NAME_MAX (e.g. a ~300-char basename)
  passes `sanitize_artifact_path` but fails at `File.write` with
  `Errno::ENAMETOOLONG`; surfaced as a job error rather than a friendly
  message. Low priority (models do not produce such names in practice).
- `briefs/math` is still the hand-written fixture; replace during the later
  validation step.

## Addendum  -  `tools` input on `cortex_brief` (2026-09-04)

Implementation note for the brief tool-provisioning feature (engine:
`lib/Cortex/briefs.rb`; task declaration: `lib/Cortex/tasks/conversation.rb`).

- `tools` is an `:array` input on `cortex_brief` (default `[]`), a JSON array
  of spec strings (never comma-split; the task body re-parses a JSON string,
  mirroring the entity tasks' handling of their `:text arguments` input).
- Each spec follows `Workflow [task [input|name=value ...]]`
  (`TOOL_SPEC_GRAMMAR`). `validate_tool_spec` splits with `Shellwords`,
  requires identifier-like workflow and task tokens (`/\A[\w.:-]+\z/`),
  accepts input tokens that are bare identifiers or `name=value` (value may
  be empty and contain anything), and rejects `noinputs`/`none` unless they
  are the sole input token. Errors are actionable `ScoutException`s naming
  the offending spec (via `inspect`) and the grammar.
- `tool_messages` expands the specs in array order with the Chat builder API
  (no string surgery): a one-token spec (`whole_workflow_spec?`) emits
  `introduce <workflow>` then `tool <workflow>`; any longer spec emits a
  single `tool` message with the tokens rejoined by single spaces  -  the
  spec is otherwise pasted verbatim, so upstream scout-ai `tool:` semantics
  apply at continue time (bare names restrict accepted inputs, `name=value`
  pre-fills and hides the input, `noinputs`/`none` exposes no inputs).
- `save_brief(..., tools:)` implements replace semantics: with `tools` (even
  `[]`) the existing chat is passed through `strip_brief_tooling` (removes
  `tool`/`introduce`/`kb`/`mcp` roles on a copy) and the new block is
  prepended unless empty; with `tools` omitted (`nil`) the existing tooling
  is kept untouched.
- Validation is syntax only by design: workflow/task existence is never
  checked at brief time because a workflow may be installed later and
  unknown workflows make scout-ai attempt an install at continue time.
- The dep chat receives the same specs: `brief_prompt_chat` pastes each
  string verbatim as a `tool:` message (whole-workflow specs also emit
  `introduce:`) before the user prompt, so the brief-producing agent sees
  the provisioned tools while drafting. Provisioning is still delivered to
  a consuming agent through `Agent/brief` in `cortex_continue`, where the
  followed brief contributes the provisioned tools plus the framework's
  mandatory `tool: Cortex`.
- Distinct `tools` arrays yield distinct `cortex_brief` job paths (the input
  participates in job identity), and the task schema exposes `tools` on
  `cortex_brief` only (`cortex_continue` and `continue` expose no tool
  provisioning input of their own).
- Behavior is pinned by `test/Cortex/test_brief_tools.rb` (grammar variants
  and exact expected messages, verbatim pass-through, array order, the
  worked example, replace/keep/strip persistence, schema assertions, and
  the end-to-end mock-backend run proving the briefed agent carries exactly
  the provisioned tooling).
