# Findings — workspace management pass

## What changed in this pass

1. **One storage abstraction under all tools.**
   `CORTEX_WRITE_MAP = :lib`, `CORTEX_READ_MAPS = [:lib, :current]`;
   `namespace_dir` / `resource_path` / `resource_paths` /
   `resolve_resource` / `namespace_entries` / `ambiguous_names` are now the
   only place path-map logic lives. No task resolves paths on its own.
   `resource_paths` deduplicates maps resolving to the same directory, so
   in this checkout (where `:lib` and `:current` coincide) legacy data is
   listed, searched, and read exactly once with no migration.

2. **Four management tools added.**
   - `cortex_edit` — exact `find`→`replace`, strict failure on missing or
     ambiguous target unless `all: true`; previous version snapshotted.
   - `cortex_rename` — logical rename within a map; content + `.meta` +
     `.history` move together; `rename` version record with `renamed_from`.
   - `cortex_remove` — explicit namespace; deletes sidecars and prunes
     empty parents; no stale metadata.
   - `cortex_move` — path-map transfer of the whole logical object with a
     `move` version record; reported no-op when both maps resolve to the
     same physical directory.

3. **Naming canonicalized.** `cortex_continue` / `cortex_brief` are the
   canonical tasks (implemented directly, canonical descriptions);
   `continue_chat` / `brief_agent` are `task_alias`-style delegating
   wrappers returning byte-identical `{agent_meta, content}` receipts.
   The internal `continue` chat_task was not renamed.

4. **Listing/search/read made path-map aware and bounded.**
   - `cortex_list`: `type` is exactly `all | conversations | briefs |
     artifacts` (briefs no longer implicitly folded into conversations),
     `offset`/`limit` pagination with `shown/total` and `(more: offset=N)`
     markers; path map is appended to names only when the name exists in
     more than one map.
   - `cortex_search`: searches every readable map; same four-type filter;
     snippet output; `limit`.
   - `cortex_read`: artifacts use line pagination
     (`start_line`/`line_count`, header `# lines A-B of T (next: B+1 |
     end)`, 50k char cap retained); conversations keep index +
     `last`/`range`; cross-map ambiguity is reported, never hidden.

5. **Nested names are first-class everywhere** (recursive enumeration in
   all three namespaces, consistent in list/search/read/write/edit/
   rename/remove/move).

## Verification

- Invariant suite: `ruby test/test_cortex_workspace.rb` → 28 passed, 0
  failed, 0 errored (archived in `test-results.md`, including traversal,
  ambiguity, pagination-boundary, and missing-target cases).
- End-to-end LLM run (`tmp/e2e_management_out.txt`, summarized in
  `example-run.md`): brief → unbriefed continue → briefed continue with
  `Agent/brief` syntax → `cortex_write` → paginated `cortex_read` →
  `cortex_edit` → `cortex_rename` → `cortex_search` finding the renamed
  artifact; plus a direct `cortex_move`/`cortex_remove`/alias check. Every
  `cortex_continue` turn returned the `job=Cortex/continue/...` receipt.
- Note: in the sandboxed run the worker could not execute code through
  bwrap (kernel restriction); the arithmetic was verified manually by the
  worker and flagged as such. This is an environment issue, not a Cortex
  issue.

## Decisions worth revisiting

- `cortex_move` is a no-op when the maps coincide. Once Cortex is installed
  (not run from a checkout), `:lib` and `:current` will differ and moves
  will be real transfers; the test suite covers the no-op path only.
- Listing pagination is per-namespace-section (`offset` applies inside each
  section for `type: all`); a global cursor was considered and deferred.
