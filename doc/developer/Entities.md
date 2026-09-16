# Cortex entity properties (the Step-based subsystem)

This page documents the property engine as shipped after the subsystem
redesign (design/property-subsystem-redesign.md, implemented): how
entity types, properties, definition identity, addresses, receipts and
evidence relate, and where each concept lives on disk. The engine is
split across `lib/Cortex/entities.rb` (store + compilation),
`lib/Cortex/types.rb` (module factory + declaration engine),
`lib/Cortex/properties_run.rb` (run dispatch + address resolution +
the error envelope), `lib/Cortex/receipt.rb` (the run receipt),
`lib/Cortex/evidence.rb` (Step-derived evidence scan) and
`lib/Cortex/tasks/entity.rb` (the agent-facing task layer).

**You should read this if:** you are changing property compilation, the
metadata schema, lifecycle/execution semantics, or the tool surface.

---

## The organizing principle: concept → code → path

Every concept has exactly one code symbol and one path shadow:

| Concept | Code symbol | Path shadow |
|---|---|---|
| entity type | `Cortex::Types.for(<Type>)` — anonymous module named `<Type>` | `var/cortex/entities/<Type>/` (definitions), `var/jobs/<Type>/` (results) |
| entity | plain String id | the `<entity-id>` prefix of a result label |
| property | one task per property (`property_task` + Cortex dep wiring + wrapper) | `var/cortex/entities/<Type>/<property>` (body), `var/jobs/<Type>/<property>/` (results) |
| definition identity | defaultless inputs `_cortex_definition{,_version,_digest}` | the three values inside every `<label>.info[:inputs]`; version+digest in `.meta` |
| argument set | task inputs from the definition spec | the `_<32hex>` suffix of the label; values echoed in `.info[:inputs]` |
| result kind | task result type (`string`/`tsv`/`json`/...) | file extension (`.tsv`, `.json`) or its absence |
| materialized result | `Step` (`path`/`load`/`info`/`files_dir`) | `<label>[.ext]` + `.info` + `.files/` |
| address | `Step#short_path` | the path minus `var/jobs/` |
| dependency | `dep <property>` + `step(:<property>)` | upstream addresses in `.info[:dependencies]` |
| receipt | `Cortex::Receipt.build`; task `cortex_property_run` | no file — a projection of the Step |
| named list | `cortex_write_list`/`cortex_read_list` | `var/cortex/lists/<entity_type>/<list>` + `.meta` |

## Naming and addressing (the rules the engine guarantees)

```
full:      var/jobs/<Type>/<property>/<label>[.<ext>]
short_path: <Type>/<property>/<label>[.<ext>]        # Step#short_path
label:     <id> | <id>_<32hex> | Default_<32hex>
ext:       .tsv | .json | .yaml | .marshal           # TYPE_EXTENSIONS
```

- The hash appears on **every** Cortex property result: the three
  definition-identity inputs are defaultless and always provided, so the
  task digest gate always fires. Different argument sets never collide;
  a definition change moves the address.
- The entity id stays a clean readable prefix (`Tp53_<md5>`), never
  `Default_<md5>`, for single-entity runs.
- `:single` fan-out over a list gives every member its OWN digest
  (`Tp53_<md5A>`, `Kras_<md5B>`, ...): pairwise-distinct,
  independently addressable results. `:array`/`:both` produce ONE vector
  result labeled `Default_<md5>`. List receivers of `:single` are never
  routed through the vector form.
- Each dependency Step is digested via its ADDRESS (with its embedded
  hash) into the downstream hash: identical arguments over different
  upstream evidence yield different downstream addresses.
- `<Type>` modules get their `directory` PINNED to the checkout jobs
  root at build time (see "Job placement" below), so the result tree is
  the engine's own tree regardless of the process CWD.

## Job placement (checkout-rooted pin)

