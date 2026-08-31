# Cortex-managed executable Entities

This page documents the entity engine (`lib/Cortex/entities.rb`) and its task
layer (`lib/Cortex/tasks/entity.rb`): how Scout `Entity` properties become
first-class, versioned Cortex resources backed by real Workflow Steps.

**You should read this if:** you are changing property compilation, the
metadata schema, or the lifecycle/execution semantics.

---

## Storage layout

```
var/cortex/entities/
  Gene/activity_in_treatment.rb         <- trusted Ruby body (the property task body)
  .meta/Gene/activity_in_treatment.json <- metadata schema v1
  .history/Gene/activity_in_treatment/  <- prior versions, NNNNNN.rb + NNNNNN.json
```

- The address is compound: `<Type>/<property>`. `<Type>` is a Ruby constant
  path (`Gene`, `Study::Sample`); `<property>` is snake_case.
- Resolution goes through the same `read_maps`/`write_map` machinery as the
  other namespaces, but a definition that exists in **two distinct physical
  locations** is a hard `ScoutException`: two copies of executable code at
  one address are never merged or silently preferred.
- Writes are body-first, metadata last: a crash between the two leaves an
  orphaned body that cannot be activated (nothing resolves without `.meta`).

## Metadata schema v1

```json
{
  "schema": 1,
  "entity_type": "Gene",
  "property": "activity_in_treatment",
  "description": "…",
  "property_type": "single",            // single | array | both
  "result_type": "float",               // any Scout workflow type
  "arguments": [{"name": "treatment", "type": "string",
                 "description": "…", "required": true, "default": null}],
  "dependencies": ["normalized_activity"],
  "version": 1,
  "digest": "…64 hex…",
  "active": true,
  "versions": [{"version": 1, "digest": "…", "action": "define",
                "job": "…", "agent": "…", "timestamp": "…"}]
}
```

`single2array` / `array2single` are accepted as aliases and normalized to
`array` / `single`.

## Digest rule

`SHA256` over canonical JSON of `{body, property_type, result_type,
arguments, dependencies}`. **`description` is excluded on purpose**:
documentation edits must not invalidate cached evidence. Everything else
does — and because the digest participates in the job's cache identity, any
semantic change moves every job of that property.

## Envelope contract (compilation)

A property is compiled into an *anonymous module* that behaves like an
`Entity` + `EntityWorkflow`:

1. **Fresh generations, never redefinition.** Each manifest (the set of
   active definitions of a type, in dependency order) is compiled into a
   *new* anonymous module keyed by the manifest digest in a process-local
   registry. Re-declaring a same-named task in a live module is unreliable:
   `Persist.memory` memoizes `Task` objects, so the first body keeps running
   (probe: a redefined body returned the first result at the same path).
   A digest change therefore builds a new generation and re-points the
   registry; nothing is redefined in place, and dropping a property simply
   means the new module lacks it.
2. **`mod.name = <Type>` and `mod.entity_name = underscored type`** are set
   *before* any task is declared — the entity input declaration needs them,
   and they make job paths read `var/jobs/Gene/<property>/<entity>`.
3. **Hidden identity inputs** are declared on every property task and
   participate in cache identity:
   - `_cortex_definition` (`"<Type>/<prop>"`),
   - `_cortex_definition_version` (integer),
   - `_cortex_definition_digest` (string).
   They have **no defaults**: a default equal to the active value never
   reaches `non_default_inputs`, so the job hash would not change on
   definition updates. Values are passed explicitly on every call.
4. **Dependencies use explicit `dep` blocks with option forwarding**, never
   bare `dep :name`:
   ```ruby
   mod.dep(:dep_name) do |jobname, options|
     args = options.slice(*declared_arguments_of(dep_name))
     args = args.merge(identity_of(dep_name))   # the DEPENDENCY's identity
     mod.job(:dep_name, options[mod.entity_name], options.merge(args))
   end
   ```
   The block must be declared *before* the `property_task` that uses it.
   Forwarding the full option set (author arguments + the dependency's own
   identity inputs) creates a real `Step` dependency and makes definition
   updates propagate to both the dependency's and the dependent's job path.
5. **`property_task` + our forwarding wrapper.** The upstream
   `property_task` does not forward `*args` to `<property>_job`
   (scout-gear 10.12.2 defect), so after declaring the task we install our
   own wrapper via `define_method(<prop>)`:
   - `:single` / `:both`: `<prop>_job(*args, **kwargs)` then run/load;
   - `:array` with a scalar receiver: `make_array` + member selection
     (`res[container_index]` when contained, else `res[self] || res[0]`).
