# Foreign-entity adoption validation — design §11 (relaxed adoption)

iteration: validation of the committed engine change (user iteration 11;
follows the placement validation, `impl-step9-current-placement-validation.md`)
date: 2026-09-14 (orientation) and 2026-09-15 (probes, suite, CLI; this
documentation pass is step 7a — no `lib/` or `test/` edits in this step)
committed change: relaxed foreign-entity adoption per the design artifact
§11 (v16, amended v17). Code merged before this pass; evidence below.
design artifact: `var/cortex/artifacts/design/property-subsystem-redesign.md`
§11 (amended in parallel by the design agent — not touched here).

## Purpose

Record what relaxed adoption changed, why, the §11 decisions as
implemented, and the validation evidence (probes, suite, CLI), with
validated claims separated from unverified ones. The motivating demo: a
foreign `EntityWorkflow` module (`Security`, from a `Finances` workflow)
should be runnable through `cortex_property_run` without any Cortex
definition, and definable through `cortex_property_define` with the new
body actually served.

## 1. What changed and why (code reading, `tmp/step1-orientation.md`)

- `resolve_entity_module` (lib/Cortex/entities.rb) ADOPTS a pre-existing
  `EntityWorkflow` constant (extend `Entity` when needed, register under
  the type, pin the job directory); a pre-existing NON-Entity constant is
  still a hard `ScoutException` (rule (b), unchanged); no constant →
  managed anonymous module, as before.
- `load_entity_type` returns the adopted module for a foreign type with
  ZERO Cortex definitions (previously nil): the type is unknown only when
  no adoptable constant exists either.
- `run_property` classifies the regime BEFORE job building: an ACTIVE
  Cortex definition always selects the task path; no definition on an
  adoptable module runs the plain method; failures on either path surface
  as §2.6 error envelopes, never a silent fallback.
- Job placement is anchored to the checkout root (fixes anomaly A);
  remove semantics were corrected (anomaly B); the eviction hook prefix
  was repaired (it previously matched nothing).

## 2. The §11 decisions (as implemented and validated)

1. **Adoption eligibility** — pre-existing `EntityWorkflow` module
   loadable by constant name is adoptable; non-Entity constants stay a
   hard error.
2. **Regime dispatch** — A (no active definition): plain-method
   execution on the entity object; B (active definition): task path via
   build_jobs/execute_jobs with the §2.7 11-key receipt; C
   (define/update over the adopted module): task path serving the NEW
   body at a MOVED address. Regime-B build/execute/input-validation
   failures are errors (§2.6 envelope), never silent fallback to the
   plain method; plain-path `NoMethodError`/`ArgumentError` likewise
   return the §2.6 envelope (verdict `execution_error`).
3. **Named lists** — task path fans out with entity_options merged;
   plain path executes members individually, ONE fallback receipt per
   member (tagged `entity_list`), preserving `failed_members`/
   `total_members` counting.
4. **Receipts** — regime A populates `receiver` with the entity id
   (the original demo showed `receiver: null`; fixed); regime A uses the
   same envelope with `definition: {version: 0, digest: null}` and null
   `address`/`result_kind`/`status`/`materialized`/`info_path`; no new
   keys.
5. **Arguments rule (plain path)** — empty Hash passes nothing;
   non-empty Hash binds via `Method#parameters` (kwargs for `:key`/
   `:keyreq`, one positional Hash for a positional parameter, else
   `ParameterException` verdict `argument_error`).
6. **Foreign job placement** — new labels root at the checkout
   `var/jobs/<Type>/...` regardless of process CWD; 3-segment address
   grammar and `cortex_result` resolution unchanged; pre-existing labels
   keep replaying at the old root (two-roots semantics).
7. **Eviction/invalidation mechanism** — the `_cortex_definition*`
   identity inputs are merged into `provided_inputs`, digested into BOTH
   the Task memo key and the result address, so a definition change
   always yields a new memo key and a new address; the eviction hook is
   same-process memory hygiene only.

