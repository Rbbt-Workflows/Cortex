# Implementation reference: Cortex-managed executable Entities

This is the working reference for the implementer. It consolidates: the task
spec, the approved design, freshly verified probe results, the codebase state,
and a step-by-step plan with acceptance criteria. Read the design document
first; this file never contradicts it, only adds execution detail.

Primary sources:
- Design (approved): `research/cortex-managed-entities-design.md`
- Probe findings (verified this pass): `research/probe-property-task-findings.md`
- Conversational intent: `on_entities` conversation (orchestrator message)

## 1. Verified environment facts (from probes run this pass)

These are NOT assumptions; they were executed on 2026-08-25 against installed
scout-gear 10.12.2, ruby 3.3.1. Probes live in `tmp/probe_prop_task.rb`,
`tmp/probe_run2.rb`, `tmp/probe_run3.rb`.

1. **`<property>_job` DOES forward keyword arguments.**
   `g.probe_activity_job(treatment: 'PD_PI')` vs `g.probe_activity_job()` give
   different job paths (inputs enter the digest). So the executor can obtain a
   correctly-keyed Step by calling `<property>_job(**args)`.

2. **The public property wrapper drops arguments (upstream bug).**
   `EntityWorkflow#property_task` generates:
   `property property_name => property_type do |*args| job = self.send(property_job_name) ...`
   — `*args` are never forwarded. Calling the public property with arguments
   silently builds a default-args job. Consequence: after installing a
   property, Cortex must override the generated public property with a
   forwarding wrapper, and the executor should use `<property>_job` (or the
   wrapped public property) — never the raw generated one — when arguments are
   involved.

3. **Anonymous `Module.new` + `extend EntityWorkflow` + `name = 'X'` works.**
   Verified: runtime-created modules with an assigned name produce clean job
   paths `var/jobs/ProbeAnon/...`. This is the mechanism for
   `Cortex::ManagedEntities`.

4. **Nested constant modules also work** (`ProbeNest::Managed`), but produce
   job paths containing `ProbeNest::Managed` (with `::`). Prefer anonymous
   modules with assigned SHORT names (`Cortex::ManagedEntities::Gene` should
   be assigned `name = 'Gene'`, NOT left as the nested name) so job paths stay
   `var/jobs/Gene/...`. Note: two types assigned the same short name from
   different namespaces would collide in job-path space; keep the registry the
   single source of truth and assign names from the registry only.

5. **ALL inputs (including defaulted ones) participate in job identity.**
   Explicit vs omitted default input changes the job path; `task_info[:inputs]`
   lists declared inputs + the entity-name input (e.g. `[:treatment, :probe_gene]`).
   Therefore the executor must ALWAYS pass the definition-identity inputs
   (`_cortex_definition`, `_cortex_definition_version`, `_cortex_definition_digest`)
   explicitly; their mere presence with explicit values is what changes identity.
   (Do not try to change defaults to force invalidation — pass explicitly.)

6. **Step EXECUTION is blocked inside this sandbox** (`Errno::EROFS` on
   `~/.scout/tmp` locks / `~/.scout/var/jobs`). Redirects attempted after
   `require 'scout'` failed (paths finalized). In-sandbox you can: compile
   modules, compute job paths, validate definitions, run non-LLM unit tests
   that don't call `Step#run`. To actually RUN property jobs (smoke tests,
   dependency/invalidation tests) you must either run on the host outside the
   bwrap exec tasks, or set the var/tmp redirect BEFORE requiring scout
   (untested — probe `Scout::Config.set({'directory'=>...})` ordering first).

7. **`property_task` annotation mechanics**: every call re-declares all
   `annotation_input`s plus an entity-name input before `task(...)`. Managed
   entities should keep `annotations` empty (no `annotation_input` calls) so
   tasks only carry declared property arguments + the entity input + the hidden
   identity inputs.

8. `update_property`-style boolean inputs in the demonstrator change job
   identity (probe 4a) — exactly the flaw the design's `update` input avoids
   by cleaning instead of re-keying.

## 2. Current codebase state (baseline to build on, do NOT revert)

- `workflow.rb` (modified, uncommitted): full workspace layer (path maps,
  pagination, artifacts with `.meta`/`.history`, edit/rename/remove/move);
  `write_map` default `:current`, `read_maps` `[:lib, :current, :user]`;
  requires `Cortex/tasks/entity` at the bottom; export list at the end must
  gain the new entity tools.
- `lib/Cortex/entities.rb` + `lib/Cortex/tasks/entity.rb`: demonstrator only
  (`update_entity_module` with hardcoded `test`/`test_dep`). Rewrite both;
  delete the demonstrator semantics entirely.