Every entity module built by `Cortex.entity_new_module`
(lib/Cortex/entities.rb) — managed anonymous AND adopted foreign — has
its `directory` pinned through `pin_module_directory!` to
`<checkout>/var/jobs/{TOPLEVEL}/{SUBPATH}`, an ABSOLUTE template that
`follow(:default)` expands to exactly `<checkout>/var/jobs/<Type>`. The
root is resolved ONCE from the Cortex project anchor
(`entity_jobs_root`), never from the process PWD, so a run from any CWD
roots at the checkout (a run with CWD `var/cortex/entities` still roots
at `var/jobs/<Type>/...`, not inside the entities namespace). History:
the earlier `:default => :current` annotation rooted at `{PWD}/var/jobs`
— anomaly A, see
`research/impl-step11-foreign-adoption-validation.md`.

Motivation: the checkout tree is mounted in the ComputerUse execution
sandbox; the home tree is not, so agents can read result files from
scripts. Mechanics (validated in
`research/impl-step9-current-placement-validation.md` and, for the
checkout pin, `research/impl-step11-foreign-adoption-validation.md`):

- The pin runs on EVERY module build (`Types.for`,
  `resolve_entity_module`, `load_entity_type`, `entity_stage_compile`);
  there is no newness gate. It merges a PRIVATE `path_maps` copy
  (`directory.path_maps.merge(default: ...)`), so the process-wide
  `Workflow.directory` Hash is never mutated — this closes defect D1
  of the `:current` era, where other workflow modules built later in
  the same process inherited the entity placement
  (`tmp/placement-step2.out` probes b1/b2/b3).
- The absolute template never re-enters `Path.map_order`, so placement
  is CWD-independent. `Path#find` is still FIRST-EXISTING-WINS across
  map order (scout-essentials path/find.rb:265-271), falling back to
  `follow(:default)` only when nothing exists (find.rb:273).
- Consequence (split evidence): labels whose old-root directories
  already exist — e.g. foreign types with pre-change evidence under
  `~/.scout` — keep replaying at the old root (first-existing-wins).
  Same definition, two roots; both resolve through `cortex_result`,
  which is root-independent.
- Guard test: `test/Cortex/test_placement_default.rb` pins the absolute
  pin (and its persistence across builds), real-run placement under the
  scratch root, the `follow(:default)` fallback, and the
  first-existing-wins boundary.

## Foreign entity adoption (three regimes)

A pre-existing `EntityWorkflow` module (e.g. `Security` from an external
workflow) is **adopted**: `resolve_entity_module` extends it with
`Entity` when needed, registers it under the type, and pins its job
directory like any managed module. A pre-existing constant that is NOT
an Entity/EntityWorkflow module stays a hard `ScoutException` (rule
(b): a plain constant must never be shadowed or extended). A foreign
type with ZERO Cortex definitions still loads (`load_entity_type`
returns the adopted module); the type is unknown only when no adoptable
constant exists either.

`cortex_property_run` classifies the regime BEFORE job building:

| Regime | Condition | Execution | Receipt |
|---|---|---|---|
| A — plain method | no active Cortex definition on an adoptable module | `receiver.send(property, ...)` on the entity object | same envelope, `definition: {version: 0, digest: null}`, `address`/`result_kind`/`status`/`materialized`/`info_path` null, `receiver` = entity id, `value` = raw return |
| B — task path | active Cortex definition (any origin) | build_jobs/execute_jobs, real Step | §2.7 11-key envelope (below) |
| C — define over adopted | `cortex_property_define`/`_update` on the adopted module | task path | §2.7 receipt with the NEW definition identity, served at a MOVED address |

- Regime A arguments rule: an empty Hash passes NOTHING; a non-empty
  Hash binds via `Method#parameters` — kwargs for `:key`/`:keyreq`, one
  positional Hash for a positional parameter, else `ParameterException`
  (verdict `argument_error`).
- Named lists: regime A executes members individually and returns ONE
  fallback receipt per member (tagged `entity_list`), preserving the
  `failed_members`/`total_members` counting; regimes B/C fan out as
  usual.
