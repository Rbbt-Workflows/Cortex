# Workspace management pass — test results

Run: `ruby test/test_cortex_workspace.rb` from the repository root
(workflow loaded via `require_relative '../workflow'`).

All operations run against the real `var/cortex` store using disposable
`probe/test/...` names (nested paths exercise the recursive listing).

## Summary

```
SUITE: 28 passed, 0 failed, 0 errored
```

## Covered invariants

- write → read (full and line-paginated, nested names)
- write → search (content found across read maps, limit honored)
- write → edit → read (single occurrence; strict failure on ambiguous /
  missing target; `all` opt-in for multiple)
- write → rename → read (history and .meta moved with the artifact)
- write → remove (no stale .meta / .history left behind)
- write → move between path maps (as one logical object; `:lib` and
  `:current` resolve to the same physical directory here, so the move is a
  reported no-op and the resource stays intact)
- same logical name in two readable maps → deterministic `:lib` precedence
  and explicit ambiguity notice in reads
- legacy `:current`-only resource still discoverable by list/search/read
- pagination boundaries: empty page, single-item page, offset beyond end
- read beyond end of resource
- search limit
- non-existent rename/move/edit/remove targets raise clear ScoutExceptions
- path traversal (`..`), absolute paths, and `~` names rejected in every
  operation
- briefs isolated from conversations (no leakage through shared storage)
- listings are metadata-only (content markers never appear)

## Full final run

```text
PASS  write -> read (artifact roundtrip through lib write map)
PASS  write -> read (nested name, first page reports lines/total)
PASS  write -> search finds nested artifact content
PASS  search honors limit
PASS  edit replaces single occurrence
PASS  edit fails on missing target
PASS  edit fails on ambiguous target without all=true
PASS  edit with all=true replaces every occurrence
PASS  append mode extends artifact and bumps version
PASS  replace mode snapshots previous version to .history
PASS  edit snapshots previous version to .history
PASS  rename moves content + .meta + .history together
PASS  rename preserves path map
PASS  rename of missing target fails
PASS  remove deletes resource and leaves no stale meta/history
PASS  remove of missing target fails
PASS  move keeps one logical object (maps coincide -> no-op)
PASS  read resolves :lib first when name exists in both maps
PASS  read reports cross-map ambiguity
PASS  legacy :current-only resource found by search
PASS  pagination: empty page beyond end
PASS  pagination: single item page
PASS  read beyond end reports no more lines
PASS  path traversal rejected (write)
PASS  path traversal rejected (rename)
PASS  absolute path rejected
PASS  tilde path rejected
PASS  brief namespace is isolated from conversations
PASS  listing never returns contents

SUITE: 28 passed, 0 failed, 0 errored
```
