# The `scout cortex` command-line suite

Design note for the subcommand suite under `share/scout_commands/cortex/`,
implemented with one shared helper at `lib/Cortex/cli.rb`.

Related material:

- `tmp/cli-framework-findings.md` — verified framework facts (SOPT mechanics,
  discovery maps, `Step#exec`), with file:line evidence.
- `tmp/cortex-task-inventory.md` — authoritative inventory of all 22 Cortex
  tasks and their inputs; table (b) is the positional mapping source.

## The old generic script and what it got right

Until this step, `share/scout_commands/cortex` was a single generic script:
it registered a fixed handful of options (`-t type`, `-n name`, `-e entity`,
`-et entity_type`, `-p property`), took the first remaining positional as
`command`, defaulted `type` to `artifacts`, forced the first positional's
neighbor into `name`, and ran:

    Workflow.require_workflow 'Cortex'
    job = Cortex.job("cortex_#{command}".to_sym, nil, options)
    puts job.exec

Three things in it were right and are kept verbatim in the new helper:

1. **Thin execution**: `Cortex.job(task, nil, options)` + `puts job.exec`.
   All tasks are `export_exec`, so `Step#exec` returns the result text
   directly — the same path `scout workflow task ... --exec` uses.
2. **Positional -> input mapping**: SOPT consumes options destructively, so
   whatever is left in `ARGV` is positional; assigning those to task inputs
   is the right ergonomics for a CLI.
3. **Task defaults come from the task definition**: the script passed the
   options hash straight to `Cortex.job`, and `Task#assign_inputs` fills
   declared defaults (verified: `cortex_list` runs with `type=all` when the
   option is absent). No CLI-level default table is needed.

What it got wrong (all fixed by the replacement):

- **Typos**: usage said "Run a Cortext command" (Cortex); `-e` and `-et`
  were both documented "Entity" (`-et` is the entity *type*); and
  `help = IndiferentHash.process_options options, :help` was a dead line —
  its result was never used (`options[:help]` was read directly).
- **Blanket `options[:type] ||= 'artifacts'`**: wrong for almost every task.
  `cortex_list`/`cortex_search` default to `all`; `cortex_read` *requires*
  an explicit type. The new code never invents defaults.
- **First positional always `name`**: only right for 5 of 21 tasks (inventory
  table (b)).
- **Six hardcoded options for 22 tasks**: inputs like `--query`, `--limit`,
  `--content`, `--body` were unreachable.

## Why a file became a directory

The scout dispatcher (`bin/scout`) walks `$scout_command_dir` (`Scout.scout_commands`,
a `Path` over the `scout_commands` path maps). For each token it first checks
`File.directory?(dir[$command].find)`: a directory *nests* (the token becomes
a subcommand prefix), otherwise the token must be a file that is `load`ed.
A path cannot be both a loadable command file and a parent of subcommands, so
replacing the single-file `cortex` with `cortex/<subcommand>` scripts is the
only way to get `scout cortex list`, `scout cortex read`, ... while keeping
the generic behavior reachable as `scout cortex task ...` (decision 1).

## Discovery maps and the install symlink

Verified live (see `tmp/cli-framework-findings.md`): command discovery maps
are `<repo>/scout_commands/` (the `:current` map, only when it exists) and
`~/.scout/scout_commands/` (the `:user` map). `share/scout_commands/` is NOT
a discovery location — a checkout's `share/` tree is only reachable through
`scout workflow cmd <Workflow> ...` (which looks at `wf.libdir.share.scout_commands`).
The canonical files therefore live in `share/scout_commands/cortex/` (repo
layout constraint), and live use requires the user-level symlink:

    mkdir -p ~/.scout/scout_commands
    ln -sfn <repo>/share/scout_commands/cortex ~/.scout/scout_commands/cortex