- Failures are never silently swallowed into a fallback: regime-B
  input-validation/build/execute failures and regime-A
  `NoMethodError`/`ArgumentError` both surface as the §2.6 error
  envelope.
- Defining on an adopted module must not silently REPLACE a foreign
  instance method: a property name occupied by anything that is not
  Cortex-owned is a hard error (ownership set).

## Definition store (unchanged locations, one rename)

```
var/cortex/entities/<Type>/<property>            # body (full Ruby file)
var/cortex/entities/.meta/<Type>/<property>.json # metadata (schema v1)
var/cortex/entities/.history/<Type>/<property>/  # version snapshots
```

- The address is compound: `<Type>/<property>`. `<Type>` is a Ruby
  constant path; `<property>` is snake_case.
- Resolution goes through the same `read_maps`/`write_map` machinery as
  the other namespaces. A definition that exists in **two distinct
  physical locations** is NOT an error: the first map in `read_maps`
  order WINS and lower-precedence copies are shadow-skipped — which is
  what makes overriding a property from a higher-precedence map legal.
  Which copy ran stays distinguishable after the fact: every execution
  receipt carries the winning definition's digest, and
  `cortex_property_list` shows shadowed copies as their own per-map rows
  (agents and users should stay mindful of overrides; the machinery
  never hides them). See `entity_sources`/`entity_resolve!` in
  `lib/Cortex/entities.rb`.
- Writes are body-first, metadata last.
- **The only schema change is the read-side rename `result_type` →
  `result_kind`.** Old definition files are NEVER rewritten; on disk the
  field is still `result_type`, readers derive `result_kind` from it,
  and the old spelling is recognized indefinitely (also on define/update
  inputs, reported with a loud deprecation warning).

Metadata schema v1 (as stored):

```json
{
  "schema": 1,
  "entity_type": "Gene",
  "property": "activity_in_treatment",
  "description": "…",
  "property_type": "single",
  "result_type": "float",
  "arguments": [{"name": "treatment", "type": "string",
                 "description": "…", "required": true}],
  "dependencies": ["normalized_activity"],
  "version": 1,
  "digest": "…64 hex…",
  "active": true,
  "versions": [ … provenance records … ]
}
```

`single2array` / `array2single` are accepted aliases. Digest rule:
`SHA256` over canonical JSON of `{body, property_type, result_type,
arguments, dependencies}`; **description is excluded** (documentation
edits never invalidate evidence).

## Compilation envelope

A property is compiled into an anonymous module named exactly `<Type>`
(`Cortex::Types.for`, delegating to the store's `entity_new_module`),
with declarations in this order per property:

1. **Author arguments** (from the definition spec).
2. **The three defaultless identity inputs** — after the author
   arguments because bodies bind inputs positionally. No defaults: a
   default equal to the active value would never reach the digest gate.
3. **Explicit `dep` blocks** (before the `property_task` that uses
   them), forwarding ONLY the arguments the dependency declares and
   REWRITING the identity inputs to the dependency's own active
   definition:
   ```ruby
   mod.dep(:dep_name) do |jobname, options|
     args = options.slice(*declared_arguments_of(dep_name))
     args = args.merge(identity_of(dep_name))   # the DEPENDENCY's identity
     mod.job(:dep_name, options[mod.entity_name], options.merge(args))
   end
   ```
4. **`property_task` + our forwarding wrapper** (scout-gear 10.12.2's
   public wrapper drops `*args`; the engine installs its own).

Fresh generations, never redefinition: each manifest digest compiles a
new module in a process-local registry (`Persist.memory` memoizes Task
objects, so in-place redeclaration keeps running the first body).
`mod.name = <Type>` and `mod.entity_name` are set before any task is
declared. Bodies are compiled from the definition file path so syntax
errors and backtraces cite the `.rb`.

The redeclaration memoization hazard is NEUTRALIZED for the task path by
the identity inputs, not by rebuilding the module: the three
`_cortex_definition*` inputs are merged into the SAME `arguments` hash
that becomes the Task memo key's `provided_inputs` (scout-gear
`workflow/task.rb:47`), so every definition change yields a NEW memo
key and a NEW result address — the stale memo entry simply never
matches. define/update additionally call `evict_task_job_cache!`
(prefix `Task_job_<property>:`), which is same-process memory hygiene
only: `Workflow.job_cache` is a plain process-local Hash, so eviction
matters for long-lived processes, never for correctness (step-4 probes
E1/E2, `tmp/step4-probes/VERDICT.md`, quoted in
`research/impl-step11-foreign-adoption-validation.md`).

