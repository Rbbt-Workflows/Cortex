# ==========================================================================
# Placement guard: entity property jobs root at the :current map
# --------------------------------------------------------------------------
# Pins the committed engine change (lib/Cortex/entities.rb
# entity_new_module -> mod.directory.path_maps[:default] = :current):
#
#   * a NEW entity type built through Cortex::Types.for gets the
#     :default => :current annotation, and a real property job
#     materializes under the scratch :current root (tmp/entity_test_var),
#     NOT under ~/.scout;
#   * the annotation is the placement determinant and persists across
#     repeated mod.directory accesses (Workflow#directory memoization);
#   * when no candidate exists anywhere in map order, task-directory
#     resolution falls back to follow(:default) => the :current root;
#   * regression boundary for defect #2 (latent re-rooting, first-existing
#     wins): when a later map (:user) ALREADY holds the type directory,
#     .find resolves there, NOT at :default.  Simulated entirely inside
#     the scratch roots (mirrors tmp/placement_probe_step2.rb c-sim).
#
# NOTE (open defect #1, deliberately NOT asserted as correct behavior):
# the annotation mutates the @path_maps Hash shared by reference with
# Workflow.directory, flipping :default process-wide for workflow modules
# whose directory Path is computed AFTER an entity build in the same
# process.  Probe evidence: tmp/placement-step2.out probes b1/b2/b3.
# This file does not pin that side effect as intended semantics.
#
# ISOLATION: identical to test_entities.rb (scratch path maps under
# tmp/entity_test_var installed after the workflow loads).
# ==========================================================================
require File.expand_path(__FILE__).sub(%r(/test/Cortex/.*), '/test/Cortex/test_helper.rb')
require 'fileutils'
require 'json'

FileUtils.rm_rf(SCRATCH) if File.directory?(SCRATCH)
[LIBDIR, USERDIR].each { |d| FileUtils.mkdir_p(d) }

Path.path_maps[:current] = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:lib]     = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:user]    = File.join(USERDIR, '{TOPLEVEL}', '{SUBPATH}')
Scout::Config::CACHE['cortex'] = [[['read_maps'], 'lib,current,user'],
                                  [['write_map'], 'current']]
Cortex.instance_variable_set(:@entity_root, Path.setup('var'))

PLACEMENT_TYPE = 'PlacementGuard'.freeze

module TestPlacementHelpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', PLACEMENT_TYPE))
      FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', PLACEMENT_TYPE))
      FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', PLACEMENT_TYPE))
      FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', PLACEMENT_TYPE))
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)
  end

  # Build a fresh module for the type exactly the way the engine does
  # (Types.for is deliberately fresh-unmemoized) and install one trivial
  # :single property with the identity-input envelope (design SS5).
  def build_type
    mod = Cortex::Types.for(PLACEMENT_TYPE)
    identities = {
      _cortex_definition:         "#{PLACEMENT_TYPE}/probe",
      _cortex_definition_version: 1,
      _cortex_definition_digest:  'placement-guard-test'
    }
    defn = {
      type: PLACEMENT_TYPE,
      property: 'probe',
      body: 'entity.to_s + "@placement"',
      body_path: "probe:#{PLACEMENT_TYPE}/probe.rb",
      meta: {
        'entity_type' => PLACEMENT_TYPE, 'property' => 'probe',
        'description' => 'placement guard probe',
        'property_type' => 'single', 'result_type' => 'string',
        'arguments' => [], 'dependencies' => [],
        'version' => 1, 'digest' => 'placement-guard-test'
      }
    }
    Cortex::Types.register(mod, defn, identities)
    mod
  end
end

