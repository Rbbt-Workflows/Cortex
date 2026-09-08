# Command-line interface: `scout cortex`

The Cortex workflow ships a `scout cortex` command family installed under
`share/scout_commands/cortex/`. Each subcommand wraps exactly one Cortex
workflow task, takes the same inputs, and prints the task result:

```bash
scout cortex list -t artifacts
scout cortex search --query TP53 --type artifacts
scout cortex read claims/C42.md artifacts --lines 100
scout cortex write claims/C42.md --content "Claim: ..."
scout cortex task cortex_activity --entity_type TF --entity TP53
```

## Layout

```
share/scout_commands/cortex/     # one thin script per task
  list, read, write, edit, search, ...
  task                           # generic passthrough: first positional = task name
lib/Cortex/cli.rb                # the actual implementation (Cortex::CLI)
```

Every subcommand script is the same 8 lines: a header comment naming the task
it wraps, then `require_relative '../../../lib/Cortex/cli'` and
`Cortex::CLI.dispatch '<task>'`. Adding a new Cortex task therefore only means
dropping in one more script whose basename is the task name without the
`cortex_` prefix.

## Implementation notes

* Option tables, short-option allocation and the man-style `--help` rendering
  all come from the task's own input declarations (`Cortex::CLI::SUMMARIES`
  holds the one-line header; positionals come from `POSITIONALS`). The CLI is
  never hand-written per task.
* Positional arguments bind in the declared order after option parsing, so
  `scout cortex read claims/C42.md artifacts` equals
  `scout cortex read -n claims/C42.md -t artifacts`.
* `scout cortex task <task> ...` mirrors `scout workflow task Cortex <task>
  --exec` for tasks without a dedicated subcommand (first positional is the
  task name, with or without the `cortex_` prefix).
* `--help` renders the task documentation as the command documentation, per
  the design intent of the suite.

## Testing

`test/Cortex/test_cli.rb` covers the pure parts (option table construction,
short allocation, positional binding, JSON-array inputs, required-input
checks, script-header consistency). End-to-end behaviour of the installed
subcommands is exercised with a real `scout` binary against a scratch
workspace.

Two `SOPT` quirks the helper has to work around (documented inline in
`lib/Cortex/cli.rb`):

1. `SOPT.reset` only clears `@shortcuts`/`@all`; the input tables survive it,
   so options registered earlier in the same process (by the `scout` binary
   itself) would otherwise leak into every subcommand.
2. `SOPT.consume` lazily initializes `@@current_options` and never clears it,
   returning and merging into the *same* hash on every call; without an
   explicit `SOPT.current_options = {}` a second `parse()` in one process
   inherits the first one's options (masking missing-required-input errors).
