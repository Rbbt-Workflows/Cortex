# Cortex-managed executable Entities: proposed design

Status: design proposal before implementation

## Goal

Replace manual transcription of analytical values with project-owned Scout
Entity properties. An agent defines a small, executable property body; Cortex
owns naming, storage, validation, versioning, loading, workflow registration,
job execution, and provenance.

The central invariant is:

> Numerical or structured evidence crosses into an agent context through a
> property job, not by an agent copying values out of a source file.

This is not a new evidence abstraction. The evidence producer is a normal Scout
Entity property, preferably backed by a normal Workflow Step through
`EntityWorkflow`.

## Scout findings that constrain the design

### Entity property dispatch

`Entity::Property#property` records the block parameter signature in
`properties[name]` and defines real methods according to the property type:

- `:single` and `:single2array`: `_single_<name>`; a list receiver maps the
  property independently over each member.
- `:array` and `:array2single`: `_ary_<name>`; a list receiver is processed once;
  a scalar receiver is wrapped as a one-member list and the corresponding
  result is selected.
- `:multiple`: `_multi_<name>`; the block receives a list of missing entities
  and supports per-member persistence.
- `:both`: `<name>` directly; the block receives the receiver as-is, whether it
  is a scalar entity or a list.

The names `single2array` and `array2single` do not currently introduce a
separate conversion in `Entity::Property#property`; they select the same real
method families as `single` and `array`, respectively.

Recommended Cortex public choices are initially `single`, `array`, and `both`.
`multiple` should be enabled after dedicated persistence tests. The two
`*2*` names should be accepted only as compatibility aliases, not advertised as
having conversion semantics that Scout does not implement there.

### EntityWorkflow

`EntityWorkflow.extended` extends the same module with `Workflow` and `Entity`,
adds `entity` and `entity_list` job helpers, and defines an Entity `job`
property. `property_task` creates:

1. a workflow task;
2. `<property>_job`, returning the Step; and
3. `<property>`, running/loading that Step.

This gives Cortex the desired normal job paths, cache, dependency metadata, and
Step provenance.

There are two current implementation details Cortex must not ignore:

1. `property_task(task_name, property_type, *args, &block)` does not use its
   `*args` parameter.
2. The generated public property accepts `*args`, but calls
   `self.send(property_job_name)` without forwarding them. Therefore property
   arguments do not reach the generated job through the public property.

Cortex should either fix this in scout-gear with regression tests, or install a
small corrected public wrapper after `property_task`. The preferred long-term
fix is in scout-gear; Cortex still needs a compatibility check because deployed
Scout versions may predate the fix.

The relevant installed source is:

- `scout-gear/lib/scout/workflow/entity.rb`, `EntityWorkflow#property_task`
- `scout-gear/lib/scout/entity/property.rb`, `Entity::Property#property`

### Workflow cache identity

Changing a Ruby body alone does not necessarily change an existing job path.
Every generated property task therefore needs hidden definition identity in its
inputs, at minimum:

- `_cortex_definition`: logical property address;
- `_cortex_definition_version`: integer version;
- `_cortex_definition_digest`: digest of body plus executable metadata.

The digest must include body, property type, result type, argument schema, and
dependencies. This makes a method update produce a different Step identity and
causes downstream dependency paths to change.

## Resource model

An entity type is implicit: the first property defined for `Gene` or
`Treatment` establishes that logical entity type in Cortex. There is no
separate mutable entity-class source file in the first API.

Active definitions:

```
var/cortex/entities/
  Gene/
    activity_in_treatment.rb
    trajectory.rb
  Treatment/
    timepoints.rb
```

Cortex-owned sidecars:

```
var/cortex/entities/.meta/Gene/activity_in_treatment.json
var/cortex/entities/.history/Gene/activity_in_treatment/000001.rb
var/cortex/entities/.history/Gene/activity_in_treatment/000001.json
```

The `.rb` file contains only the body of the property task block. It does not
contain `module`, `extend Entity`, `property`, `task`, or `dep` declarations.
Cortex generates that envelope from the sidecar metadata.

The metadata is the executable interface, for example:

```json
{
  "schema": 1,
  "entity_type": "Gene",
  "property": "activity_in_treatment",
  "description": "Return activity calls for one gene and treatment",
  "property_type": "single",
  "result_type": "json",
  "arguments": [
    {
      "name": "treatment",
      "type": "string",
      "description": "Treatment identifier",
      "required": true
    }
  ],
  "dependencies": ["raw_activity"],
  "version": 3,
  "digest": "...",
  "active": true,
  "versions": [
    {
      "version": 3,
      "digest": "...",
      "action": "update",
      "job": "Cortex/cortex_property_update/...",
      "agent": "Worker",
      "timestamp": "..."
    }
  ]
}
```

Body example:

```ruby
raw = step(:raw_activity).load
record = raw[entity.to_s]
{
  entity: entity.to_s,
  treatment: inputs[:treatment],
  value: record && record['value'],
  source_property_job: step(:raw_activity).short_path
}
```

Bodies use a deliberately small documented contract:

- `entity` for `single` properties;
- `entity_list` for `array` properties;
- `inputs[:name]` for declared property arguments;
- `step(:dependency)` for declared property dependencies;
- normal Ruby/Scout APIs for data access and composition.

They should return structured Ruby values, not prose.

## Entity type resolution and namespace safety

Cortex maintains a registry by logical entity type name.

Resolution order:

1. Resolve an existing constant without evaluating agent-supplied constant
   expressions. If it is an Entity module, reuse it.
2. If a constant exists but is not an Entity module, fail; never mutate an
   unrelated constant.
3. Otherwise create a module under `Cortex::ManagedEntities`, extend it with
   `EntityWorkflow`, and register it under the logical name.

Existing Entity modules may be extended with `EntityWorkflow` only after an
explicit compatibility check. Cortex must not redefine their identifier
formats, annotations, existing properties, or methods. A Cortex property name
that already exists and is not Cortex-owned is a collision and definition must
fail.

Names are validated independently of generic resource paths:

- entity type: Ruby constant segments (`Gene`, `Project::Treatment`), no
  arbitrary expression;
- property, argument, and dependency: lower-case Ruby method/input identifier;
- reserved names include framework helpers and generated suffixes such as
  `job`, `entity`, `entity_list`, `inputs`, and names ending `_job`.

## Loading and compilation

`Cortex.load_entity_type(type)` performs lazy, type-wide loading:

1. resolve the entity module;
2. read every active definition under `entities/<type>/` across readable path
   maps;
3. reject cross-map ambiguity for executable definitions (unlike ordinary
   content reads, executable ambiguity must not silently choose one);
4. validate metadata and build the dependency graph;
5. reject missing dependencies and cycles;
6. compile definitions in topological order;
7. memoize the loaded manifest digest for the process.

On a later request, if the type manifest digest has changed, Cortex recompiles
changed definitions and removes Cortex-owned methods/tasks for removed
properties. Existing non-Cortex methods are never removed.

Compilation is deterministic. For each property Cortex generates equivalent
DSL declarations:

```ruby
input :treatment, :string, 'Treatment identifier', nil, required: true
input :_cortex_definition, :string, '...', 'Gene/activity_in_treatment'
input :_cortex_definition_version, :integer, '...', 3
input :_cortex_definition_digest, :string, '...', '<digest>'
dep :raw_activity
property_task({activity_in_treatment: :json}, :single) do
  # exact body from the .rb definition
end
```

The actual compiler should not concatenate unescaped names. It validates names,
generates the fixed envelope, and uses the definition file path and line offset
in `module_eval` so syntax/runtime backtraces cite the cortical definition.

Property bodies are trusted executable Ruby. Owning the envelope reduces
accidental namespace damage but is not a Ruby security sandbox. Documentation
and tool descriptions must state this directly.

## Dependency model

Version 1 supports same-entity property dependencies by name:

```json
"dependencies": ["raw_activity", "timepoints"]
```

All declared property arguments with matching names are forwarded by normal
Workflow recursive-input rules. The body consumes dependency results through
`step(:raw_activity)`.

This limited model is intentional. It creates real Step dependencies and
therefore real invalidation. A body calling another property directly is legal
Ruby but is not accepted as a substitute for declaration when provenance
matters.

A later schema can add explicit cross-entity dependencies with entity and input
mapping. That should not be improvised as free-form Ruby in metadata; it needs a
small declarative mapping language and tests for dependency identity.

## Definition lifecycle

### Create

`cortex_property_define`:

- fails if active property exists;
- validates all names, argument types, dependencies, and result/property types;
- compiles in a staging module;
- optionally runs a supplied test entity and arguments;
- commits body and metadata atomically only after validation;
- records version 1 and producing job/agent.

### Update

`cortex_property_update`:

- fails if property does not exist;
- requires `expected_version` (optimistic concurrency) so one agent cannot
  silently overwrite another agent's update;
- treats omitted fields as unchanged;
- validates a complete candidate in staging;
- snapshots the previous body and metadata to `.history`;
- atomically activates the new version;
- returns a compact confirmation with address, version, and digest.

### Remove

`cortex_property_remove` is a scientific-method removal, not an evidence purge:

- requires `expected_version`;
- snapshots the active version;
- removes the active body from resolution;
- writes an inactive/tombstone metadata record with provenance;
- prevents future execution through the Cortex API;
- preserves history so old property jobs remain auditable.

Permanent purge should be an administrator operation, not an agent tool.

### Read/list

- `cortex_property_list`: metadata only, filter by entity type/prefix, paginated.
- `cortex_property_read`: bounded body read plus interface metadata and current
  version/digest; does not execute code.
- `cortex_property_history`: compact version/action/provenance listing.

Definitions should also be discoverable through an extended `cortex_list`
`type=entities`, but explicit property tools remain clearer to models than
forcing compound executable resources through generic artifact operations.
Generic `cortex_write` must never write entity definitions.

## Execution API

Keep a single canonical execution task:

`cortex_entity_property`

Inputs:

- `entity_type` (required string);
- `property` (required string);
- `entity` (string or JSON array according to property type);
- `entity_options` (optional JSON annotation options);
- `arguments` (JSON object, never positional);
- `update` (boolean, clean/recompute the selected property job; default false).

