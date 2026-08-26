# Workspace Implementation

This page documents the storage layer: the path-map abstraction, namespaces,
listings, search, bounded reads, artifact provenance/versioning, and the
management operations.

**You should read this if:** you are changing how Cortex stores, finds, or
returns research objects.

---

## One storage abstraction

Every tool resolves resources through the same module-level functions; no
task contains its own path logic.

| Method | Purpose |
|--------|---------|
| `write_map` / `read_maps` | write map and read order (see Anchoring and path maps below; `Scout::Config` keys `cortex.write_map` / `cortex.read_maps` override) |
| `namespace_dir(ns, map = write_map)` | physical directory for a namespace in a path map |
| `sanitize_resource_name!(name)` | rejects absolute paths, `..`, `~`, and empty names |
| `resource_path(ns, name, map)` | physical path of a logical name in a map |
| `resource_paths(ns, name, maps = read_maps)` | candidate `[path, map]` pairs; maps resolving to the same directory are deduplicated |
| `resolve_resource(ns, name, maps)` | first existing candidate plus the full candidate list |
| `namespace_names(ns, map)` / `namespace_entries(ns, maps)` | discovery (recursive, dot-entries hidden) |
| `ambiguous_names(ns, maps)` | names existing in more than one map |

Namespaces: `conversations`, `briefs`, `artifacts` — all three support
nested names (`probe/test/a.md`), all enumerated recursively, dot-dirs
(`.meta`, `.history`) excluded everywhere.

Convenience accessors (`conversation_path`, `brief_path`, `artifact_path`,
... ) are thin wrappers over the same functions.

## Anchoring and path maps

`lib/Cortex/path_maps.rb` resolves the storage root per project:

1. **Anchor.** `SCOUT_CHAT_DIR` (set by Scout-AI to the libdir of the chat
   being executed; inherited by job subprocesses, including the ComputerUse
   bwrap sandbox) or the `Scout::Config` key `cortex.chat_dir`. Without an
   anchor (running from the Cortex checkout) maps collapse to the checkout:
   `:lib`, `:current`, `:user`, write `:current`.
2. **yaml maps.** `cortex_path_map.yaml` (project root, then `etc/`)
   attaches other projects' cortex stores:

       maps:
         cortex:
           dir: /home/mvazque2/git/workflows/Cortex
         ags:
           dir: /home/mvazque2/git/workflows/AGS
           read_only: true

   Entries become instance-level maps on `CORTEX` (the global
   `Path.path_maps` table is never modified) and may redefine `:lib`.
   `read_only: true` maps are searched for reads and rejected as
   `cortex_move` targets. Read order: `:chat` (anchor project, when
   anchored), yaml maps in file order, then `:lib`, `:current`, `:user`.

`Cortex.configure_cortex!` is idempotent and reconfigures on an anchor
change; `Cortex.chat_anchor` returns the active anchor (nil when
collapsed to the checkout).

## Resolution and ambiguity

`resource_paths` deduplicates maps that resolve to the same physical
directory (in this checkout `:lib` and `:current` coincide, so legacy data
is seen exactly once). Reads resolve in `read_maps` order (`:lib` first);
when a name exists in two *different* physical locations, `cortex_read`
prints both paths instead of silently picking one, and `cortex_list` /
`cortex_search` tag such names with `:map` suffixes.

## Listing and search

- `cortex_list`: metadata only, `offset`/`limit` pagination
  (`DEFAULT_LIST_LIMIT = 50`), sections report `<shown>/<total>` and a
  `(more: offset=N)` marker. `type` is `all | conversations | briefs |
  artifacts` — no implicit expansion.
- `cortex_search`: case-insensitive, multi-term AND, one snippet
  (~200 chars) per resource, `limit` (default 20), searches every readable
  map. For conversations the brief namespace is *not* implicitly included.

## Bounded reads

- Artifacts: line pagination `start_line` / `line_count`
  (`DEFAULT_READ_LINES = 200`, `READ_CAP = 50_000` chars). Header
  `# lines A-B of T (next: B+1 | end)`.
- Conversations: compact index by default; `last` / `range` for full
  messages (50k cap).

## Artifact provenance and versioning

- Write (`replace`/`append`) and edit snapshot prior content to
  `artifacts/.history/<name>/<timestamp>.<n>` and append to
  `artifacts/.meta/<name>.json` a version record `{job, agent, mode,
  timestamp, size}` (mode is one of `replace`, `append`, `edit`, `rename`,
  `move`).
- `cortex_rename` moves content + `.meta` + `.history` together within the
  same map and appends a `rename` version record carrying `renamed_from`.
- `cortex_move` transfers the whole logical object between path maps and
  appends a `move` record with from/to maps; when both maps resolve to the
  same directory it is a reported no-op.
- `cortex_remove` deletes content plus both sidecars and prunes empty
  parent directories; no stale metadata survives.
- Producing jobs come from `self.short_path` of the calling task — the
  workflow job remains the single provenance source.

## Brief resolution (the ergonomic core)

`Agent/brief` (`Worker/bash-math`) means agent `Worker` plus brief
`bash-math` from `briefs/`. Briefs are never looked up in `conversations/`
and regular conversations are never used as briefs; both mistakes raise
actionable errors. A `.meta` sidecar in `briefs/.meta/` records the target
agent and producing job. No prefix coupling: the brief name does not need
to contain the agent name, and the legacy `var/cortex/<Agent>/<brief>`
location is detected and reported.

## Known environment limitation: property-step outputs under bwrap

Property steps persist their JSON results under the Scout jobs tree. The
default ComputerUse sandbox only mounts `~/.rbbt/var/jobs/{Cortex,Planned}`,
so from inside that sandbox property-step JSON outputs are machine-readable
but machine-unreachable (observed in the AGS pilot 2 audit; DEFECT-3 in
`AGS/var/cortex/artifacts/pilot2/defects.md`). Mitigations, both supported
without code changes:

- mount the jobs path into the sandbox (exec task `read_paths`), or
- read the receipt through a property: the `receipts` argument of
  `cortex_property_read` resolves a job path and returns its JSON.

## Invariants (tested)

`test/test_cortex_workspace.rb` covers: write→read; write→search;
write→edit→read; write→rename→read; write→remove; move semantics;
history/metadata preservation through edit/rename/move; no stale
metadata after remove; nested paths; cross-map ambiguity; pagination
boundaries; beyond-end reads; search limits; missing targets; path
traversal rejection; brief/conversation isolation; metadata-only listings.
See `research/test-results.md` for the archived run.
