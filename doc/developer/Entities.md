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