- `test/test_cortex_workspace.rb`: 28-check invariant suite; runs against live
  workspace but purges `probe/test/*` names; MUST keep passing. Pattern to
  copy for the entity suite (same `check`/`expect_raise` helpers, sandbox
  names under `entities/probe/`).
- `test/Cortex/test_entities.rb`: demonstrator test; replace with the real
  suite (or delete if folded into `test/test_cortex_entities.rb`).
- `test/test_helper.rb`: prepends `lib/` to `$LOAD_PATH` — so
  `require 'Cortex/entities'` works from tests. Note the workspace suite
  requires `../workflow` directly instead.
- README.md documents all tasks under `# Tasks` with one-liner + explanation;
  `doc/user/WorkspaceTools.md` documents each tool's semantics; conventions:
  no inline `desc` in workflow.rb, input descriptions are the model-facing
  docs, tools are additive (never rename/remove exported tools).
- Research conventions: per-pass notes under `research/`, critique record,
  test results file.
- Git repo exists; prior passes committed. Current tree is dirty
  (`workflow.rb` modified, `lib/`, `test/Cortex/` untracked) — commit when done.

## 3. Where the new code goes

```
lib/Cortex/entities.rb          # registry, resolution, loader/compiler, storage, validation
lib/Cortex/tasks/entity.rb      # cortex_property_* + cortex_entity_property tasks
workflow.rb                     # require path (already present), export list += 8 tools
test/test_cortex_entities.rb    # new invariant suite (host-run for Step#run parts)
doc/user/WorkspaceTools.md      # new tool sections
doc/developer/Workspace.md      # entities namespace storage notes (optional)
README.md                       # # Tasks entries for the 8 new tasks
research/notes-entities-impl.md # implementation notes for this pass
research/scout-gear-property-task.patch  # staged upstream fix
research/test-results-entities.md        # archived run
```

Storage layout (from design; `entities` is a 4th namespace with special rules):

```
var/cortex/entities/<Type>/<property>.rb
var/cortex/entities/.meta/<Type>/<property>.json
var/cortex/entities/.history/<Type>/<property>/000001.rb + 000001.json
```

## 4. Detailed design deltas / implementation decisions settled by probes

These refine the design without changing it:

a) **Registry + naming**: `Cortex::ManagedEntities` is a plain module holding
   a registry Hash (logical type name -> module). Modules are anonymous,
   assigned `name = <Type>` from the registry key only. Reuse of an existing
   top-level Entity constant is allowed only if `mod.is_a?(Entity)` style
   check passes AND no collision with Cortex-owned properties; never mutate a
   non-Entity constant. Job-path space uses the assigned short name.

b) **Argument forwarding wrapper** (compatibility fix, always installed):
   after `property_task`, redefine the public property on the module:
   ```ruby
   mod.property property_name => property_type do |*args, **kwargs|
     job = mod.send(property_job_name, *args, **kwargs)
     # ... same run/load/join/error logic as EntityWorkflow's generated property
   end
   ```
   Implement it once in `Cortex/entities.rb` (do not copy scout-gear internals
   beyond the needed run/load semantics; keep it small: join if running, raise
   on unrecoverable error, clean recoverable, run unless done, load).

c) **Hidden identity inputs**: declared as normal `input`s on the managed
   module before `property_task` with default values = the CURRENT definition
   values, AND the executor passes them explicitly. Since defaults also enter
   identity (probe 5), a definition update with new defaults alone already
   re-keys jobs — belt and suspenders: update defaults AND pass explicitly.

d) **Executor**: prefer obtaining the Step via
   `entity = mod.setup(id, options); step = entity.send("#{property}_job", **args)`;
   then run/load it. Dynamic dependency wiring of an externally-created Step
   into `cortex_entity_property` is NOT verified to be supported — if a quick
   probe of the dep API fails, follow the design fallback: run the Step and
   return `property_job` in the receipt (path is explicit evidence). Do not
   burn time forcing dynamic deps this pass.

e) **`update` input**: `entity_property` executes; with `update=true` it calls
   `.clean` (optionally recursive via separate input) then run. It must NOT be
   part of job identity — which is automatic if it is an input of the OUTER
   Cortex task, not of the property task.

f) **Digest**: `Misc.digest` over a canonical string of
   `{body, property_type, result_type, arguments (name,type,required,default),
   dependencies, entity_type, property}` — exact schema in code comments.

