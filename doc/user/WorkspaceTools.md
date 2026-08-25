# Workspace Tools

This page documents the four `cortex_*` tools that agents use to navigate and
extend the Cortex workspace.

**You should read this if:** you are writing prompts for agents that work
inside Cortex, or you are an agent that just got the Cortex tools.

---

## `cortex_list`  -  compact inventory

Lists namespaces and their entries with metadata only. Never returns
contents.

```
cortex_list(type: "all", prefix: "")
```

- `type`: `conversations`, `briefs`, `artifacts`, or `all`.
- `prefix`: only entries whose name starts with it.

Output shape:

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

Use it to discover what exists; then use `cortex_read` on specific entries.

Note: like every Scout task, results are cached per input combination. If
the workspace changed since a previous identical call, use a different input
(e.g. a narrower `prefix`) to force a fresh run.

## `cortex_search`  -  lexical content search

Searches message content of conversations and briefs, and file content of
artifacts, and returns compact matches with snippets.

```
cortex_search(query: "8,976,431", type: nil, limit: 10)
```

- `query`: substring matched case-insensitively. Multiple whitespace-separated
  terms require every term (AND).
- `type`: restrict to `conversations`, `briefs`, `artifacts`, or nil for all.
- `limit`: maximum number of matches.

Output shape:

```
#type	name	match
conversations	Summing	4:assistant: **8,976,431 + 2,895,764**
conversations	Summing	13:assistant: ## Execution summary - What I tried: computed ...
```

The `match` column is `message-index:role: snippet` for chats; for artifacts
it is a line snippet. Results are cached per input combination; change the
query or `limit` to force a re-run after workspace changes. Use the message index with `cortex_read`'s `range` to
pull the full context.

Search is lexical (substring), not semantic.

## `cortex_read`  -  bounded retrieval

Reads a conversation, brief, or artifact with explicit bounds.

```
cortex_read(name: "Summing", type: "conversations", last: 3, range: nil)
cortex_read(name: "bash-math", type: "briefs", last: nil, range: "0-1")
cortex_read(name: "summing/answer.md", type: "artifacts", last: nil, range: nil)
```

- `type`: `conversations`, `briefs`, or `artifacts`.
- Without `last`/`range`, conversations and briefs return the compact message
  index (`index`, role, fingerprint) rather than full text.
- `last: N` returns the trailing N messages in full.
- `range: "a-b"` returns messages a through b inclusive in full.
- Artifacts ignore `last`/`range` and always return full content.

Conversations can be very large; prefer the index first, then pull ranges.

## `cortex_write`  -  durable artifact write

Creates or updates an artifact and returns a one-line confirmation.

```
cortex_write(path: "summing/answer.md", content: "# Result\n...", mode: "replace")
```

- `path`: relative to `artifacts/`; subdirectories allowed; `..` rejected.
- `mode`: `replace` (default) snapshots the previous version to
  `.history/<path>/<timestamp>.<seq>` and overwrites; `append` adds to the
  end, creating the artifact if absent.
- Automatic provenance: each write appends to `artifacts/.meta/<path>.json` a
  record of `job`, `agent`, `mode`, `timestamp`, `size`.

Response is only a status line, e.g.:

```
Artifact written: summing/answer.md (494 bytes, v2)
```

The content is never echoed back. Read it back with `cortex_read` if needed.

## Working discipline

The intended loop for an agent inside Cortex:

1. `cortex_list` to see the workspace.
2. `cortex_search` to find prior work on the topic.
3. `cortex_read` (bounded) to pull just what is needed.
4. Contribute via `continue_chat` or `brief_agent`.
5. `cortex_write` any durable result; keep conversations as working space
   only.
