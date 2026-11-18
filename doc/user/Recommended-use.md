# Recommended use: the Cortex workspace cycle

This page gives the intended agent workflow over the workspace, worked
examples, and the etiquette that keeps the workspace useful. For the
per-tool reference see [WorkspaceTools.md](WorkspaceTools.md); for the
workspace model see [Workspace.md](Workspace.md).

---

## The cycle

1. **Discover** — `cortex_list` to see what exists (metadata only, always
   small and paginated).
2. **Locate** — `cortex_search` to find material by content, across all
   readable path maps.
3. **Inspect** — `cortex_read` to fetch only the parts you need:
   conversation index plus `last`/`range` slices, or line-paginated
   artifact pages.
4. **Contribute** — `cortex_continue` to add a turn to a conversation
   (optionally through a briefed agent), `cortex_brief` to prepare or
   refresh a reusable brief.
5. **Consolidate** — `cortex_write` to extract reusable results into
   artifacts, `cortex_edit` for targeted corrections without resending
   whole documents.
6. **Manage** — `cortex_rename`, `cortex_move`, `cortex_remove` only when
   deliberately reorganizing existing resources.

Two disciplines make this work well:

- Never rely on an important conclusion living only in a conversation:
  conversations are working space; extract durable results as artifacts.
- Do not assume an artifact exists because a conversation mentions it:
  verify with `cortex_list` / `cortex_read`.

Briefing is decoupled from agent naming: a brief is stored under its own
name in `briefs/` and referenced as `Agent/brief` — see
[Conversations.md](Conversations.md) for briefing and continuing, and
[WorkspaceTools.md](WorkspaceTools.md) for the full brief tool-provisioning
grammar (`tools` input).

## Examples

Every example below is also available as a dedicated `scout cortex`
subcommand — the subcommand scripts exist in this repository under
`share/scout_commands/cortex/` (see [CortexCLI.md](CortexCLI.md)).
Installed-CLI availability of these subcommands in a given environment is
unverified unless Cortex is installed there; when in doubt, use the
generic `scout workflow task Cortex <task> ...` form, which needs only the
workflow (not the command scripts) on the installed surface.

Brief an agent for later reuse:

```bash
scout workflow task Cortex cortex_brief --conversation bash-math \
    --agent Worker \
    --prompt "You are a math worker; always compute sums with bash arithmetic."
```

Provision the brief's tooling so the agent receives exactly these tools:

```bash
scout workflow task Cortex cortex_brief --conversation bash-math \
    --agent Worker \
    --tools '["ScoutCoder help_workflow", "Baking"]' \
    --prompt "You are a math worker; always compute sums with bash arithmetic."
```

Continue a conversation with the briefed agent:

```bash
scout workflow task Cortex cortex_continue --conversation Summing \
    --agent Worker/bash-math \
    --prompt "Compute S = 1 + 12 + 123 + 1234 exactly."
```

Find and read prior material:

```bash
scout workflow task Cortex cortex_search --query TP53 PD_PI --type artifacts
scout workflow task Cortex cortex_read --type artifacts --name claims/C42.md --start_line 1 --lines 100
```

Extract a durable result:

```bash
scout workflow task Cortex cortex_write --path claims/C42.md \
    --content "Claim: ... (evidence, context, caveats)"
```

## Cortex etiquette

Whenever you need to establish that something works, **open an investigation**
and leave the results for those who come after you. An investigation should
conclude when the issue is clear and understood. At that point, consider what
should be done with the information: consolidate it, turn it into
documentation, update an existing artifact, or otherwise clean it up so that
future work becomes simpler.

Maintain **named Cortex conversations** for different areas of work, and
recruit the appropriate agents for each. When a new line of work branches
off an established conversation, start a new named conversation and carry
over only the conclusions that matter (preferably as artifacts the new
conversation can cite).

For tasks that require substantial preparation—such as writing workflow tasks,
debugging complex errors, or developing tests—consider **briefing a specialist
agent first**. Give it additional instructions about what it needs to
investigate and, when appropriate, have it perform a simple task first. This
can verify that the agent has acquired the necessary context and understanding
before it is trusted with a sequence of more complicated tasks.