## Body contract

Arbitrary trusted Ruby executing in the task body: `entity` /
`entity_list` (receiver helpers), `inputs[...]` (declared arguments,
also positional locals), `step(:dep)` (a dependency's Step).
Dependencies must be active same-type properties; the graph must be
acyclic; closure-aware required-argument validation raises actionable
errors naming the property that needs an argument.

## Run dispatch and receipts

`Cortex::Properties.run_property` builds every Step through `mod.job`
(never `Task#job` — only the module's step_module carries the
`entity`/`entity_list` helpers). Dispatch: `:single` → one Step per
receiver member; `:array`/`:both` → one vector Step (`Default_<md5>`)
with the `list:` receiver. Named-list staleness (list file newer than a
done Step) cleans and recomputes; `update: true` always recomputes at
the same address.

The receipt (section 2.7 of the design) is `{entity_type, property,
receiver, arguments, definition:{version,digest}, address, result_kind,
status, value (bounded), materialized:{path,bytes}, info_path}` —
mechanically derived from the produced Step. Fan-out runs return an
array of receipts; a member failure does not fail the run (the failed
member's receipt carries the error envelope, plus
`failed_members`/`total_members`).

The structured error envelope on every failure path:
`{exception_class, exception_message (verbatim), message_is_bare,
backtrace_head, verdict (argument_error | definition_error |
execution_error), context}`; bare raises (message == class name) get a
warning naming the raise site.

## Address resolution (`cortex_result`)

Literal path → `var/jobs`-prefixed short_path via `Step.load` → one
recovery pass matching the address's hex tail (16..32 hex digits; a
mangled prefix with an intact hash recovers) reported loudly →
structured `ParameterException` listing candidates. Ambiguous tails
error with all candidates. Resolution never executes: bare path-Steps
only.

## Lifecycle