Implementation-established corrections beyond the seven (design §11
"orphaned-body hygiene" and "test authority"): remove deletes the BODY
and KEEPS the meta tombstone (removal record) and drops the ownership
entry; define-over-orphan starts at version 1 with fresh meta; the four
authoritatively-stale tests were rewritten to the §11 contract.

## 3. Evidence (pointers; files are the authority)

### Step 3 — engine probes (`tmp/step3-probes/`)

- `p1_final.out` (plain path, regime A): scalar receipts with
  `receiver: "GOOG"` populated, `definition {version:0, digest:null}`,
  null address/materialized/info_path, raw values; kwargs and positional
  argument binding both served; zero-arg method + non-empty arguments →
  `ParameterException verdict=argument_error`; named list → 3 per-member
  fallback receipts tagged `entity_list`; non-adoptable constant
  (`PlainRuby`) → hard `ScoutException`; adoptable module without method
  → actionable error. (`p1_before.out` records the pre-fix crash that
  motivated regime classification before job building.)
- `p2_final.out` (regimes B/C): define on the adopted module → version 1,
  3-segment address `P2Sec/fee_mark/GOOG_c862…`, real Step on disk; update
  body A→B → version 2, MOVED address `GOOG_8804…`, value `MARK-B:GOOG`
  (new body served).
- `p3_after.out` (placement, CWD-independence): run executed with
  `cwd_was: …/var/cortex/entities`, result at
  `/bulk/…/Cortex/var/jobs/P3Type/probe/GOOG_562b…`,
  `under_checkout_var_jobs: true`.
- `p4_after.out`: `entities.rb` loads standalone (`P4 OK`).

### Step 4 — invalidation discrimination (`tmp/step4-probes/VERDICT.md`)

Verdict block, quoted verbatim:

> ## Step 4 verdict (E1/E2, fresh processes, BWRAP=false, 2026-09-15)
>
> **Hypothesis H2 holds: eviction is belt-and-braces, not essential.**
>
> - E1 (control, eviction enabled, one process): define A → run → update to B → run.
>   Served body B at a NEW address (`E4A/mark/GOOG_59e153…` → `E4A/mark/GOOG_20a7fc…`).
>   Memo keys after runA vs runB differ:
>   `Task_job_mark:ff7cf2ad…` → `Task_job_mark:c5d5606e…`.
> - E2 (discriminator, eviction neutralized in-process by aliasing
>   `Cortex.evict_task_job_cache!` to a no-op before any define/run): the
>   post-update run STILL served body B at a NEW address. Memo keys again
>   differ across the update: `Task_job_mark:a99c2254…` (body A) vs
>   `Task_job_mark:14ee77b8…` (body B).

The same file records the mechanism (memo key composition at scout-gear
`workflow/task.rb:47`; identity merge in `properties_run.rb build_jobs`)
and the discovery that the ORIGINAL hook prefix `"Task job <property>"`
matched NOTHING against the sanitized keys
(`var/cache/persistence/Task_job_<property>:<md5>`) — a silent no-op,
repaired in step 3 to the sanitized prefix with the `:` terminator.

### Step 5 — suite and eviction probe

- `tmp/step5-suite.txt`: `SUITE: 247 tests, 1209 assertions, 0 failures,
  0 errors` (step-3 suite baseline `tmp/step3-suite.txt`: 237/1162/0).
  Includes `test/Cortex/test_foreign_entity_adoption.rb` (T1–T10).
- `tmp/step5-probes/evict_check.out`: repaired hook evicts (count 1 after
  update; manual eviction of the residual entry succeeds; body B served
  at the moved address).

### Step 6 — end-to-end CLI (`tmp/step6-cli/`, README + captures)

