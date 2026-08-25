# Design decisions — workspace-management pass

Implements the "Cortex Workspace Management — Next Implementation Pass"
spec. Builds on `reference-scout-paths.md` (Scout path-map facts). Out of
scope, per spec: entities, semantic retrieval, auto-injection, ChatAnalyst
integration, AGS/biology concepts.

## 1. One storage abstraction

Single module-method layer in `Cortex` resolving every resource:

```ruby
Cortex::CORTEX_WRITE_MAP  # :lib  (default; Scout.config cortex.write_map)
Cortex::CORTEX_READ_MAPS  # [:lib, :current] (Scout.config cortex.read_maps)

Cortex.namespace_dir(namespace, path_map)      # Path under the map
Cortex.resource_path(ns, name, path_map)       # physical path for logical name
Cortex.resource_paths(ns, name, maps=nil)      # all readable physical paths
Cortex.resource_exists?(ns, name, maps=nil)
Cortex.resolve_resource(ns, name)              # first hit in READ_MAPS order
                                              # -> [path, map] or nil
Cortex.namespace_names(ns, path_map)           # recursive, dot-dirs hidden
Cortex.map_tag(map)                            # ':lib' or '' when unique
```

Rules:

- `sanitize_resource_name!` applies to ALL namespaces (conversations, briefs,
  artifacts): non-empty, relative, no leading `/` or `~`, no `..` segment, no
  newline/tab. Replaces the artifact-only `sanitize_artifact_path`.
- Nested names are legal everywhere (`conversations/AGS/heatmap` works like
  `artifacts/claims/C42.md`). `namespace_names` is recursive for all
  namespaces and returns relative paths; dot-directories (`.meta`,
  `.history`) are excluded at every level.
- Read precedence is READ_MAPS order (`:lib`, then `:current`). When the
  same logical name exists under more than one map, tools do NOT silently
  pick one: reads resolve to the first hit but **report the ambiguity** in
  the output (a `[note]` line listing both locations); listings and search
  tag the map when a name is present in several maps; otherwise no map tag
  is shown.
- Chat namespaces also carry sidecars: briefs have `.meta/<name>.json`;
  artifacts have `.meta/<name>.json` + `.history/<name>/`. Conversations have
  none. Sidecar paths are derived through the same map-aware helpers, so
  they travel with their resource on rename/move.

## 2. Tool surface (canonical names)

Canonical + compatibility (old names = `task_alias` shims, see below):

| tool | semantics |
|------|-----------|
| `cortex_continue` (was `continue_chat`) | grow `conversations/<name>` via `continue`, return receipt `{agent_meta, content}` |
| `cortex_brief` (was `brief_agent`) | grow `briefs/<name>` + `.meta` sidecar, return receipt |
| `cortex_list` | metadata-only, paginated, map-tagged when ambiguous |
| `cortex_search` | lexical, AND terms, snippets, all read maps, type filter `all/conversations/briefs/artifacts` |
| `cortex_read` | conversations/briefs: index or `last`/`range`; artifacts: line pagination |
| `cortex_write` | create/replace/append artifact in write map, history+meta |
| `cortex_edit` | exact find→replace in a resource (strict: missing/ambiguous fail) |
| `cortex_rename` | logical rename, same map, moves content+meta+history |
| `cortex_remove` | delete resource + its meta + history (explicit namespace required) |
| `cortex_move` | transfer between path maps, logical name unchanged, content+meta+history together |

`continue` (the chat_task) is NOT renamed.

### Renames/aliases

`cortex_continue`/`cortex_brief` are the real tasks. `continue_chat` and
`brief_agent` are `task_alias` shims (`task_alias :continue_chat, Cortex,
:cortex_continue`), so they keep identical inputs, output type, receipts.
Verified in `reference-scout-paths.md` §4. Export list gains the canonical
names; aliases stay exported (agents in old conversations keep working).

## 3. Semantics per operation

### cortex_write
- Writes to `resource_path(:artifacts, name, CORTEX_WRITE_MAP)`.
- On replace of an existing artifact in the same map: snapshot to
  `.history/<name>/<ts.seq>` (as today).
- `.meta/<name>.json` accumulates `{job, agent, mode, map, timestamp, size}`
  version records (new `map` field records the physical map written).

### cortex_edit
- Inputs: `name` (artifact), `find`, `replace`, `all` (bool, default false),
  optional `agent`.