| Operation | Semantics |
|-----------|-----------|
| `define` | refuses if an active property exists; stages + compiles in a scratch module; optional smoke; writes body then meta; version 1 |
| `update` | requires `expected_version`; snapshots to `.history/NNNNNN.{rb,json}`; omitted fields keep their value; bumps version |
| `validate` | compile-only or compile+smoke; smoke ALWAYS `clean: true` in a fresh scratch directory (a previous run's error text is structurally unobservable); never mutates the store; staging includes the type's manifest so dependent candidates resolve their deps |
| `remove` | requires version match; deletes the active `.rb` and KEEPS the meta tombstone (the removal record — `active: false`); drops the ownership entry so the module is re-adoptable; never leaves an orphaned body; history preserved; address redefinable |
| `define` over an orphaned body (body without `.meta`) | treats the body as absent: version 1 with fresh meta (the orphan carries no identity, so nothing to version-conflict with) |
| `history` | compact view of `.history` + `versions` |

## Evidence and the retired registry

**Current evidence is the var/jobs Step tree.** Each materialized
result's `.info` sidecar carries the argument set, the definition
identity, upstream dependency addresses, status, timestamps and
messages. `lib/Cortex/evidence.rb` (`Cortex.step_evidence`) scans
`var/jobs/<Type>/**/*.info` and derives the evidence rows used by
`cortex_activity` investigations and the `properties` namespace
listings/searches/reads.

**The execution registry (`var/cortex/properties/`) is retired.**
Nothing writes it. Legacy records (`<Type>/<property>/<receiver>.json`,
`examinations` arrays, receivers including the legacy
`list:<Type>_<list>` spelling) stay on disk untouched and are read
as-is as **history** (`source: registry_history`) by `lib/Cortex/properties.rb`
(the read-only reader), the activity facet, and the properties-namespace
reads. Superseded, not invalidated.

The design's OPTIONAL derived index (`var/cortex/index/`) was **not
built**: the activity and listing surfaces scan `.info` sidecars
directly.

## Activity report

`cortex_activity` is a read-only join for ONE entity over: defined
properties; materialized results (`source: step_info`, with address,
definition identity, step status); legacy records (`source:
registry_history`); containing named lists; lexical mentions. Facets
self-register under `lib/Cortex/activity/`; investigation status
(`active`/`older`/`removed`) cross-checks each item's recorded
definition version against the current active version. Deterministic:
identical inputs over an identical workspace produce identical output.

## Trusted Ruby

Property bodies are **trusted executable Ruby**, written by agents that
already have write access to the workspace; execution is not sandboxed
and no sandboxing is claimed. Same trust boundary as any workflow task.

## Test conventions for this subsystem

- All runs need `BWRAP=false` (the sandbox denies `/bulk` paths).
- Whole suite: `bash tmp/suite-runner.sh` (equivalently
  `BWRAP=false ruby -Itest -Ilib -e 'Dir.glob("test/**/test_*.rb").sort.each{|f| require File.expand_path(f)}'`).
- Isolation: entity suites install scratch path maps under
  `tmp/entity_test_var` AFTER the workflow loads (see
  `test/Cortex/test_helper.rb`), so definitions and jobs never touch
  `~/.scout`. The load-order constraint (workflow.rb before scratch
  maps) is documented in that helper's header.
- Subsystem suites: `test_types_receipt.rb` (§3 rules),
  `test_properties_run.rb` (dispatch + resolution),
  `test_property_tools.rb` (tool contracts),
  `test_registry_retirement.rb` (no-write guard, activity rewiring,
  migration, address purity), `test_property_history.rb` (definition
  store + legacy reads), `test_worked_example.rb` (the §10 walkthrough),
  `test_foreign_entity_adoption.rb` (regimes A/B/C, T1–T10).
- Placement guard: `test_placement_default.rb` (annotation + real-run
  rooting under the scratch `:current` root, `follow(:default)`
  fallback, first-existing-wins boundary).
- Suite-runner fact: the `SUITE:` line counts only
  `test/test_cortex_workspace.rb` own checks — the aggregate loads
  every file, but that file calls `exit` at load time, before Test::Unit
  autorun, so the Test::Unit test methods (all `test/Cortex/test_*.rb`
  suites, including the placement guard) run only via their standalone
  invocation (`BWRAP=false ruby -Itest -Ilib test/Cortex/<file>.rb`).

## Known limitations

- No cross-entity-type dependencies.
- Define/validate smoke of a DEPENDENT property stages the type's full
  active manifest (dependencies installed with the candidate), not the
  candidate alone: the dep block resolves its upstream task inside the
  same module, so a candidate-only staging module leaves the dependency
  nil and the smoke fails with `undefined method 'path' for nil`.
- The live foreign fixture run (Observation/probe on the
  `scout_essentials_lib` map) was verified as
  **body-executes-under-the-new-engine** via a scratch twin, not
  in-place: the chat harness's checkout mount is not visible to the
  test sandbox. Recorded in `research/impl-step6-worked-example.md`.
- Real-workflow foreign adoption (the `Finances::Security` demo) is
  verified only through a minimal in-process stand-in with the same
  contract; the real Finances workflow is absent from this machine
  (`research/impl-step11-foreign-adoption-validation.md`, open item).
