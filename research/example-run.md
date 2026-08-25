# Example run — workspace management pass

Environment note: in this sandboxed run the worker's own code-execution
tools (bash/python/ruby) fail with a bwrap namespace kernel restriction, so
the worker verified its arithmetic manually and flagged that clearly. This
is a host limitation, not a Cortex issue.

## Sequence (from `tmp/e2e_management_out.txt` plus a direct CLI tail)

1. **`cortex_brief`** — briefed `Worker` as brief `brief-math-check`
   ("always recompute arithmetic with bash"). Saved under `briefs/` with
   `.meta` sidecar (agent + producing job + timestamp).
2. **`cortex_continue`** — unbriefed Worker proposed a sum in conversation
   `probe/e2e-management` (247 + 589). Receipt:
   `job=Cortex/continue/Default_81cb....chat`.
3. **`cortex_write`** — wrote `probe/e2e-management/answer.md` with
   `status: pending` (v1), nested path.
4. **`cortex_continue` with `agent: Worker/brief-math-check`** — the
   briefed worker solved and double-checked: **836**. Receipt intact.
5. **`cortex_read` lines 2-3** — header `# lines 2-3 of ... (next: 4)`.
6. **`cortex_edit`** — `status: pending` → `status: solved`; reported
   `(1 occurrence replaced, 48 bytes, v2)`; v1 snapshotted to `.history`.
7. **`cortex_rename`** — `answer.md` → `final.md`; history and `.meta`
   moved with it; message reported the map.
8. **`cortex_search "solved"`** — found the renamed artifact first
   (`probe/e2e-management/final.md`) plus the older `summing/answer.md`;
   conversations and artifacts as separate sections.
9. **`cortex_move` to `current`** — in this checkout `:lib` and `:current`
   resolve to the same directory: reported as a no-op, resource intact
   (this is the sync-like semantic; a real transfer happens once the two
   maps differ).
10. **`cortex_list`** with `prefix`/`offset`/`limit` — paged metadata-only
    listing.
11. **`cortex_remove`** — removed content + `.meta` + `.history` in one
    action; no stale sidecars left.
12. **Legacy alias** — `continue_chat` on the same conversation returned
    the byte-identical receipt shape
    `{agent_meta: [{role: :meta, content: "job=Cortex/continue/..."}], content: "OK-LEGACY-ALIAS"}`.

## Receipts

Every `cortex_continue`/`cortex_brief` turn (and their legacy aliases)
returned `agent_meta: job=Cortex/continue/<id>.chat`, so the parent
conversation keeps an explicit provenance edge to each child execution.
Workspace tools returned one-line confirmations, never full contents.