6. **Bodies are compiled from the definition file path.** The author's body
   is read with `File.read` and wrapped in a `Proc` evaluated with the
   `.rb` path as filename, so syntax errors and backtraces cite the
   definition file, not the engine.

## Body contract

A body is arbitrary trusted Ruby executing in the task body, where:

- `entity` — the annotated entity (scalar receiver), or the string
  `"Default"` for a *list* receiver of a `:both` property;
- `entity_list` — the list receiver (`:both`);
- `inputs[...]` — the declared arguments (they are also declared as task
  inputs, so they arrive positionally as locals);
- `step(:dep)` — a dependency's `Step` (`.load` its result).

`:both` bodies branch on `Array === entity_list`; the compile envelope
declares the `entity_list` helper on the step methods of `array`/`both`
properties so that helper resolves inside the body (the raw list arrives as
the `list` input).

## Receiver shapes and result selection

`Cortex.run_entity_property` drives `<prop>_job` directly and selects the
value per receiver shape:

| property_type | scalar receiver | list receiver |
| --- | --- | --- |
| `single` | one job, its value | one job per member, values in order |
| `array` | container job, member-selected value | container job, list value (plus per-member jobs) |
| `both` | entity branch | `entity_list` branch (single container job) |

The receipt's `property_job` follows the same shape: `String` when a single
Step produced the evidence, `Array` when the receiver produced one Step per
member.

## Dependencies and invalidation

- Dependencies must be active properties of the **same entity type** and the
  graph must be acyclic (topological compile; cycles raise).
- **Closure-aware required arguments.** A property that depends on another
  must also be able to forward the arguments the dependency needs. An
  argument that no property in the dependency closure declares is rejected;
   a missing required argument of the closure raises with an actionable
  message naming the property that needs it.
- Invalidation is automatic through the identity inputs: updating a
  dependency (new digest/version) changes the dependency's job hash and,
  through the `dep` block's option forwarding, the dependent's hash too.

## Lifecycle

| Operation | Semantics |
|-----------|-----------|
| `define` | refuses if an active property exists; stages and compiles the candidate in a scratch module (syntax/compile errors surface before anything is written); optional smoke execution; writes body then meta; version 1 |
| `update` | requires `expected_version == active version`; snapshots body+meta to `.history/NNNNNN.{rb,json}`; omitted fields keep their value; bumps version and appends provenance |
| `remove` | requires version match; snapshots to history; writes a tombstone (`active:false`, `removed:true`); **deletes the active `.rb`** so the property stops being executable/resolvable; history is preserved and the address can be redefined |
| `history` | compact view of `.history` + the `versions` array |

## Execution and receipts

`Cortex.entity_property_job` / `run_entity_property` validate arguments
against the schema (closure-aware), annotate the entity with the module
(`mod.setup`), and call `<prop>_job(**arguments)`; the task layer returns the
8-key receipt `{entity_type, entity, property, arguments,
definition_version, definition_digest, property_job, result}` where
`property_job` is the Step `short_path`. No agent metadata is attached: the
producing step *is* the provenance. Repeat calls replay from cache;
`update: true` cleans and recomputes at the same path.

## Trusted Ruby

Property bodies are **trusted executable Ruby**. Definitions are written by
agents that already have write access to the workspace; execution is not
sandboxed and no sandboxing is claimed. This is the same trust boundary as
any workflow task in the repository.

## Known limitations

- No cross-entity-type dependencies (`Gene/x` cannot depend on `Sample/y`).
- Multiple/`:both` receivers are exercised but the list form is the least
  used path.
- `cortex_search` does not index definitions; discovery is
  `cortex_property_list` (deliberate, for this milestone).

## Execution registry

Property *executions* are persisted separately from property *code*:

```
var/cortex/
  entities/    # property code: <Type>/<property>.rb + .meta + .history
  properties/  # execution records: <Type>/<property>/<receiver>.json
  lists/       # named entity lists: <entity_type>/<list> (+ .meta)
```

A record is written by the engine (`run_entity_property`) on every
execution. `receiver` is either an entity id or, for named lists,
`list:<type>_<list>`. Each `examinations` entry is one distinct argument
set: re-running the same arguments increments `runs`; new arguments
create a new examination. Every entry records `arguments`,
`arguments_digest`, `first_run`/`last_run`, `forced_update`,
`property_job` (the producing Scout Step short path — the evidence
producer, never the outer Cortex task), `definition_version`,
`definition_digest`, `result_digest`, `first/last_producer_job`,
`first/last_agent`, and `list` when the receiver came from a named list.

