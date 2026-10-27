# Pending Improvements

Known gaps, deferred work, and accepted-for-now limitations across the Cortex
workspace. Each entry records the current behavior, why it is not implemented
yet, and what a fix would involve. Remove an entry when it is implemented.

Entity support (entity properties, named entity lists, the execution
registry, `cortex_activity`) was removed from Cortex in October 2026 and now
lives in the Semantics workflow; tracking scientific evidence is the
responsibility of the Research workflow. The entries below that mention those
features are kept as the historical record of decisions made while they lived
here; they are not pending work for Cortex.

---

## Test-suite hygiene

- Running every `test/Cortex/test_*.rb` file in a single process shows cross-file interference (state shared through the live workspace). Each file passes in isolation; reproduce on a clean tree with `git stash` before blaming a change.
- `test/Cortex/test_path_maps.rb` has one environment-dependent failure (`test_unanchored_pwd_in_plain_dir_keeps_pwd_anchor`) that predates the workspace reduction and is not a Cortex defect.
