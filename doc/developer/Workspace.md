# Workspace Implementation

This page documents the storage layer: namespaces, listings, search, bounded
reads, and artifact writes with provenance and versioning.

**You should read this if:** you are changing how Cortex stores, finds, or
returns research objects.

---

## Namespaces and path resolution

`Cortex.CORTEX` is `Scout.var.cortex` (repo-local in this checkout). All
paths derive from it:

| Method | Produces |
|--------|----------|
| `conversation_path(name)` | `var/cortex/conversations/<name>` |
| `brief_path(name)` | `var/cortex/briefs/<name>` |
| `brief_meta_path(name)` | `var/cortex/briefs/.meta/<name>.json` |
| `artifact_path(name)` | `var/cortex/artifacts/<name>` |
| `artifact_meta_path(name)` | `var/cortex/artifacts/.meta/<name>.json` |
| `artifact_history_path(name)` | `var/cortex/artifacts/.history/<name>/` |
| `namespace_names(ns)` | top-level entry names, dot-files excluded |
| `artifact_names` | recursive relative artifact paths, dot-dirs excluded |

`validate_type!` normalizes `type` to one of `conversations`, `briefs`,
`artifacts`, `all`; anything else raises.

## Brief resolution (the ergonomic core)

`resolve_brief(agent, brief)`:

1. `load_brief(brief)`  -  only `briefs/<brief>`; a non-file or empty chat is
   nil.
2. Missing brief -> build an actionable error: name the brief and agent; if a
   conversation with that name exists, say conversations are not briefs; if
   the legacy `var/cortex/<agent>/<brief>` exists, point at it and suggest
   `brief_agent`; list existing briefs (or note none exist yet).
3. Never falls back to the conversations namespace.

The `Agent/brief` syntax lives in the `agent` input of `continue_chat` and
`brief_agent`'s `agent` input. The brief file name and the agent name are
fully decoupled; the association is recorded in the brief sidecar
(`agent`, `job`, `timestamp`) written by `save_brief`.

## Message normalization

`chat_messages(chat)` drops messages with empty content. This exists because
`Chat.load` of a file whose first message is empty yields a leading empty
separator message; every count, index, search hit, and range slice uses this
normalization so indices are stable across saves. Message indices shown by
listing/search/index are indices into this filtered array.

## Listing

`namespace_listing(type, prefix)` gathers rows; `listing_text(type, prefix)`
renders. Conversations/briefs: name, message count, bytes, mtime. Artifacts:
name, bytes, mtime. `type: 'all'` renders the three sections with entry
counts. Dot-directories (`.meta`, `.history`) are excluded at both the
namespace and artifact glob level. There is also `listing_tsv` returning a
TSV object for programmatic use.

## Search

Lexical, case-insensitive, over chat message content and artifact file
content.

- `search_terms` splits on whitespace; `matches_query?` implements
  substring for a single term and AND for multiple terms.
- `search_conversations(query, type, limit)` walks `conversations` (and
  `briefs` unless restricted), scoring each non-empty message; a hit line is
  `index:role: snippet` (first 100 chars, whitespace-collapsed).
- `search_artifacts(query, limit)` walks artifact contents, returns
  `snippet_around` (a ~200-char window around the first term hit).
- The `cortex_search` task merges the two result sets under the shared
  `#type name match` header and honors `limit` across both.

Search is intentionally substring, not semantic; embeddings are deferred.

## Bounded reads

`cortex_read` semantics:

- Conversations/briefs without `last`/`range`: `conversation_index`  - 
  `index, role, fingerprint` per message (fingerprint falls back to
  `Log.truncate_string` of content).
- With `last: N` or `range: "a-b"`: `conversation_slice` renders
  `role:\ncontent` for the selected messages. `parse_range` validates
  `a <= b >= 0`; out-of-range clamps (empty string, never nil slices).
- Artifacts: full content.
- Everything passes through `cap_string` (`READ_CAP` = 50 000 chars) which
  truncates with a marker.

## Artifact writes

`write_artifact(path, content, mode, job:, agent:)`:

1. `sanitize_artifact_path` rejects empty paths, leading `/` or `~`, any
   `..` segment, and newlines/tabs  -  the write stays under `artifacts/`.
2. On `replace` of an existing artifact: snapshot the current content to
   `.history/<name>/<YYYYMMDDHHMMSS>.<seq>` where `<name>` keeps its
   subdirectory structure, so each artifact has its own version sequence.
3. Write the new content (`append` joins with a newline first).
4. Update `artifacts/.meta/<name>.json`: append to `versions` the record
   `{job, agent, mode, timestamp, size}`. The `job` recorded is the
   `cortex_write` job's `short_path` (passed by the task body as
   `job: self.short_path`).
5. Return `[name, bytes, version]`  -  the task body renders the single
   confirmation line. Content is never echoed.

The brief sidecar (`briefs/.meta/<name>.json`) is deliberately simpler: one
current record (agent, producing job, timestamp), not a version list, since
briefs are grown, not rewritten.

## Invariants worth preserving

- Only `chat_task :continue` runs inference; projections never build agents.
- `brief_agent` writes only `briefs/`; `continue_chat` writes only
  `conversations/`; `cortex_write` writes only `artifacts/`.
- Listing/search never return file contents whole; reads are bounded by
  `READ_CAP`; writes confirm in one line.
- Dot-directories are invisible to every listing/search/read path.
- The export list stays static (tool surface stability for cached prefixes).
