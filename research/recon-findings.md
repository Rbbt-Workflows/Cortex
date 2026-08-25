# Cortex recon findings (Step 1)

## Paths
- Repo: /bulk/mvazque2/git/workflows/Cortex
- `Scout.var.cortex.find` resolves to `/bulk/mvazque2/git/workflows/Cortex/var/cortex` (repo-local, WORKS from inside repo).
- Existing conversations: `var/cortex/Summing`, `var/cortex/Worker/math` (plain chat files, `role:` blocks, `meta: job=...` lines).
- scout-ai: `/home/mvazque2/git/scout-ai` (git repo; read-only mount in this sandbox BUT writes allowed under `/home/mvazque2/git/scout-ai/tmp` only). Plan says: NO scout-ai edits this pass. The `agent_meta` contract in `lib/scout/llm/tools/call.rb` is already present and must not change.

## Tool exposure mechanism (verified)
- `agent.start_chat.tool 'Cortex'` = Chat annotation `message(:tool, content)`; processed by `Chat.tools` (chat/process/tools.rb): tokens = [workflow_name, task_name, *inputs].
  - `tool 'Cortex'` (no task) → ALL exported tasks of Cortex become tools.
  - `tool 'Cortex', :task_name` → only that task.
- Tool definitions come from `LLM.task_tool_definition` = task `desc` + input descriptions. So `desc` blocks ARE the tool docs: keep them precise and self-contained.
- `export :t` → async job tool (result produced via Workflow.produce); `exec_export` → `job.exec` inline.

## APIs verified
- `Chat.load(file)` — reads persisted chat WITHOUT compiling/executing (chat/process/meta.rb). Safe for provenance inspection. Use for read/search of conversations.
- `Chat.parse(text)` / `chat.print` (LLM.print) — message text format; `message[:role]`, `message[:content]`.
- `Chat.setup([])`, `chat.user(content)`, `chat.follow(msgs)`, `chat.save(path)` (path already a Path if from Scout.var).
- `Step.load(short_or_full_path)` — relocates `WF/task/name` under `var/jobs` (step/load.rb). Then: `.short_path`, `.path`, `.status`, `.done?`, `.error?`, `.aborted?`, `.running?`, `.info`, `.load`, `.dependencies`, `.provided_inputs`, `.task_name`, `.workflow`.
- `Chat.serialize_meta(job: short_path)` — existing receipt format.
- `Log.fingerprint`, `Log.ellipsis` (truncation helpers).

## ChatAnalyst (verified via help_workflow)
Tasks: `chat_overview`, `chat_report`, `chat_tool_calls`, `chat_tokens`, `chat_agents`, `message_index`, `message_content`.
Programmatic use: `ChatAnalyst.job(:chat_report, file: '/path/session.chat').run` (from its docs). Load with `Workflow.require_workflow 'ChatAnalyst'`.
`chat_overview` = chats+jobs+edges counts; `chat_report` = compact combined (session size, jobs, tokens, failures); `chat_tool_calls` = call index; `chat_tokens` = direct token usage.

## Docs convention (from scout-ai repo docs)
- `doc/StartHere.md` (paths/reading guide), `doc/user/*.md`, `doc/developer/*.md`, `research/*.md` at repo ROOT (sibling of doc/). Layering: Code → research/ → doc/developer → doc/user. Use this for Cortex.

## Briefing failure (from var/cortex/Worker/math)
`continue_chat(agent: "Worker/Worker/math", conversation: "Worker/math")` raised `ScoutException "No conversation Worker/Worker/math"` (partition: agent=Worker, brief conv="Worker/Worker/math" not found). Fix per plan: normalization candidates + actionable error listing candidates.

## Notes / decisions to apply
- New tasks get `desc` blocks (they become tool descriptions AND documentation).
- Conventions: conversations under `var/cortex/<name>`; artifacts under `var/cortex/artifacts/<name>` with `.meta/<name>.json` provenance sidecars and `.history/<name>/<version>` snapshots; dot dirs excluded from listing/search.
- Cache hygiene: no dynamic inventories in agent prefix; system message static.
- Testing without LLM: task helpers can be exercised with plain Ruby (`Cortex.job(:list_conversations,...).run`); briefing resolution extracted into a helper so it is unit-testable; full LLM smoke test optional if credentials work (try once; if not, unit-level + document).