g) **VersionedResource extraction**: design suggests extracting shared
   primitives from artifact versioning. Pragmatic call for this pass: keep
   entity storage self-contained in `Cortex/entities.rb` (body+meta atomic
   commit, history snapshots with version numbers `000001.rb/.json`) but
   follow the same conventions; full extraction is a refactor for a later
   pass (avoid destabilizing the 28 passing checks). If trivial, alias
   `sanitize_resource_name!` reuse for the entity namespace.

h) **cortex_list extension**: design says extend `cortex_list` with
   `type=entities`. That changes an existing tool's select options (cache
   prefix impact). Decision: DEFER this pass; `cortex_property_list` is the
   discovery surface. Note it in README as intended future extension.

i) **Name validation**:
   - entity type: `/\\A[A-Z][A-Za-z0-9]*\\z/` single segment (no `::` in v1
     storage paths; nested types add path complexity for no current need);
   - property/argument/dependency names: `/\\A[a-z][a-z0-9_]*\\z/`;
   - reserved: `job`, `entity`, `entity_list`, `inputs`, `list`, and any name
     ending in `_job`.

j) **Tombstone**: remove writes `.meta` with `active=false`,
   `removed_version`, provenance; keeps `.rb` ONLY in `.history`; active body
   file deleted from `entities/<Type>/`. Execution of an inactive property
   fails with an actionable message pointing at history.

## 5. Metadata schema (sidecar), exact

```json
{
  "schema": 1,
  "entity_type": "Gene",
  "property": "raw_activity",
  "description": "string",
  "property_type": "single|array|both",
  "result_type": "json|tsv|text|string|float|integer|boolean",
  "arguments": [
    {"name": "treatment", "type": "string|integer|float|boolean|select|array|json",
     "description": "str", "required": true, "default": null,
     "select_options": ["PD","PI"], "jobname": false}
  ],
  "dependencies": ["raw_activity"],
  "version": 2,
  "digest": "hex",
  "active": true,
  "versions": [
    {"version": 2, "digest": "hex", "action": "define|update|remove|reactivate",
     "job": "Cortex/cortex_property_update/...", "agent": "Worker",
     "timestamp": "YYYY-MM-DD HH:MM:SS"}
  ]
}
```

Unknown top-level metadata keys: reject (schema error), except during update
merge where we control the whitelist.

## 6. Compiler envelope (exact shape generated per property)

```ruby
# inputs: one per declared argument (type/desc/required/default/select)
input :treatment, :string, 'Treatment identifier', nil, required: true
input :_cortex_definition, :string, 'Cortex definition address', 'Gene/raw_activity'
input :_cortex_definition_version, :integer, 'Cortex definition version', 1
input :_cortex_definition_digest, :string, 'Cortex definition digest', 'abc...'
dep :raw_activity  # for each declared dependency, same entity type
property_task({ raw_activity => :json }, :single) do
  <exact body text from the .rb file>
end
```

Compiled with `module_eval(src, path, line)` where path is the definition file
and line is the offset of the body inside the generated envelope, so
backtraces cite the cortical `.rb` file. Generate source by building an array
of lines; NEVER interpolate names without prior validation (all names pass the
regexes in §4.i).

## 7. Task surface (8 tasks, all exported once)

| task | inputs (beyond common) | returns |
|---|---|---|
| cortex_property_list | entity_type, prefix, offset, limit | text listing: Type/property, property_type, result_type, version, deps, #args |
| cortex_property_read | entity_type, property, start_line, lines | text: metadata header + bounded body page (never executes) |
| cortex_property_history | entity_type, property, offset, limit | text version/action/job/agent/timestamp list |
| cortex_property_validate | entity_type, property, candidate (json), entity, arguments (json) | text report; supports candidate-without-activate and active+smoke |
| cortex_property_define | entity_type, property, body, metadata (json: description, property_type, result_type, arguments, dependencies), entity (smoke), arguments (smoke) | text confirmation: address, v1, digest, smoke result |
| cortex_property_update | entity_type, property, body (nil=keep), metadata (json partial), expected_version (required), entity (smoke), arguments (smoke) | text confirmation: address, new version, digest |
| cortex_property_remove | entity_type, property, expected_version (required) | text confirmation tombstone |
| cortex_entity_property | entity_type, property, entity (string or json array), entity_options (json), arguments (json object), update (bool), recursive (bool) | json receipt per design §Execution |

Common conventions: `ScoutException`/`ParameterException` with actionable
messages (missing property lists available properties of that type; stale
version message includes current version); `job: self.short_path, agent:`
provenance recorded into `.meta.versions`; atomic commit = write body+meta to
tmp then rename; history snapshot BEFORE activating new version.

