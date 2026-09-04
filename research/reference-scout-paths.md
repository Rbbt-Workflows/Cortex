# Research note — Scout path maps, resource sync, and the :lib question

Answers gathered for the workspace-management pass (step 1 of the plan).
All facts verified live in this sandbox (ruby snippets under `tmp/`), against
the scout-essentials/scout-gear sources in `~/git/`.

## 1. How `Path#find(map)` resolves `Scout.var.cortex`

`Scout.var.cortex` is the annotated Path `var/cortex` with
`libdir = <repo root>` (the workflow checkout; this repo has no `lib/` dir of
its own, so `Path.caller_lib_dir` climbs to the repo root).

Relevant path maps (scout-essentials `lib/scout/path/find.rb`):

```
:current => "{PWD}/{TOPLEVEL}/{SUBPATH}"
:lib     => "{LIBDIR}/{TOPLEVEL}/{SUBPATH}"
```

Live resolution from the repo root (`{PWD} == {LIBDIR}` there):

```
var/cortex.find(:current) -> /bulk/mvazque2/git/workflows/Cortex/var/cortex
var/cortex.find(:lib)     -> /bulk/mvazque2/git/workflows/Cortex/var/cortex
```

**Consequence:** for `var/cortex`, `:lib` and `:current` resolve to the same
physical directory *when invoked from the repo root*. `Path#follow` does not
care whether the target exists; it is a pure template expansion. `find(:lib)`
on a missing path still returns `<repo>/var/cortex/...`, so writes through
`:lib` land in the same place today.

Also relevant: this checkout is bind-mounted into
`~/.scout/workflows/Cortex` and `~/.rbbt/workflows/Cortex` (same inode), so
`Scout.var.cortex` is shared across invocations regardless of which install
path resolves. `Path.path_maps` can be extended with
`Path.add_path(name, map)` / `Path.prepend_path` / `Path.append_path` if we
want a dedicated Cortex map later; not needed now.

## 2. `Resource.sync` semantics (model for `cortex_move`)

`Resource.sync(path, map, options)` (scout-essentials
`lib/scout/resource/sync.rb`):

1. `target = resource.identify(path).find(map)` — resolve the *same logical
   resource* through another map.
2. Collect `real_paths`: the source file itself if it exists on disk, else
   `find_all` (dirs) or `glob_all`.
3. `Open.sync(source, target, options)` each of them — under the hood
   `Open.rsync` (`rsync -avztHP --copy-unsafe-links --omit-dir-times`,
   default excludes `.save .crap .source tmp filecache open-remote`; extra
   args via `:other`; `delete: true` appends `&& rm -Rf <source>`).

So the Scout-native notion of "move between path maps" is: resolve the target
map, rsync content there, optionally delete the source. It copies *content*;
it knows nothing about sibling `.meta/`/`.history/` stores — Cortex must
extend it by including those directories in the sync set.

## 3. Where Scout's own tests live (test-harness choice)

scout-gear/scout-essentials use `test/unit` with a `test/test_helper.rb`
(`$LOAD_PATH` fix-ups + `require 'test/unit'`). This repo already has a
`test/test_helper.rb` stub in that style. Decision: keep `test/unit`
(`rake`-less; runnable with `ruby -Ilib -Itest test/cortex_workspace_test.rb`),
no new dependency. The suite must isolate the workspace by pointing
`Cortex` at a tmp dir (see design note) and clean up after itself.

## 4. Alias mechanism (canonical names + compatibility)

`task_alias(name, workflow, oname, *rest, &block)` in scout-gear
`lib/scout/workflow/definition.rb` is the supported aliasing primitive:
it declares a `dep` on the original task and re-exposes its result
(`extension :dep_task`, same type/returns). Caveats found:

- Annotations (`input`, `desc`, ...) attach to the **next** task definition,
  and `task_alias` consumes them too — so an alias cannot add its own inputs
  this way without them being swallowed. Fine for us: the alias forwards the
  *same* inputs (they come from the dependency tree via recursive inputs).
- `task_alias` produces a *job* that links the dep result; it does not call a
  block. If we want an alias that literally returns the dep's JSON output,
  `task_alias` is enough.

Decision (original): implement `cortex_continue`/`cortex_brief` as real
tasks (renamed bodies of the old names) and keep the old names as
`task_alias` shims. (Verified: `task_alias` returns the dep's persisted
result when not `:forget`.)

Later outcome: the `task_alias` shims were removed altogether during the
workspace-hygiene pass; only the canonical `cortex_*` names exist today.
The mechanics above are kept as reference for future alias work.

## 5. `:lib` as default write map — reality check

Spec says `CORTEX_WRITE_MAP = :lib`. Two findings:

- For `var/...` resources `:lib` and `:current` are the same directory from
  the repo root, so switching the write map to `:lib` is a no-op physically
  *here*. It still matters: (a) when Cortex is invoked with a different PWD
  (e.g. from `~/.scout/workflows` symlinks or from another checkout),
  `:lib` stays anchored to the workflow's own libdir while `:current` follows
  the caller's PWD; (b) it makes the intent explicit and future-proof if a
  dedicated `:lib` location (e.g. `lib/cortex/` shipped with the repo, or an
  added path map) is introduced.
- Reads must keep finding existing data: all current data lives under the
  repo's `var/cortex` (which is both `:current` and `:lib` today), so
  `CORTEX_READ_MAPS = [:lib, :current]` with `:lib` first loses nothing.

Decision: adopt `CORTEX_WRITE_MAP = :lib`, `CORTEX_READ_MAPS = [:lib,
:current]` as constants at the top of the module, overridable via Scout
config keys `cortex.write_map` / `cortex.read_maps` (cheap, no new
machinery), and document that today both resolve to the same place from the
repo root.