All four verdicts MATCH (`is_fee.out` regime A with value `false`;
`list_plain.out` three per-member fallback receipts; `define_v1.out`
version 1 / digest `42d233…` / address `Security/step6_mark/GOOG_6f2c4863…`
/ value `MARK-A:GOOG`; `update_v2.out` version 2 / digest `773ffa…` /
moved address `GOOG_0987150…` / `MARK-B:GOOG`). Definitions lived in a
scratch `:current` store while the entity job tree rooted at the CHECKOUT
(`var/jobs/Security/...`), confirming CWD- and store-independent
placement. **Stand-in caveat:** the real `Finances` workflow is not
present on this machine (no checkout anywhere; GitHub 404), so CLI
verification used a minimal in-process `Security` `EntityWorkflow`
stand-in with the same contract (`is_fee? → false`); the user's original
demo output remains the only real-Finances evidence.

CLI environment notes (also documented in `doc/user/CortexCLI.md`):
`scout task` does not exist on this build — use
`scout workflow task Cortex ...` or the `scout cortex` subcommands; the
repo-root form hits a discovery/autoinstall trap (`Workflow Cortex not
found` → GitHub 404) — workaround: scratch workflows dir with a symlink
to the checkout; the `:json` projection stringifies plain-path booleans
(`"false"`).

## 4. Defects found and fixed during the iteration

- **Anomaly A — mis-rooted results** (`tmp/step1-orientation.md` §7): a
  `:current`-based default rooted foreign-type jobs at
  `{PWD}/var/jobs`, producing
  `var/cortex/entities/var/jobs/Security/echo/GOOG_f5bb…{,.info}` when
  the CWD was the entities namespace. FIXED: checkout-rooted pin
  (`entity_jobs_root` + `pin_module_directory!`), which also merges a
  private `path_maps` copy (closing defect D1's shared-Hash mutation).
  The authorized one-time residue was deleted in step 3.
- **Anomaly B — orphaned body** (`tmp/step1-orientation.md` §8):
  `Sec/echo.rb` without meta (and an emptied `.meta/Security/`)
  contradicted remove semantics. FIXED: remove deletes the body, keeps
  the meta tombstone, drops the ownership entry; define-over-orphan
  starts at version 1 with fresh meta. Residue deleted in step 3.
- **No-op eviction hook**: original prefix `"Task job <property>"` never
  matched the sanitized cache keys (step-4 verdict, above). FIXED: match
  the sanitized prefix `Task_job_<property>:`; verified eviction count 1
  (`tmp/step5-probes/evict_check.out`), pinned by T10.
- **Step-11 cleanup — residue, not fixtures** (2026-09-15): greps of
  `test/`, `lib/`, `doc/` and `research/` for `PlacementE2E`, `Step4CLI`
  and `echo_note` return zero hits (tests use their own scratch roots
  under `tmp/entity_test_var` and types like `Step5A`/`AdoptSec`), so
  `var/cortex/entities/{PlacementE2E/echo_note.rb,Step4CLI/echo.rb}`
  plus their `.meta` sidecars were removed as residue.
  `doc/user/WorkspaceTools.md.orig` (no test/doc references to the
  `.orig` name) was deleted as a stale pre-adoption backup.

## 5. Open items

- Real-Finances rerun: not possible on this machine (workflow absent);
  a rerun against the real workflow is the missing independent evidence
  for the demo scenario.
- The design artifact §11 amendment (v17) was applied in parallel by the
  design agent; this note deliberately does not modify it.

## 6. Claim ledger

VALIDATED: adoption + three regimes + receipts + arguments rule + named
lists (step-3 probes, T1–T10 suite, CLI captures); invalidation
mechanism and eviction-as-hygiene (step-4 fresh-process discrimination,
step-5 eviction probe); placement CWD-independence incl. definitions in a
scratch store (step-3 p3, step-6 CLI); remove/orphan semantics (suite);
suite green 247/1209/0.

VALIDATED-WEAKER: CLI verdicts verify the CLI↔engine contract through a
minimal stand-in `Security` module, not the real Finances workflow.

UNVERIFIED: real-Finances/`Security` behavior (workflow absent; user demo
output is user-asserted evidence only).