class TestPlacementDefault < Test::Unit::TestCase
  include TestPlacementHelpers

  def setup
    purge!
  end

  # ------------------------------------------------------------------
  # The annotation itself (step 3, design §11.4): :default is pinned to a
  # CONCRETE absolute template <jobs root>/{TOPLEVEL}/{SUBPATH} -- CWD
  # independent, unlike the old symbolic :current.  It survives repeated
  # accesses (memoized Path, same object) and every module build carries it.
  # ------------------------------------------------------------------
  def test_module_directory_annotation_is_current_and_persists
    mod = Cortex::Types.for(PLACEMENT_TYPE)

    pinned = mod.directory.path_maps[:default]
    assert_match(%r{/var/jobs/\{TOPLEVEL\}/\{SUBPATH\}\z}, pinned.to_s,
                 'entity_new_module pins :default to the absolute checkout jobs-root template')
    assert_equal File.join(LIBDIR, 'var', 'jobs'),
                 pinned.to_s.sub(%r{/\{TOPLEVEL\}/\{SUBPATH\}\z}, ''),
                 'the pinned root is the scratch :current var/jobs (LIBDIR-anchored)'

    d2 = mod.directory
    assert_same mod.directory, d2,
                'Workflow#directory memoizes: repeated access returns the same Path'
    assert_equal pinned, d2.path_maps[:default],
                 'the annotation persists on the memoized Path object'

    # Fresh build (Types.for is fresh-unmemoized) carries it again.
    mod_b = Cortex::Types.for(PLACEMENT_TYPE)
    assert_equal pinned, mod_b.directory.path_maps[:default],
                 'every module build carries the annotation (no newness gate)'
  end

  # ------------------------------------------------------------------
  # End-to-end: a real property job of a NEW type materializes under the
  # scratch :current root (LIBDIR), never under the real home.
  # ------------------------------------------------------------------
  def test_new_type_job_materializes_under_scratch_current_root
    mod    = build_type
    entity = mod.setup 'alpha'
    job    = entity.probe_job({})
    job.run

    assert_equal :done, job.info[:status]
    assert File.exist?(job.path), "job file exists: #{job.path}"

    expected_root = File.join(LIBDIR, 'var', 'jobs', PLACEMENT_TYPE)
    assert job.path.to_s.start_with?(expected_root),
           "job path roots at the scratch :current map: #{job.path}"
    refute job.path.to_s.start_with?(ENV['HOME']),
           "job path must not root under the real home: #{job.path}"
  end

  # ------------------------------------------------------------------
  # Resolution rule when nothing exists anywhere in map order: the
  # task directory falls back to follow(:default) => the :current root.
  # (Same assertion family as above, checked at the directory level.)
  # ------------------------------------------------------------------
  def test_task_directory_falls_back_to_default_current_when_no_candidate
    mod      = Cortex::Types.for(PLACEMENT_TYPE)
    task_dir = mod.directory['probe']

    refute File.exist?(File.join(LIBDIR, 'var', 'jobs', PLACEMENT_TYPE, 'probe'))
    refute File.exist?(File.join(USERDIR, 'var', 'jobs', PLACEMENT_TYPE, 'probe'))

    found = task_dir.find
    assert found.to_s.start_with?(File.join(LIBDIR, 'var', 'jobs', PLACEMENT_TYPE)),
           "no candidate anywhere -> :default fallback roots at the pinned jobs root: #{found}"
    assert_equal :default, found.where,
                 'the fallback comes from the pinned :default map (CWD-independent)'
  end

  # ------------------------------------------------------------------
  # Defect #2 boundary (first-existing-wins): when a later map (:user)
  # ALREADY holds the type's task directory, .find re-roots there and the
  # :default fallback never fires.  Fully simulated inside scratch roots,
  # no execution, mirroring tmp/placement_probe_step2.rb probe c-sim.
  # ------------------------------------------------------------------
  def test_first_existing_dir_in_map_order_wins_over_default
    sim_root   = File.join(SCRATCH, 'placement_sim')
    current_rb = File.join(sim_root, 'current_root')
    user_rb    = File.join(sim_root, 'user_root')

    FileUtils.mkdir_p(File.join(user_rb, 'var', 'jobs', PLACEMENT_TYPE, 'probe'))
    begin
      p = Path.setup("var/jobs/#{PLACEMENT_TYPE}/probe")
      p.path_maps[:current] = File.join(current_rb, '{TOPLEVEL}', '{SUBPATH}')
      p.path_maps[:user]    = File.join(user_rb, '{TOPLEVEL}', '{SUBPATH}')
      p.path_maps[:default] = :current

      found = p.find
      assert_equal File.join(user_rb, 'var', 'jobs', PLACEMENT_TYPE, 'probe'),
                   found.to_s,
                   'existing :user copy wins over the :default => :current fallback'
      assert_equal :user, found.where
    ensure
      FileUtils.rm_rf(sim_root)
    end
  end
end
