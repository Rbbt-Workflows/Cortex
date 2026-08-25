# Probe findings: EntityWorkflow property_task runtime behavior (2026-08-25)

Probes: `tmp/probe_prop_task.rb`, `tmp/probe_run2.rb`, `tmp/probe_run3.rb`
(installed scout-gear 10.12.2, ruby 3.3.1). Environment limited job *execution*
(read-only `~/.scout` inside bwrap), but job-path computation and compilation
behavior were verified.

## Verified facts

1. **`<property>_job` forwards kwargs correctly.**
   `g.probe_activity_job(treatment: 'PD_PI')` and `g.probe_activity_job()`
   produce DIFFERENT job paths. The `_job` property body is
   `job(task_name, *args)` and args reach the workflow job.

2. **The PUBLIC property wrapper drops arguments (upstream bug).**
   `property property_name => property_type do |*args| job = self.send(property_job_name) ...`
   — `*args` are accepted but NOT forwarded to `<property>_job`. Calling
   `g.probe_activity(treatment: 'PD_PI')` silently builds the job with default
   inputs instead. Consequence for Cortex: the executor must call
   `<property>_job(**arguments)` itself, or install a forwarding wrapper; the
   generated public property cannot be trusted with arguments on scout-gear
   10.12.2.

3. **Anonymous `Module.new` + `extend EntityWorkflow` + `name = 'X'` works.**
   Job path uses the assigned name: `var/jobs/ProbeAnon/tok/...`. So
   `Cortex::ManagedEntities` modules created at runtime register cleanly.
   Nested real constants also work (`ProbeNest::Managed` → path contains
   `ProbeNest::Managed`); prefer anonymous modules with assigned short names
   to keep paths clean.

4. **All inputs, including defaulted ones, participate in job identity.**
   Explicit `treatment: 'PD_PI'` vs omitted default produce different job
   paths, and `task_info[:inputs]` lists both the declared inputs and the
   entity-name input (`[:treatment, :probe_gene]`). This means hidden
   definition-identity inputs (`_cortex_definition`, `_cortex_definition_version`,
   `_cortex_definition_digest`) will change job identity if the executor ALWAYS
   passes them explicitly. Do not rely on changing their default values;
   always pass explicitly from the Cortex executor.

5. **`property_task` annotation mechanics.** Every call re-declares all
   `annotation_input`s plus an entity-name input before `task(...)`. Dynamic
   (re)definition of multiple properties on one module therefore accumulates
   inputs per task correctly, but the module accumulates annotations; keep
   annotations empty for managed entities unless needed.

6. **Executing Steps inside this sandbox fails** (`Errno::EROFS` on
   `~/.scout/tmp` locks and `~/.scout/var/jobs`). Attempts to redirect via
   `Scout::Config.set({directory: ...})`, `ENV['SCOUT_VAR']`, `ENV['SCOUT_TMP']`
   after require failed: `Scout.var` paths were already finalized. Tests that
   need `Step#run` must be executed OUTSIDE the bwrap exec tasks (e.g. via
   `scout workflow task` / the normal test runner on the host), or the var/tmp
   redirect must be applied before `require 'scout'` finalizes paths (untested).
   Job-path computation and compile-time validation work fine in-sandbox.

## Suggested upstream fix (scout-gear, property_task)

```ruby
property property_name => property_type do |*args, **kwargs|
  job = self.send(property_job_name, *args, **kwargs)
  ...unchanged...
end
```

plus forwarding `*args` of `property_task` itself or documenting it unused.
Stage as a patch file under `research/` (scout-gear source is read-only here).