`Path#find` and `Dir.glob` both follow the symlink, `File.directory?` sees a
directory, and `load` executes the scripts with `__FILE__` inside the
symlinked path — from which `require_relative` still resolves, because
`require_relative` (like `__dir__`) canonicalizes through the symlink to the
real checkout (verified: `__dir__` of a script reached through a symlinked
directory returns the real path).

Install state found during this step: `~/.scout/scout_commands/` did not
exist at all (nothing installed, no stale symlink to replace). The symlink
was created fresh.

Sandbox note: writes outside the ComputerUse bwrap mounts do not persist
between tool calls in this environment (observed: files created under
`~/.scout/scout_commands/` in one call were gone in the next), so the pilot
below installs the symlink and runs every check inside a single bash call
(`tmp/run-pilot.sh` is the re-runnable harness and its output is
`tmp/pilot-verification.log`). The symlink may need to be recreated outside
the sandbox for durable use; the two lines above are the complete install.

## Decisions

1. **Subdirectory layout, generic passthrough survives as `cortex/task`.**
   First positional = task name (with or without the `cortex_` prefix),
   remaining args/options forwarded — mirroring `scout workflow task Cortex
   <task> --exec`. The internal `continue` task gets no dedicated script
   (per inventory note) but remains reachable through `task`, for parity
   with the reference command. `scout cortex task <t> --help` delegates to
   `<t>`'s help (`scout cortex task search --help` prints the search help).
2. **Thin scripts derive the task from their own basename**
   (`cortex/list` -> `cortex_list`); `task` is the only special case. Each
   script is a shebang, `frozen_string_literal`, one `require_relative` and
   one `dispatch` call.
3. **Help is synthesized from the live task definitions** via
   `SOPT.input_array_doc`-style formatting of `task.recursive_inputs`
   (name, type, description, default, select options, required flag). No
   `desc` blocks are added to the workflow in this step and no
   `doc/user/*.md` is parsed. If a task ever gains a `description`, the
   helper prepends it to `## DESCRIPTION` — the task definition stays the
   single source of truth. The framework's `## SYNOPSYS` misspelling is
   kept deliberately (do not fix).
4. **Stable shorts for common inputs**: `-t` type, `-n` name, `-e` entity,
   `-et` entity_type, `-p` property, `-q` query. Everything else is
   auto-assigned by `SOPT.fix_shortcut(name[0], name)`, which silently
   lengthens on collision (`lines` -> `-li` when `last` holds `-l`).
   Reserved shorts are registered first so they always win.
5. **Type handling**:
   - boolean inputs are flags (`--reply`, `--reply=false`);
   - integer inputs are NOT pre-cast — the string reaches the task and
     `Task.format_input` does `to_i` (verified);
   - hash/JSON `:text` inputs (`arguments`, `test_arguments`,
     `entity_options`) are passed as strings and parsed by the task;
   - `:array` inputs are comma-split unless the value is an existing file —
     the exact rule of `Task#get_SOPT` — EXCEPT arrays documented as JSON
     (`tools`, see `JSON_ARRAY_INPUTS`): those are taken as one string and
     `JSON.parse`d by the helper before being passed, so a JSON payload is
     never comma-split.
6. **Execution**: `Cortex.job(task, nil, options)` then `puts job.exec`.
7. **Install**: canonical files in `share/scout_commands/cortex/`; symlink
   at `~/.scout/scout_commands/cortex` for live discovery (see above).

## How options and help are derived

`Cortex::CLI` (lib/Cortex/cli.rb) does, per subcommand:

1. Load the workflow from the helper's own real path. `Workflow.require_workflow
   'Cortex'` cannot be used: from any PWD other than a checkout it attempts a
   GitHub autoinstall of `Scout-Workflows/cortex.git`, which does not exist.
2. Deduplicate `task.recursive_inputs` by name keeping the first occurrence
   (`cortex_brief` declares `agent` twice: its own required `agent` and the
   `agent` inherited through `export_scaffold`; `NamedArray#uniq` dedups whole
   tuples, not names).
