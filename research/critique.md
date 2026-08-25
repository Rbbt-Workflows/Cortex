# Critique — workspace management pass (Critic record)

## Verdict: PASS

Verified against the acceptance list for the workspace-management pass.

## Evidence checked

1. **Tools exported.** `Cortex.tasks.keys` contains `:continue`,
   `:cortex_continue`, `:cortex_brief`, `:cortex_list`, `:cortex_search`,
   `:cortex_read`, `:cortex_write`, `:cortex_edit`, `:cortex_rename`,
   `:cortex_remove`, `:cortex_move`, plus the aliases `:continue_chat` and
   `:brief_agent` (`task_alias :continue_chat, Cortex, :cortex_continue`,
   `task_alias :brief_agent, Cortex, :cortex_brief`).
2. **Alias behavior.** `continue_chat` on the `Summing` conversation
   returned `{agent_meta: [{role: :meta, content: "job=Cortex/continue/Default_....chat"}], content: "OK-LEGACY-ALIAS"}` — the same receipt shape as `cortex_continue`.
3. **Storage abstraction.** `CORTEX_WRITE_MAP = :lib`,
   `CORTEX_READ_MAPS = [:lib, :current]`; all resolution flows through
   `namespace_dir`/`resource_path`/`resource_paths`/`resolve_resource`;
   grep found no per-task path-map logic. `resource_paths` deduplicates
   maps that resolve to the same directory, so legacy data in the shared
   checkout appears exactly once.
4. **Invariants.** `ruby test/test_cortex_workspace.rb` → **28 passed, 0
   failed, 0 errored**; output archived in `research/test-results.md`.
   Covers write→read/search/edit/rename/remove, move semantics,
   history/metadata preservation, nested paths, ambiguity, pagination
   boundaries, beyond-end reads, search limits, missing targets, traversal
   rejection, brief isolation, metadata-only listing.
5. **End-to-end.** `research/example-run.md` (backed by
   `tmp/e2e_management_out.txt`) shows brief → continue (unbriefed) →
   write → continue (briefed, `Worker/brief-math-check`) → paginated read
   → edit → rename → search → move (no-op in checkout) → remove → legacy
   alias, with `job=` receipts on every `cortex_continue` turn.
6. **Scope discipline.** No entity system, no semantic/entity retrieval,
   no relevance injection, no ChatAnalyst integration, no AGS-specific
   code. `continue` chat_task not renamed; `chat_task` structure untouched.
7. **Docs.** `doc/StartHere.md`, `doc/user/`, `doc/developer/`,
   `research/` updated; canonical names used throughout, aliases noted.

## Notes / residual risks (non-blocking)

- In this checkout `:lib` and `:current` are the same physical directory,
  so `cortex_move` real-transfer behavior is only exercised via the
  same-location no-op; the test suite asserts that no-op path. A deployment
  where the maps differ should re-run the move tests.
- Listing pagination applies `offset` within each namespace section for
  `type: all` (documented); a single global cursor was deferred.
- The e2e transcript reflects one LLM run; only structural behavior is
  claimed stable.
