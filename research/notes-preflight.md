# Preflight probe notes: task redefinition, envelopes, deps, wrappers

Date: 2026-08-25. Host runs with `BWRAP=false ruby` (see plan guidance).
Probes live in `tmp/probe_*.rb`. Installed scout-gear: 10.12.2.

## P1. Redefining a same-named Workflow task does NOT replace it in `mod.tasks`

`Workflow#task` builds a `Task` object and assigns `@tasks[name] = task`
every time, but:

- `Workflow#job` does `tasks[name]` then `task.job(*args)`, and `Task#job`
  memoizes the Step through `Persist.memory("Task job #{name}", repo:
  Workflow.job_cache, other: {workflow:, task: name, id:, provided_inputs:})`.
- `Workflow.job_cache` is a process-level Hash: `@job_cache ||= {}`.

Observed (`probe_task_redefine{,2,4,5,7,8}.rb`):

- Redefine `foo` with body `v2` after a `v1` job exists: new Step object is
  returned but `.task` refers to the ORIGINAL Task object (same object_id as
  the v1 Task; the v1 body runs). "block body check" shows the hash slot
  changed but jobs still execute v1.
- `job1.equal?(job3)` false for a fresh `mod.job(:foo)` after the cache was
  tampered with, yet the Step still ran v1, because the Step is constructed
  with `&self` (the Task object captured earlier by `Persist.memory`).
- Even `Workflow.job_cache.clear` + full `Persist` reset did not change the
  executed body (`probe_task_redefine9.rb`): the memoized Step holds the old
  Task's block.

Conclusion: **within one process, a redefined task is not effective while an
older Step for the same (name, id, inputs) is alive in the memory cache.**
Cleanest reliable strategy: new job paths via distinct identity inputs
(hidden `_cortex_definition*` inputs) instead of same-name reload. Within a
long-lived process, definitions are immutable once compiled; the *workspace*
supports versions, and the *compiler* prefers loading the active version at
first request. A subsequent request after definition update recompiles the
property into a FRESH module generation (see P6), never redefining the same
task in place.

## P2. property_task envelope facts (10.12.2)

- `entity_task` = `property_task(name, :single)`; `list_task` = `:array`.
- Inputs: `:single`/`:single2array` declare `input entity_name, :string, ...,
  jobname: true`; `:both` declares entity input (jobname) + `:list` array;
  `:array`/`:array2single`/`:multiple` declare only `:list` array.
- Task name: `property_task({name => result_type}, property_type, &block)`.
- Generated methods: `<property>_job` (returns the job, does not run) and
  `<property>` (runs + loads). Both are `property ... => property_type`.
- The public `<property>` does NOT forward its `*args` to
  `<property>_job` (`job = self.send(property_job_name)`), and
  `property_task`'s own `*args` parameter is unused. Confirmed upstream bug
  (already documented in research/probe-property-task-findings.md).
- `mod.job(:task, ...)` works; annotation inputs are declared from
  `mod.annotations` (we set none), so job inputs are exactly:
  declared inputs + entity_name input + hidden identity inputs.
- `mod.name = 'Gene2'` gives clean paths `var/jobs/Gene2/<task>/<entity>`
  (no anonymous-module naming artifacts) as long as `entity_name` is set
  (`mod.entity_name = 'gene'`).
- `:both` on a scalar uses `entity` (entity_list nil); on a list `entity_list`
  is the list and `entity` is "Default" (the `:list` input default). Use
  `Array === entity_list` to branch, not `entity`.

## P3. Our forwarding wrapper works

Defining `<property>` ourselves via `define_method` that calls
`<property>_job(*args, **kwargs)` then runs/loads:

- scalar `g.probe_it(treatment: 'PD')` returns the body value;
- after changing identity inputs, the same call gets a NEW job path and
  recomputes (paths differ: true);
- a list receiver for a `:single` property needs `make_array` semantics (the
  framework maps per member); our wrapper on the scalar path works, and for
  lists we fall back to `collect`.

For `:array` properties the framework public method maps a scalar receiver
into a one-element list and selects `res[self] || res[0]`; our wrapper
mirrors that and works for both scalar and list receivers
(`probe_array_wrapper.rb`: "TP53" / "A,B").

## P4. Dependencies must be declared with an explicit dep block

`dep :raw_activity` inside the same module does NOT create an edge unless a
`dep` block computes the job (a bare `step(:raw_activity)` is nil and
`.load` raises NoMethodError). Working pattern:

    mod.dep(:raw_activity) do |jobname, options|
      mod.job(:raw_activity, options[mod.entity_name] || options[:gene], options)
    end

This yields a real dependency Step (`deps: ["Gene9/raw_activity/Tp53_..."]`)
and the body can do `step(:raw_activity).load`. Forwarding `options` also
propagates hidden identity inputs to the dependency, so updating the
dependency definition produces new paths on BOTH the dependency and the
dependent, with no explicit re-wiring (`probe_dep_propagation2.rb`:
paths differ: true; j2 recomputed "Tp53@raw2@combined").

This matches the design: hidden `_cortex_definition*` inputs are how cache
identity changes on update; the dep block must forward all options.

## P5. Entity instance helpers

`mod.setup('Tp53')` yields a String extended with the module (via Entity
setup). `make_array` exists for building lists. `AnnotatedArray` /
`is_contained?` exist for list members (scout-annotation). For our wrappers
we only need Array checks and `make_array` on the scalar path.

## P6. Hot reload strategy

Because of P1, hot reload = build a fresh generation module on manifest
change and re-point the registry. We create a new anonymous module with
`name = <Type>` and `entity_name` set, then compile ALL active properties
into it, and memoize keyed by manifest digest. Old generations keep working
for already-created Steps; new requests go through the new module. Entity
instances annotated with the old module still work (their singleton methods
point at old tasks) but new `mod.setup` uses the new generation.

## Decisions locked in from probes

1. Envelope compiles into a fresh module generation per manifest digest;
   same-name task redefinition inside a live process is unreliable (P1, P6).
2. The public property method is OUR wrapper (forwarding args), installed
   after `property_task`; `<property>_job` remains the canonical job entry.
3. Dependencies use explicit `dep` blocks forwarding all options (P4).
4. Hidden identity inputs `_cortex_definition`, `_cortex_definition_version`,
   `_cortex_definition_digest` are declared on every property task (and thus
   participate in cache identity and propagate to deps).
5. `:both` bodies branch on `Array === entity_list`.
6. `:array` scalar path uses `make_array` + member selection.
7. New entity types get `name = <Type>` and `entity_name = underscore(Type)`
   so job paths are clean (`var/jobs/<Type>/<task>/<entity>`).
