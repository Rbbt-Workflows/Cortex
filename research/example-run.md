# Example run: briefs, conversations, artifacts, receipts

Recorded 2026-08-24 from a full run through the public Cortex tasks
(`Cortex.job(:task, ...).run` from the repository root). Trimmed for length;
original transcripts: `tmp/e2e_out.txt` (run script `tmp/e2e_run.rb`).

Environment: LLM inference reachable; the repository checkout is not a git
repo in this sandbox; sub-agent exec tools (`bash`/`python`/`ruby`) run inside
a nested bubblewrap that this sandbox cannot start, so the Worker could not
machine-verify arithmetic and reported manual cross-checks instead.

## 1. Brief the Worker with a non-prefixed brief name

```
Cortex.job(:brief_agent,
  conversation: "bash-math",
  prompt: "You are a math worker. When asked to compute any sum, always use bash arithmetic rather than mental math. Reply with one sentence acknowledging this.",
  agent: "Worker")
```

Status: done.

```json
{
  "agent_meta": [
    {"role": "meta", "content": "job=Cortex/continue/Default_ee7323909672a9654dae64de491cf299.chat"}
  ],
  "content": "Acknowledged: whenever I need to compute any sum or arithmetic result, I will use the bash tool to calculate it rather than relying on mental math."
}
```

Stored: `var/cortex/briefs/bash-math` (user turn, `meta: job=...`, assistant
turn) and `var/cortex/briefs/.meta/bash-math.json`:

```json
{"agent":"Worker","job":"Cortex/continue/Default_ee7323909672a9654dae64de491cf299.chat","timestamp":"2026-08-24 23:09:16"}
```

Note the brief name does not contain the agent name; the agent is recorded in
the sidecar.

## 2. Unbriefed Worker proposes a sum in conversation `Summing`

```
Cortex.job(:continue_chat, conversation: "Summing",
  prompt: "Propose an interesting arithmetic sum (a single addition problem). Do NOT solve it; leave it for another worker. State the sum clearly and nothing else.",
  agent: "Worker")
```

Status: done. Receipt: `job=Cortex/continue/Default_6c8bffad9ea49ed85da0b35e0a89437b.chat`

```json
{"agent_meta":[{"role":"meta","content":"job=Cortex/continue/Default_6c8b...chat"}],
 "content":"**8,976,431 + 2,895,764**"}
```

## 3. Briefed worker (`Worker/bash-math`) solves it

```
Cortex.job(:continue_chat, conversation: "Summing",
  prompt: "Solve the sum proposed earlier in this conversation. Compute it exactly.",
  agent: "Worker/bash-math")
```

Status: done. Receipt: `job=Cortex/continue/Default_965effd61a3b287d5db530ccc233baf2.chat`

The agent tried `bash` (`echo $((8976431 + 2895764))`), then `python` and
`ruby` (its brief demands machine computation); all nested-sandbox exec calls
failed at startup, and it fell back to two independent manual methods that
both gave:

```
8,976,431 + 2,895,764 = 11,872,195
```

The brief was resolved from the `briefs` namespace through the
`Agent/brief` syntax; there is no coupling between the brief file name and the
agent name, and no `Worker/Worker/math`-style confusion.

## 4. Workspace tools over the grown workspace

`cortex_list type=all`:

```
conversations	1 entry
  #name	messages	bytes	mtime
  Summing	14	34578	2026-08-24 23:10
briefs	1 entry
  #name	messages	bytes	mtime
  bash-math	3	391	2026-08-24 23:09
artifacts	1 entry
  #name	bytes	mtime
  summing/answer.md	278	2026-08-24 23:10
```

`cortex_search "8,976,431"` (conversations + artifacts):

```
#type	name	match
conversations	Summing	4:assistant: **8,976,431 + 2,895,764**
conversations	Summing	13:assistant: ## Execution summary - What I tried: computed **8,976,431 + 2,895,764** using `bash` arithmetic (`ec
```

`cortex_search "bash" type=conversations`:

```
#type	name	match
conversations	Summing	7:function_call: {"name":"bash","arguments":{"cmd":"echo $((8976431 + 2895764))"},"id":"call_..."}
conversations	Summing	8:function_call_output: {"name":"bash","content":"{\"exit_status\":-1, ...
conversations	Summing	13:assistant: ## Execution summary - What I tried: computed **8,976,431 + 2,895,764** using `bash` arithmetic (`ec
```

`cortex_read Summing type=conversations range=0-1`:

```
user:
Propose an interesting arithmetic sum (a single addition problem). Do NOT solve it; leave it for another worker. State the sum clearly and nothing else.
meta:
job=Cortex/continue/Default_6c8bffad9ea49ed85da0b35e0a89437b.chat
```

`cortex_read bash-math type=briefs range=0-0`:

```
user:
You are a math worker. When asked to compute any sum, always use bash arithmetic rather than mental math. Reply with one sentence acknowledging this.
```

## 5. Artifact write with provenance and versioning

`cortex_write path=summing/answer.md mode=replace agent=Manager`:

```
Artifact written: summing/answer.md (278 bytes, v1)
```

Second write with corrected content:

```
Artifact written: summing/answer.md (494 bytes, v2)
```

After the replace, `artifacts/.history/summing/answer.md/20260824231352.1`
contains the v1 text (verified by reading it back), and
`artifacts/.meta/summing/answer.md.json` accumulates:

```json
{"versions":[{"job":"Cortex/cortex_write/Default_33f0...","agent":"Manager","mode":"replace","timestamp":"2026-08-24 23:10:37","size":278},
             {"job":"Cortex/cortex_write/Default_8bca...","agent":"Manager","mode":"replace","timestamp":"2026-08-24 23:13:52","size":494}]}
```

`cortex_read summing/answer.md type=artifacts` returns the current v2 content
in full.

## Final artifact content (v2)

```
# Summing conversation result

The unbriefed Worker proposed the sum 8,976,431 + 2,895,764 in
conversation Summing; the Worker briefed with bash-math solved it
(11,872,195). The briefed agent attempts machine computation (bash/ruby)
first per its brief; in this sandbox exec tools were unavailable and it fell
back to two-method manual arithmetic that agreed.

Provenance: each turn in conversations/Summing carries a meta job= reference
to its Cortex/continue job (see the conversation file).
```

## What this demonstrates

- Briefs live in `briefs/` under arbitrary names; the target agent is in the
  `.meta` sidecar and in the `Agent/brief` reference syntax.
- Conversations live in `conversations/` and accumulate turns with `meta:
  job=Cortex/continue/...` provenance lines; briefs are never loaded from the
  conversations namespace.
- Artifacts live in `artifacts/` with `.meta` provenance sidecars and
  `.history` version snapshots; `cortex_write` answers with one line.
- Every delegation returns the frozen receipt `{agent_meta, content}` where
  the job is the foreign key to the full child execution.