## 8. Test plan mapping (what must be covered, and where it can run)

In-sandbox-safe (no Step#run): schema/name validation, duplicate define,
stale expected_version, failed-candidate-leaves-active-intact (compile error),
tombstone blocks execution at the API level, history/metadata provenance
fields, ambiguous-map rejection, path traversal, pagination, read-bounded,
ownership/collision rules, registry resolution, envelope compilation.

Requires host run (Step#run): smoke execution receipts, actual job paths for
single/array/both on scalar+list receivers, dependency chain A→B invalidation
(B update → new B job path → new A job path), update cleans without re-keying,
structured result types, annotations/options.

Run on host: `ruby test/test_cortex_entities.rb` and
`ruby test/test_cortex_workspace.rb` (regression). In-sandbox: `ruby -c` all
files. Mark Step#run-dependent tests so they can be skipped in-sandbox with a
flag (`SKIP_RUN=1`) so CI-ish flows still validate the rest.

## 9. Step-by-step order (respect dependencies between steps)

1. Rewrite `lib/Cortex/entities.rb`: name validation, schema validation,
   storage (atomic write, history, meta), digest. No compilation yet.
2. Registry/resolution (`Cortex::ManagedEntities`, anonymous modules with
   assigned names, reuse rules, collision detection).
3. Staging compiler: envelope generation + `module_eval` with path/line,
   including the argument-forwarding public-property wrapper; validation
   levels 1-2.
4. Loader `Cortex.load_entity_type`: type-wide lazy load, ambiguity rejection,
   dep graph validation (missing/cycle), topological compile, manifest digest
   memoization + hot reload (only remove Cortex-owned methods).
5. Rewrite `lib/Cortex/tasks/entity.rb` with the 8 tasks; add to `export` in
   workflow.rb; delete demonstrator `entity_property` or alias it after
   contract review (recommend: remove; it was never exported).
6. README `# Tasks` + `doc/user/WorkspaceTools.md` + developer docs; research
   notes (impl notes, scout-gear staged patch, test results).
7. Tests: in-sandbox suite first (fast feedback), then host-run suite; run
   workspace regression.
8. Commit.

## 10. Acceptance criteria (from the task spec, verbatim)

- `ruby -c` passes on `workflow.rb` and every file under `lib/`.
- New invariant suite passes covering: define→execute receipt with real
  `property_job` path; duplicate define fails; update with stale
  `expected_version` fails; failed update leaves active version intact;
  remove tombstones, preserves history, blocks execution; history/metadata
  provenance records job and agent; dependency chain A→B recomputes A after
  B's definition update (new job identities); name/path validation rejects
  traversal, reserved and malformed names; entity module reuse vs
  unrelated-constant collision vs non-Cortex property collision; list
  pagination; body read bounded and non-executing.
- `ruby test/test_cortex_workspace.rb` (existing 28 checks) still passes.
- Demonstrator code removed; no references remain.
- All new tasks registered, exported, documented in README.md `# Tasks`; no
  inline `desc`; input descriptions self-contained for models.
- A code-level smoke run demonstrates: define property for an implicit entity
  type, execute via the exported tool, receipt contains `property_job` and
  result, definition update produces a new property job identity and
  invalidates a dependent property.

## 11. Scout-gear upstream patch to stage (not apply; repo read-only here)

```diff
--- entity.rb (installed scout-gear 10.12.2)
+++ property_task fix
   property property_name => property_type do |*args|
-    job = self.send(property_job_name)
+    # forward receiver-provided args/kwargs to the job property
+    job = self.send(property_job_name, *args)
   end
```

Save as `research/scout-gear-property-task.patch` with a header explaining:
bug (public property drops args), evidence (probe 1e/1c), suggested regression
test (`assert g.probe_activity(treatment: 'X')_job path == g.probe_activity_job(treatment:'X')_job path`).
Note that `property_task`'s own `*args` parameter is unused and could forward
to `task(...)` for result-type extras — out of scope for this fix.

## 12. Open items deliberately deferred (do NOT implement now)

- `multiple` property type (needs per-member persistence tests).
- Cross-entity dependency mapping language.
- `cortex_list type=entities` (schema change to existing tool).
- Dynamic dependency wiring of the property Step into the outer task (fallback
  receipt path is sufficient; revisit when scout-gear dep API confirmed).
- Full `VersionedResource` extraction shared with artifacts.
- Semantic search / NER / ChatAnalyst / AGS ontology / relevance injection.
