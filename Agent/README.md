# SolAgents - AOS v1 agent suite

This directory overrides the default agent directory (see the
`chats/Agent` path map resolution: the current project's `Agent/` wins
when present).

## Layout

- `intro` - core doctrine imported by all agents (classify before acting,
  execution venues, minimum sufficient action, bounded delegation, loop
  prevention, verification, persistence, stopping).
- `Sol` - strategic inference point; expensive; strategy only.
- `Manager` - coordinator; routes to Worker/ScoutCoder/Critic/Sol.
- `Worker` - bounded execution in the sandbox; evidence reports;
  experiments under `research/`.
- `Critic` - independent verdicts (PASS/NEEDS_WORK/BLOCKED/OVERWORKED).
- `ScoutCoder` - Scout framework implementation with documentation
  tooling.
- `FitMain` - FitAgent entry point for use-case runs.

## Composition model

    effective agent = intro (kernel doctrine)
                     + role start_chat (judgment policy)
                     + introduced workflows (capability contracts)
                     + current task brief

The `intro` holds the stable doctrine so role chats stay small.

## Testing with FitAgent

    scout workflow task FitAgent use_case \
      --agents ./agents/Basic --use_case ./use_case/Smoke

Create use cases under `use_case/` with `main.chat` (+ optional
`workflow.rb`, data files, `analyze.chat`).
