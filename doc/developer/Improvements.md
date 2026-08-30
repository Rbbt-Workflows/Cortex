# Pending Improvements

Known gaps, deferred work, and accepted-for-now limitations across the Cortex
workspace. Each entry records the current behavior, why it is not implemented
yet, and what a fix would involve. Remove an entry when it is implemented.

---

## Entity properties and lists

### Removed list members keep stale per-member records

`cortex_write_list` replaces list content in place. When a member is removed
from a named list, its per-member execution record
(`properties/<Type>/<property>/<entity>.json`) survives with its last
argument set and run count until that entity is examined again. The
list-receiver record (`receiver: list:<type>_<list>`) tracks the argument set
and run count but does not store the member set itself, so it cannot detect
the removal either.

- **Current behavior**: after a list mutation the list-receiver job and every
  current member's job are invalidated by mtime and recomputed (see
  "Execution registry" in `Entities.md`); removed members' records are left
  untouched.
- **Why not implemented**: the registry deliberately records history, not
  state; wiping per-member records on list change would erase the record of
  the examinations that did happen. Distinguishing "was examined" from "is a
  current member" needs an explicit membership timestamp in the record.
- **Candidate fix**: store the member set (or a digest of it) in the
  list-receiver record on each run, and let listings/activity mark
  per-member records whose last run predates the current membership as
  "stale membership" instead of silently deleting them.

## Activity report (`cortex_activity`)

Planned progression beyond the deterministic v1 facets (properties,
investigations, lists, mentions):

- Relationship facet: co-occurring entities across lists and examination
  records (MYC/FOXO3 next to TP53).
- Selected-results facet: small representative excerpts from high-value
  examinations, keeping result payloads out of the report by default.
- Preferential sampling (recent investigations, under-explored properties,
  recently modified artifacts) so repeated reports on the same entity can
  surface different facets; deliberately stochastic only after the
  deterministic core is trusted.

## Test-suite hygiene

- Running every `test/Cortex/test_*.rb` file in a single process shows cross-file interference (state shared through the live workspace). Each file passes in isolation; reproduce on a clean tree with `git stash` before blaming a change.

## Deferred entity-tool work (from the reference implementation)

- `multiple` property type (needs per-member persistence tests).
- Cross-entity dependency mapping language.
- `cortex_list type=entities` (schema change to existing tool).
- Dynamic dependency wiring of the property Step into the outer task (the
  fallback receipt path is sufficient; revisit when the scout-gear dep API
  is confirmed).
- Full `VersionedResource` extraction shared with artifacts and entities.
- Semantic search / NER / ChatAnalyst / AGS ontology / relevance injection.