3. Register options with `SOPT.register(short, name, type != :boolean,
   description)`. The third argument is a *takes-a-value* flag, not a type:
   truthy registers `:string` (value-taking), falsy `:boolean` (flag). The
   declared type (integer/select/...) is used for *display* only.
4. `SOPT.consume(ARGV)` removes recognized options in place; leftovers are
   the positionals, mapped per inventory table (b) into inputs that were not
   given explicitly. Extra positionals are an error.
5. Array coercion (decision 5), required-input check, then job + `exec`.

Help text is assembled manually in the shape of `SOPT.doc` (header,
`## SYNOPSYS` with the positional order spelled out, `## DESCRIPTION`,
`## OPTIONS` rendered through `SOPT.input_format` +
`Misc.format_definition_list_item`, with `(required)` and
`one of: ...` appended from the input declaration, plus a
`## SELECT OPTIONS` section) rather than by calling `SOPT.doc` itself:
`SOPT.doc` re-renders from `input_types`, which must hold
`:string` for consumption, and would display every non-boolean input as
`=<string>`.

SOPT footguns encoded in the helper (each marked with a `ScoutCoder:`
comment in the code):

- `SOPT.input_array_doc` registers booleans as `:string` (it passes the type
  as `SOPT.register`'s asterisk argument), so it cannot be used both to
  render and to prepare consumption; rendering and registration are done
  separately.
- `SOPT.reset` clears only `@shortcuts`/`@all`; the input tables
  (`inputs`, `input_types`, ...) survive it, so a full reset needs the
  `attr_writer`s — otherwise options registered by the parent `scout`
  process (`--log`, ...) leak into every subcommand.
- `scout cortex task <t>` needs two `SOPT.consume` passes (one with only
  `--help` registered to learn the task name, one with the task's real
  inputs); this works because consume only removes *recognized* tokens.
- `SOPT.consume` only ever takes the *next* token as a value for a
  value-taking option (`--opt value` or `--opt=value`), so positionals
  mixed between options are fine, but `--opt -x` does not mean "value -x".

## Step-4 notes (generating the remaining ~18 scripts)

- The three pilot scripts are the template; generation is copying them and
  adjusting the leading comment. Everything else (options, shortcuts, help,
  positionals, types) comes from `POSITIONALS`/`SUMMARIES` and the live task
  definitions — nothing per-task lives in the scripts.
- Add a `SUMMARIES` entry (one line) per new subcommand; fallback is
  "Run the Cortex task <name>", so an entry is cosmetic, not functional.
- Do not create a `continue` script (internal task; excluded by design).
- Every script must be executable (`chmod 755`); `require_relative
  '../../../lib/Cortex/cli'` (three levels up, not two: the scripts sit in
  `share/scout_commands/cortex/`) works both through the install symlink and
  from the checkout itself.
- The unknown-subcommand path (`scout cortex nope`) is the *dispatcher's*
  error (`Command 'cortex' not understood`), not the helper's; nothing to
  fix there.
- Re-run the pilot checks after generation; the symlink does not need to be
  recreated for new files (it points at the directory).

## Final subcommand inventory (step 4, 2026-09-07)

21 user-facing scripts plus the generic `task`; no `continue` script (the
internal `continue` task is reachable only through `scout cortex task
cortex_continue`-style passthrough, as designed). Script basename is the
task name minus the `cortex_` prefix; nothing task-specific lives in the
scripts beyond the leading comment.

| script | task | natural positionals (in order) | description |
|---|---|---|---|
| activity | cortex_activity | entity_type, entity | Report accumulated workspace activity around ONE entity |
| brief | cortex_brief | conversation, prompt | Create or refresh a reusable agent brief (prompt plus optional tooling) |
| continue | cortex_continue | conversation, prompt | Append a turn to a named conversation, optionally through a briefed agent |
| edit | cortex_edit | name, find, replace | Make a targeted, exact text edit to an existing artifact |
| entity_property | cortex_entity_property | entity_type, property, entity-or-list | Run a property for one entity or a named list, with a job receipt |
| list | cortex_list | type, prefix | List workspace namespaces with metadata only |
| move | cortex_move | name, to | Move a workspace resource between path maps |
| property_define | cortex_property_define | entity_type, property | Define (create) a new executable entity property |
| property_history | cortex_property_history | entity_type, property | Show the version history of a property definition |
| property_list | cortex_property_list | entity_type, prefix | List entity property definitions |
| property_read | cortex_property_read | entity_type, property | Read a property definition body |
| property_remove | cortex_property_remove | entity_type, property | Remove a property definition (history is kept) |
| property_update | cortex_property_update | entity_type, property | Update an existing property definition |
| property_validate | cortex_property_validate | entity_type, property | Validate a candidate property definition (with optional smoke run) |
| read | cortex_read | name, type | Read conversations, briefs, or artifacts |
| read_list | cortex_read_list | entity_type, list | Read the entity ids (and optional meta) of a named entity list |
| remove | cortex_remove | name, type | Remove a workspace resource (irreversible) |
| rename | cortex_rename | name, new_name | Rename a workspace resource in place |
| search | cortex_search | query, type | Lexically search conversation, brief, and artifact contents |
| task | (any) | task-name first, then the target task's positionals | Generic passthrough mirroring `scout workflow task Cortex <task>` |
| write | cortex_write | path, content | Write or append a durable artifact |
| write_list | cortex_write_list | entity_type, list, entities | Write or replace a named entity list |

Note on `continue`: the inventory's "no continue script" caveat was about
the *internal* `continue` chat task (excluded). `cortex_continue` — the
user-facing conversation task — does get a script, as in the table above.

Install note (unchanged from step 3, now covering all 22 scripts): the
canonical files live in `share/scout_commands/cortex/`; for live use,
`ln -sfn <repo>/share/scout_commands/cortex ~/.scout/scout_commands/cortex`
exposes all of them through the only user-writable discovery map. In the
step-3 sandbox, writes under `~/.scout` outside the bwrap mounts did not
persist between tool calls, so the verification harness recreated the
symlink at the top of each run; on a real host a single `ln -sfn` is the
complete install. New scripts need no symlink update (it points at the
directory).

Smoke sweep (step 4, tmp/subcommand-smoke.log): 21/21 dedicated
subcommands render `--help` without error in a fresh process; the bare
`scout cortex` listing shows all 21 plus `task`, alphabetical, no
duplicates or stale entries; `scout cortex task --help` still renders the
generic passthrough help. The step-3 pilot checks were re-run after
generation and still pass.

One fix made during the sweep: the synopsis used to omit underscored
positional names (entity_type was silently dropped from the synopsis of
the property/list/activity family), leaving a synopsis whose order no
longer matched positional binding. Positionals are now shown verbatim in
assignment order.

## Pilot verification (2026-09-07)

Harness: `tmp/run-pilot.sh`, log: `tmp/pilot-verification.log`. All checks
run with `SCOUT_NOCOLOR=1 SCOUT_NO_PROGRESS=1` inside one bash call.

| check | command | result |
|---|---|---|
| i | `scout cortex` | PASS — lists `list`, `read`, `task` as subcommands |
| ii | `scout cortex list -t all` | PASS — real workspace output, exit 0 |
| iii | `scout cortex read --help` | PASS — synthesized help: name/type/last/range/start_line/lines with types, defaults, required flags, select options |
| iv | `scout cortex task cortex_search --query tools` | PASS — TSV hits from the live conversation, exit 0 |
| extra | `scout cortex task search --help` | PASS — delegates to the search task's help |
| extra | `scout cortex task nope` | PASS — clean `Unknown task cortex_nope`, exit 255 |

Also validated outside the pilot log: positional forms
(`scout cortex read <name> <type>` from a checkout-root run, `scout cortex
task list briefs`), array/JSON/int/string coercions via direct
`Cortex::CLI.parse` probes (`tools` JSON array intact, `dependencies`
comma-split, `start_line` left as a string, `arguments` JSON string passed
through), and `cortex_write` positional mapping (`path`, `content`).

## Full verification matrix (2026-09-07)

Transcript: `tmp/cli-verification.log` (harness `tmp/run-verify.sh`).
Result: **17 pass, 0 fail** after harness fixes; no CLI-layer code changes
were needed. The only non-passes encountered were harness bugs, not CLI bugs:
`tail -1` truncated Scout error output to its trailing color-reset escape, and
grep patterns assumed ASCII quotes where tasks raise with typographic quotes.

1. Help sweep: 22/22 subcommands render `SYNOPSYS` + `OPTIONS`, exit 0.
2. Read-only live runs: `list -t all`, `search --query tools`, `read --last 3`
   (integer coercion, no type error), `activity` in both flag and positional
   form (identical JSON), `property_read`/`read_list` on the `probe` fixtures
   raise the expected clean ScoutException from this checkout (see below).
3. Positional binding: `entity_property <type> <property>` reaches the task's
   own "Provide an entity identifier or a named list" validation (bindings 1-2
   correct, no drift); `list briefs`; `write` synopsis documents
   `[<path>] [<content>]`.
4. Round-trips (throwaway `tmp-cli/verify*.md`, removed afterwards):
   CLI write+read PASS; reference equivalence PASS; `list -t artifacts` clean
   afterwards (verified again later: 0 tmp-cli files anywhere, `.history`
   untouched).
5. JSON paths: `brief --help` documents `tools` as a JSON array;
   `JSON_ARRAY_INPUTS` in the helper routes it through `JSON.parse`; `entity_property
   --help` documents `arguments` as a JSON object (helper leaves :text inputs
   as strings for the task to parse).
6. Scope: git cannot run here (the `.git` file points at
   `../.git/modules/Cortex`, absent in this environment), so the change set is
   enumerated from the working tree: 22-file `share/scout_commands/cortex/`,
   no leftover single `cortex` file, `lib/Cortex/cli.rb`, `research/cli-commands.md`,
   tmp logs. `research/critique.md` and
   `research/design-decisions-management-pass.md` untouched.

### Findings from the matrix (beyond pass/fail)

- **The `probe` fixtures are not reachable from this checkout.** The
  `Observation/probe` entity property, lists, and artifacts live in
  `/home/mvazque2/tmp/var/cortex` (a foreign `:user`-anchored map created by
  an earlier session). From the Cortex repo, `:user` resolves to
  `~/.scout/var/cortex`, not that directory, so `property_read`/`read_list`
  correctly report them missing. The step-5 brief assumed a
  `scout_essentials_lib` map with `lists/probe`; no such map is configured
  here (no `cortex_path_map.yaml` anywhere in this environment; the gem's
  `var/cortex` does not exist). The CLI behaved correctly for the workspace
  it could actually see.
- **`scout workflow task Cortex <t>` cannot be run from inside the Cortex
  checkout**: `Workflow.require_workflow` resolves `workflows/Cortex` only
  through the PWD-relative `workflows` Path map, so from the repo root it
  falls back to autoinstalling `https://github.com/Scout-Workflows/cortex.git`,
  which does not exist. The equivalence check therefore runs in a scratch dir
  with `workflows/Cortex` symlinked to this checkout (same trick the CLI
  helper avoids by loading `workflow.rb` by path). Recorded as a ScoutCoder
  note in `lib/Cortex/cli.rb` and in the verify harness.
- **Environment caveat**: writes under `~/.scout` do not persist between
  bwrap invocations here, so the install symlink is (re)created at the top of
  every harness run; outside this sandbox a single `ln -sfn` is the whole
  install.