Entity options flow as task *inputs*: managed entity modules declare the
entity-type annotations (`entity_new_module` adds
`annotation entity_name`), and `entity_vector_job` merges
`entity_options` into the job args. This is required because the
`entity`/`entity_list` helpers rebuild receivers from
`inputs.to_hash`; annotation values that are not job inputs are lost on
rebuild (observed: `organism` nil in `:single`/`:both` bodies).

## Named lists and list dispatch

`annotate_receiver` is the single place that establishes the persistence
contract: lists become `AnnotatedArray` entities of the module's type
(named lists carry a `list` annotation naming their source); scalars
become annotated single entities. `:single` fans out one Step per
member; `:array`/`:both` run one vector Step keyed by `Default` with the
receiver in the `:list` input. The registry records the named-list
execution (`list:<type>_<list>`) plus one member record per entity, so
an agent can ask both "was this list examined" and "was this entity
examined".

Stale property jobs are invalidated by list mutation: when
`run_entity_property` runs with `list_name`, the list file path is resolved
through `read_list` and every done job older than that file
(`Path.newer?(job.path, list_path)`) is cleaned before execution, so the
next run recomputes without `update: true`. `update: true` still
force-cleans regardless of mtimes; a missing list file never triggers the
clean (the task layer has already raised). Note one registry limitation:
the list receiver record (`list:<type>_<list>`) tracks `runs` for the
argument set but does not store the member set itself, and members
removed from a list keep their last record until they are examined
again; the per-member records (including newly added members) are the
authoritative view of who was examined.

## Inline arrays vs named lists (agent guidance)

The task layer accepts an inline JSON array in `entity` for backwards
compatibility. Arrays with more than three members execute unchanged but
the receipt gains a `note` field steering the agent toward the canonical
`cortex_write_list` + `list:` workflow. The note is additive: no existing
receipt field changes, and named-list runs never carry it. This is a
model-facing affordance, deliberately not an error, matching the "ideally
list-first" requirement.

## Activity report and the facet registry

`Cortex.activity_report(entity_type:, entity:, facets:, limit:)`
(`lib/Cortex/activity.rb`) is a read-only join over existing stores for ONE
entity, exposed as the `cortex_activity` task. It dispatches over
`Cortex::ACTIVITY_FACETS`, an ordered Hash of `name => { 'description' =>
String, 'block' => Proc }` mirroring scout-ai's prompt-strategy registry
(`Chat::REGISTERED_STRATEGIES`): the registry is module-level, facets live
one per file under `lib/Cortex/activity/` and self-register at load time,
and `activity.rb` requires them in a fixed order so section order is
deterministic without an explicit list.

Facet contract: the block receives a `Cortex::ActivityContext` (read-only
accessors `entity_type`, `entity`, `limit`, `requested_facets`, plus
`property_definitions`, `property_definition`, `investigation_status`,
`examinations`, `entity_examinations`, `list_entries`, `list_meta`,
`mentions`) and returns a section `{'facet' => name, 'title' => String,
'items' => [Hash...], 'meta' => Hash}`. The dispatcher normalizes the shape
and applies `limit` per section AFTER the facet sorts. Facets must sort
items explicitly (never rely on glob/hash order), never embed result
payloads, wall-clock time, or anything non-deterministic: identical inputs
over an identical workspace must produce an identical report. Unknown facet
names raise an actionable `ScoutException` listing the registered facets.

Dispatcher pagination contract: every section `meta` carries `total` (the
facet's full item count), `shown` (items actually returned, `<= limit`),
and `has_more` (`shown < total`). A bounded report therefore never
masquerades as a complete count; agents distinguish "three exist" from
"twenty exist, three shown" without a second call. Facets that bound their
own scan (mentions) state so in their `meta.note`; their `total` covers the
bounded sample, not the corpus.

Investigation availability (`ActivityContext#investigation_status`):
investigations are cross-checked against the definitions that exist NOW,
yielding `active`, `older` (a newer version is current; the recorded
digest identifies the code that actually produced the recorded evidence),
or `removed` (no active definition). This deliberately separates the
historical fact (the property was executed — the examination record is
never rewritten) from the current capability (it can be executed as-is).
Map identifiers in facet items are bare strings (`current`, `lib`, ...)
everywhere; `Entities#map_tag`'s colon-prefixed form is display-only and
must not leak into facet items.

Adding a facet: create `lib/Cortex/activity/<name>_facet.rb`, call
`Cortex.register_activity_facet(<name>, description:, &block)` at load
time, and add the `require_relative` line to the fixed require list at the
top of `lib/Cortex/activity.rb`. Nothing else changes (the task and its
`README.md` section stay untouched). Test-local facets can register the same way
without touching core files; see `test/Cortex/test_activity.rb`.