- Resolves through READ_MAPS; edit applies to the resolved physical file
  (first hit). Ambiguity is allowed but reported in the result line.
- Match rule: exact substring. `find` absent → error. `find` present more
  than once and `all: false` → error naming the count. `all: true` replaces
  every occurrence.
- History/meta identical to a `cortex_write` replace (snapshot previous,
  append version record with `mode: 'edit'`).

### cortex_rename
- Inputs: `type` (namespace), `name`, `new_name`, optional `agent`.
- Same-map rename: `FileUtils.mv` the resource; for artifacts and briefs also
  move `.meta/<name>.json` → `.meta/<new>.json` and `.history/<name>/` →
  `.history/<new>/`. Never merges: error if target exists in any read map.
- Appends a version record `mode: 'rename'` to the artifact meta (keeps the
  provenance chain unbroken). Briefs: sidecar content unchanged apart from
  being moved; a `renamed_from` note is appended to it.
- Result line confirms old→new.

### cortex_remove
- Inputs: `type`, `name`. No implicit "any namespace": `type` is required.
- Removes the resolved resource (first hit in READ_MAPS) plus its sidecar
  meta and history dir for artifacts/briefs. Empty parent dirs pruned up to
  (excluding) the namespace root. Dot-dirs are never accepted as the target.
- Result line names exactly what was removed (paths).

### cortex_move
- Inputs: `type`, `name`, `to` (target path map), optional `agent`.
- Source = resolved resource (first hit). Target = same logical name under
  `to`. Error if source missing, if `to` == source map, or target exists.
- Transfer set: the resource itself + `.meta/<name>.json` +
  `.history/<name>/` (when present). Implemented with `FileUtils.mv` (same
  filesystem; mirrors Resource.sync's content transfer without forking
  rsync), i.e. a move, not a copy: source disappears. Rationale documented
  in `reference-scout-paths.md` §2.
- Appends version record `mode: 'move'` with `from`/`to` maps to artifact
  meta. Brief sidecar gets a `moved` note. Conversations move as-is.

## 4. Pagination

### Listing
`cortex_list` gains `offset` (default 0) and `limit` (default 50). Output
footer reports `total`, the returned window, and `next_offset` (only when
more entries exist). Applied per-section for `all` (each section paginates
independently with its own footer line).

### Artifacts
`cortex_read` gains `start_line` (1-based, default 1) and `lines`
(default 200). Output is a header line `# lines a-b of N (next: c)` followed
by the requested lines, then the 50k-char cap applies to the returned chunk.
Out-of-range start (`> N`) → error telling the agent the total; `start+beyond
end` returns the existing tail with the header noting the true range.
Conversations/briefs keep index + `last`/`range` semantics (unchanged).

## 5. Search interface

`cortex_search type` becomes exactly `all | conversations | briefs |
artifacts` (default `all`). `conversations` no longer implies briefs; the
implementation and the description agree. Multi-term AND, case-insensitive
substring, snippet per hit, `limit` (default 20) across all maps; when a hit
name is ambiguous across maps, the hit line carries the map tag.

## 6. Provenance invariants

- No second provenance system: version records stay the single mutable
  provenance log, keyed to the producing job's `short_path`
  (`cortex_write`/`edit`/`rename`/`move` jobs record `self.short_path`; brief
  sidecars record the `continue` job as before).
- Receipts unchanged: `{agent_meta: [{role: :meta, content:
  Chat.serialize_meta({job: continue.short_path})}], content: res.answer}`.
- `chat_task :continue` remains the only inference primitive.

## 7. Tests

`test/cortex_workspace_test.rb`, `test/unit` style (matches
`test/test_helper.rb` stub and scout's own harness). The suite re-points
`Cortex::CORTEX` at a `TmpFile` dir (`Cortex.instance_variable_set` /
re-setup of the annotated Path) so it never touches live workspace data, and
removes it at teardown. Coverage = the invariant list from the spec (write →
read/search/edit/rename/remove/move; nested paths; ambiguity; pagination;
error paths; traversal attempts). Driver: a plain runnable script whose
output is archived to `research/test-results.md` (and re-run by the Critic).

## 8. What changes for the existing data

Nothing migrates: `:lib` and `:current` resolve identically from the repo
root today, so all existing conversations/briefs/artifacts remain reachable
through READ_MAPS. The write map switch only matters in future/other- checkout
scenarios.