Execution:

1. lazily load the entity type and all active definitions;
2. validate the property and arguments against metadata;
3. annotate the scalar/list with the resolved Entity module;
4. obtain `<property>_job` with keyword/options forwarding;
5. make that Step a dynamic dependency of `cortex_entity_property` if the
   Workflow dependency API permits it; otherwise run it and return its exact
   path explicitly until dynamic dependency wiring is implemented;
6. return a compact structured receipt:

```json
{
  "entity_type": "Gene",
  "entity": "TP53",
  "property": "activity_in_treatment",
  "arguments": {"treatment": "PD_PI"},
  "definition_version": 3,
  "definition_digest": "...",
  "property_job": "Gene/activity_in_treatment/TP53_...json",
  "result": {"value": 1.72, "status": "up"}
}
```

The property job, not the outer Cortex tool job, is the primary evidence
producer. The outer job should depend on it so normal Step provenance traversal
finds it. `update=true` cleans the selected property job (optionally recursively
through a separate explicit input); it does not create a second cache identity
as the demonstrator's `update_property` input currently does.

For direct Ruby use the normal API remains available:

```ruby
gene = Cortex.load_entity_type('Gene').setup('TP53')
gene.activity_in_treatment(treatment: 'PD_PI')
gene.activity_in_treatment_job(treatment: 'PD_PI')
```

## Validation

Validation has three levels:

1. **Schema**: names, types, required/default consistency, unknown metadata,
   dependency graph.
2. **Compile**: generate the complete envelope and compile/evaluate it in a
   fresh staging module. Failure never changes the active definition.
3. **Smoke execution** (optional at definition, mandatory before scientific
   use): concrete entity plus arguments, structured result, resulting Step
   path, and warnings.

A separate `cortex_property_validate` task should support validating a candidate
without activating it and validating the active definition with a smoke test.

All foreseeable failures use `ParameterException`/`ScoutException`: malformed
names, missing dependencies, cycles, collisions, stale expected version,
argument mismatch, and absent properties.

## Integration with the existing workspace

Add `entities` to discovery/search/read concepts, but do not blindly add it to
all generic management code:

- entity properties have a compound address (`EntityType/property`);
- their body and metadata must be updated atomically;
- removal preserves a tombstone/history;
- generic artifact edit/append semantics are unsafe for executable methods.

The storage layer should first extract a reusable `VersionedResource` helper
from artifact versioning. Artifacts and entity definitions can share path-map,
history, metadata, atomic-write, rename/move primitives while keeping different
lifecycle policies.

Suggested exported tools:

- `cortex_property_list`
- `cortex_property_read`
- `cortex_property_history`
- `cortex_property_validate`
- `cortex_property_define`
- `cortex_property_update`
- `cortex_property_remove`
- `cortex_entity_property`

The old unexported `entity_property` can become a compatibility alias after its
return contract is reviewed. The demonstrator `update_entity_module` and test
properties should be deleted rather than evolved.

## Testing plan

### Entity semantics

Test scalar and list receivers for `single`, `array`, and `both`; test job and
value properties; test positional/keyword argument forwarding; test entity
annotations/options; test structured result types.

### Definition lifecycle

Create, duplicate-create failure, update with matching/stale version, failed
candidate leaves active version intact, remove/tombstone, recreate policy,
history and metadata provenance, path-map ambiguity.

### Dependency/cache behavior

A depends on B; execute A; update B; verify B gets a new property job path and A
gets a new dependency/job path without manual retraction. Verify `update`
cleans the selected job rather than changing its identity. Test cycle and
missing-dependency rejection.

### Namespace compatibility

Existing Entity module reuse, new managed module creation, unrelated constant
collision, existing non-Cortex property collision, two entity types with the
same property name, removal does not remove framework methods.

### End to end

Define `Gene/raw_activity`, define dependent `Gene/activity_call`, validate on
TP53, execute through the exported tool, inspect the outer Step dependency and
returned property job receipt, update raw activity, and verify downstream
invalidation.

## Implementation order

1. Add focused scout-gear regression tests for `EntityWorkflow#property_task`
   argument forwarding and correct the method upstream if desired.
2. Extract Cortex versioned-resource primitives and add the `entities`
   namespace/path-map rules.
3. Implement definition schema, validation, history, and create/update/remove.
4. Implement registry, resolution, lazy type-wide loader, compiler, collision
   checks, and hot-reload ownership tracking.
5. Implement execution with a real dynamic dependency on the generated
   property Step.
6. Add exported discovery/read/validate tools and model-facing documentation.
7. Add dependency/invalidation and end-to-end tests.

## Decisions recommended before coding

1. New entity types should live under `Cortex::ManagedEntities`, not be injected
   as top-level constants.
2. Initial dependencies should be same-entity/static only.
3. Removal should tombstone and preserve history, not purge scientific method
   history.
4. Initial advertised property types should be `single`, `array`, and `both`;
   enable `multiple` only after its cache semantics are tested.
5. Property task argument forwarding should be fixed in scout-gear, with a
   Cortex compatibility wrapper for older releases.
