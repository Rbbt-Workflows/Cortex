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

Deliberate scope decisions, kept here so they are not re-litigated:

- Keep the four facets (properties, investigations, lists, mentions). They
  answer what-can-I-ask / what-have-I-asked / what-is-it-grouped-with /
  where-does-it-occur; richer facets (claims, artifacts, relationships)
  should emerge through investigation follow-ups, not new facet types, and
  only when a real agent workload demonstrates a gap.
- Keep mentions raw. De-noising (skipping tool-call JSON, incidental table
  rows) is a semantic-indexing problem; the facet's contract is "where does
  this token occur", and its note says so.
- Keep the report deterministic and shallow: no result payloads, no
  stochastic sampling inside `cortex_activity` itself. Any relevance-biased
  projection belongs in a separate operation.
- `cortex_activity` stays Cortex-store-scoped. Mirroring repository
  artifacts into the workspace just to improve `mentions` coverage was
  considered and rejected; a general source model (Cortex resource /
  repository resource / KnowledgeBase resource with explicitly configured
  readable sources) is the direction if coverage ever needs to widen.

Planned progression beyond the deterministic v1 facets:

- Relationship facet: co-occurring entities across lists and examination
  records (MYC/FOXO3 next to TP53).
- Selected-results facet: small representative excerpts from high-value
  examinations, keeping result payloads out of the report by default.
- Preferential sampling (recent investigations, under-explored properties,
  recently modified artifacts) as a SEPARATE stochastic operation, never
  inside `cortex_activity` itself.

Implemented from the AGS-use advice (2026-09):

- Investigations carry `status` (active / older / removed): historical
  fact vs current capability, records never deleted.
- Section meta carries `total` / `shown` / `has_more`; `total` is the
  facet's full count, never the bounded-scan count (mentions bound their
  own scan by 10x limit and say so).
- Map identifiers normalized to bare strings across every facet.

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
