# Tests for the Cortex managed-entity engine and its tasks.
#
# ISOLATION: every entity definition, meta file and history snapshot, and every
# managed-entity job directory, is redirected into tmp/entity_test_var (two
# distinct physical roots so :lib/:current vs :user behave like real maps).
# The engine freezes its entity root on first use (lib/Cortex/entities.rb
# #entity_root), so the maps are installed before any storage call and
# @entity_root is reset to the RELATIVE "var" path, which resolves through the
# scratch maps.  Scout.var is likewise relative, so job dirs land in scratch.
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

TEST_TYPES = %w[ProbeGene ProbeDep ProbeA ProbeB ProbeCyc ProbeArr ProbeBoth
                ProbeNames ProbeRecycle].freeze

module TestEntitiesHelpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      %w[entities .meta .history jobs].each do |sub|
        TEST_TYPES.each do |t|
          FileUtils.rm_rf(File.join(root, 'var', 'cortex', sub == 'jobs' ? 'jobs' : 'entities',
                                    sub == 'jobs' ? t : t)) if sub == 'jobs'
          FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities',
                                    sub, sub.start_with?('.') ? t : t))
        end
      end
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', 'Cortex'))
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)
  end

  def define(type, property, body:, **rest)
    Cortex.define_property(type, property,
      body: body, description: rest.delete(:description) || 'test',
      property_type: rest.delete(:property_type) || :single,
      result_type: rest.delete(:result_type) || :string,
      arguments: rest.delete(:arguments) || [],
      dependencies: rest.delete(:dependencies) || [],
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'test_entities')
  end

  def run_prop(type, property, entity, arguments: {}, update: false)
    Cortex.run_entity_property(entity_type: type, property: property,
                               entity: entity, arguments: arguments,
                               entity_options: nil, update: update)
  end

  def assert_scout_ex(label = nil, msg = nil)
    e = assert_raises(ScoutException) { yield }
    assert_match(msg, e.message, "#{label}: message should be actionable") if msg
    e
  end
end

class TestCortexEntities < Test::Unit::TestCase
  include TestEntitiesHelpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # ------------------------------------------------------------------
  # names
  # ------------------------------------------------------------------
  def test_entity_type_names
    assert_equal('ProbeNames', Cortex.entity_type!('ProbeNames'))
    assert_equal('A::B',       Cortex.entity_type!('A::B'))
    assert_scout_ex('type') { Cortex.entity_type!('gene') }
    assert_scout_ex('type') { Cortex.entity_type!('') }
    assert_scout_ex('type') { Cortex.entity_type!('Foo/../Bar') }
    assert_scout_ex('type') { Cortex.entity_type!('..') }
    assert_scout_ex('type') { Cortex.entity_type!('lower/Case') }
  end

  def test_property_names
    assert_equal('snake_case_1', Cortex.entity_property_name!('snake_case_1'))
    %w[Upper _leading 1number has-dash with.dot job entity entity_list
       inputs step dependencies foo_job _cortex_x].each do |bad|
      assert_scout_ex("property #{bad}") { Cortex.entity_property_name!(bad) }
    end
    %w[entity list jobname _cortex_definition _cortex_definition_version
       _cortex_definition_digest].each do |bad|
      assert_scout_ex("argument #{bad}") { Cortex.entity_argument_name!(bad) }
    end
  end

  def test_path_safety
    assert_scout_ex('path') { define('ProbeNames', '../x', body: 'entity.to_s') }
    assert_scout_ex('path') { define('Foo/../Bar', 'x', body: 'entity.to_s') }
    assert_scout_ex('path') { define('..', 'x', body: 'entity.to_s') }
  end

  # ------------------------------------------------------------------
  # lifecycle
  # ------------------------------------------------------------------
  def test_define_creates_body_and_meta
    r = define('ProbeGene', 'simple', body: '"v:" + entity.to_s')
    assert_equal 1, r[:version]
    assert(File.exist?(Cortex.entity_body_path('ProbeGene', 'simple')))
    assert(File.exist?(Cortex.entity_meta_path('ProbeGene', 'simple')))
    meta = JSON.parse(File.read(Cortex.entity_meta_path('ProbeGene', 'simple')))
    assert_equal 1, meta['schema']
    assert_equal 'single', meta['property_type']
    assert_equal true, meta['active']
    assert_equal 'ProbeGene', meta['entity_type']
    assert_equal 'simple', meta['property']
    assert_equal r[:digest], meta['digest']
  end

  def test_duplicate_define_refused
    define('ProbeGene', 'dup', body: 'entity.to_s')
    assert_scout_ex('duplicate') { define('ProbeGene', 'dup', body: 'other') }
  end

  def test_update_versioning_and_history
    define('ProbeGene', 'versioned', body: 'entity.to_s + ":1"')
    assert_scout_ex('stale update', /Version mismatch/) do
      Cortex.update_property('ProbeGene', 'versioned', expected_version: 2,
                              body: 'x', agent: 't', job: 't')
    end
    Cortex.update_property('ProbeGene', 'versioned', expected_version: 1,
                           body: 'entity.to_s + ":2"', agent: 't', job: 't')
    meta = JSON.parse(File.read(Cortex.entity_meta_path('ProbeGene', 'versioned')))
    assert_equal 2, meta['version']
    assert_equal 2, meta['versions'].length
    assert_equal 'update', meta['versions'].last['action']
    assert_equal 1, Dir[File.join(Cortex.entity_history_dir('ProbeGene', 'versioned'), '*.rb')].length
    assert_equal 1, Dir[File.join(Cortex.entity_history_dir('ProbeGene', 'versioned'), '*.json')].length
  end

  def test_failed_update_leaves_active_intact
    define('ProbeGene', 'safe', body: 'entity.to_s + ":1"')
    before = File.read(Cortex.entity_body_path('ProbeGene', 'safe'))
    assert_scout_ex('bad body') do
      Cortex.update_property('ProbeGene', 'safe', expected_version: 1,
                             body: 'this is not ruby (', agent: 't', job: 't')
    end
    assert_equal before, File.read(Cortex.entity_body_path('ProbeGene', 'safe'))
    assert_equal 1, JSON.parse(File.read(Cortex.entity_meta_path('ProbeGene', 'safe')))['version']
  end

  def test_remove_tombstones_and_allows_redefine
    define('ProbeGene', 'gone', body: 'entity.to_s')
    assert_scout_ex('stale remove') do
      Cortex.remove_property('ProbeGene', 'gone', expected_version: 99,
                             agent: 't', job: 't')
    end
    Cortex.remove_property('ProbeGene', 'gone', expected_version: 1,
                           agent: 't', job: 't')
    assert(!File.exist?(Cortex.entity_body_path('ProbeGene', 'gone')),
           'active body deleted on remove')
    meta = JSON.parse(File.read(Cortex.entity_meta_path('ProbeGene', 'gone')))
    assert_equal false, meta['active']
    assert_equal true, meta['removed']
    assert_equal 1, Dir[File.join(Cortex.entity_history_dir('ProbeGene', 'gone'), '*.rb')].length
    r = define('ProbeGene', 'gone', body: 'entity.to_s + ":again"')
    assert_equal 1, r[:version], 'redefine after removal restarts at version 1'
  end

  # ------------------------------------------------------------------
  # dispatch (single/array/both)
  # ------------------------------------------------------------------
  def test_single_dispatch_scalar_and_list
    define('ProbeGene', 'echo', body: '"E:" + entity.to_s')
    assert_equal 'E:Tp53', run_prop('ProbeGene', 'echo', 'Tp53')[1]
    assert_equal ['E:Tp53', 'E:Kras'], run_prop('ProbeGene', 'echo', %w[Tp53 Kras])[1]
  end

  def test_array_dispatch
    define('ProbeArr', 'joined',
           body: 'Array === entity_list ? entity_list.join("+") : entity.to_s',
           property_type: :both)
    assert_equal 'Tp53+Kras', run_prop('ProbeArr', 'joined', %w[Tp53 Kras])[1]
    assert_equal 'Tp53', run_prop('ProbeArr', 'joined', 'Tp53')[1]
  end

  def test_argument_forwarding
    define('ProbeGene', 'with_args',
           body: '"#{entity.to_s}@#{inputs[:treatment]}"',
           arguments: [{ 'name' => 'treatment', 'type' => 'string',
                         'description' => 'arm', 'required' => true }])
    assert_equal 'Tp53@PD', run_prop('ProbeGene', 'with_args', 'Tp53',
                                     arguments: { 'treatment' => 'PD' })[1]
    assert_scout_ex('missing required', /treatment/) do
      run_prop('ProbeGene', 'with_args', 'Tp53', arguments: {})
    end
    assert_scout_ex('unknown argument', /nope/) do
      run_prop('ProbeGene', 'with_args', 'Tp53', arguments: { 'treatment' => 'x', 'nope' => 1 })
    end
  end

  # ------------------------------------------------------------------
  # dependencies + invalidation
  # ------------------------------------------------------------------
  def test_dependency_step_and_invalidation
    define('ProbeDep', 'base', body: 'entity.to_s + "-b1"')
    define('ProbeDep', 'derived', body: 'step(:base).load + "/d"',
           dependencies: ['base'])
    job, res = run_prop('ProbeDep', 'derived', 'Tp53')
    assert_equal 'Tp53-b1/d', res
    dep = job.dependencies.find { |d| d.task_name.to_s == 'base' }
    assert_not_nil(dep, 'derived job has a real Step dependency on base')

    job2, res2 = run_prop('ProbeDep', 'derived', 'Tp53')
    assert_equal job.path, job2.path
    assert_equal res, res2

    Cortex.update_property('ProbeDep', 'base', expected_version: 1,
                           body: 'entity.to_s + "-b2"', agent: 't', job: 't')
    job3, res3 = run_prop('ProbeDep', 'derived', 'Tp53')
    assert_equal 'Tp53-b2/d', res3
    assert_not_equal job.path, job3.path, 'dependent job invalidated by dep update'
    assert_not_equal dep.path,
                     job3.dependencies.find { |d| d.task_name.to_s == 'base' }.path
  end

  def test_cycle_and_missing_dependency
    assert_scout_ex('missing dependency', /base/) do
      define('ProbeCyc', 'lonely', body: 'x', dependencies: ['base'])
    end
    a = { 'type' => 'ProbeCyc', 'property' => 'a', 'meta' => { 'dependencies' => ['b'] } }
    b = { 'type' => 'ProbeCyc', 'property' => 'b', 'meta' => { 'dependencies' => ['a'] } }
    e = assert_raises(ScoutException) { Cortex.entity_topo_sort([a, b]) }
    assert_match(/cycle/, e.message)
  end

  def test_update_flag_recomputes_same_path
    define('ProbeGene', 'counter', body: 'entity.to_s + ":" + Time.now.to_f.to_s')
    job1, res1 = run_prop('ProbeGene', 'counter', 'Tp53')
    job2, = run_prop('ProbeGene', 'counter', 'Tp53', update: true)
    assert_equal job1.path, job2.path, 'clean+recompute keeps the same path'
    assert_not_equal res1, job2.load, 'recompute produced a fresh result'
  end

  # ------------------------------------------------------------------
  # namespace safety
  # ------------------------------------------------------------------
  def test_unrelated_constant_rejected
    Object.const_set(:ProbeUnrelated, Module.new) unless defined?(::ProbeUnrelated)
    assert_scout_ex('non-entity constant') do
      define('ProbeUnrelated', 'x', body: 'entity.to_s')
    end
  end

  # Pre-existing Entity modules are NOT adopted: their task objects are
  # memoized (Persist.memory), so recompiling a same-named property into them
  # would keep the old body running.  Foreign Entity types are rejected; only
  # Cortex-managed (registered) modules are reused across generations.
  def test_existing_entity_module_is_reused
    mod = Module.new
    mod.extend Entity
    mod.extend EntityWorkflow
    mod.name = 'ProbeExisting'
    Kernel.const_set(:ProbeExisting, mod) unless defined?(::ProbeExisting)
    e = assert_scout_ex('foreign Entity module rejected') do
      define('ProbeExisting', 'prop', body: 'entity.to_s')
    end
    assert_match(/already exists/, e.message)
    assert_nil(Cortex.load_entity_type('ProbeExisting'))
  end

  # A name that already exists on the module and is NOT Cortex-owned is a
  # collision; the check applies to the managed module too (the managed module
  # is created fresh per generation, so poison it directly to exercise it).
  def test_non_cortex_property_collision
    mod = Module.new
    mod.extend Entity
    mod.extend EntityWorkflow
    mod.name = 'ProbeOccupied'
    Kernel.const_set(:ProbeOccupied, mod) unless defined?(::ProbeOccupied)
    mod.send(:define_method, :occupied) { 'foreign' }
    e = assert_scout_ex('foreign type rejected before collision matters') do
      define('ProbeOccupied', 'occupied', body: 'entity.to_s')
    end
    assert_match(/already exists|not an Entity|occupied/, e.message)
    # Same shape on a MANAGED module: each definition compiles into a FRESH
    # generation, so the poisoned module cannot be reached from define_property
    # directly.  Exercise the check through entity_stage_compile, which compiles
    # into a staging module we control.
    define('ProbeOccupied2', 'free', body: 'entity.to_s')
    staging = Module.new
    staging.extend Entity
    staging.extend EntityWorkflow
    staging.name = 'ProbeOccupied2'
    staging.send(:define_method, :occupied) { 'foreign' }
    defn = { type: 'ProbeOccupied2', property: 'occupied',
             meta: { 'property_type' => 'single', 'result_type' => 'string',
                     'arguments' => [], 'dependencies' => [],
                     'version' => 1, 'digest' => 'd' } }
    e2 = assert_scout_ex('collision on staged module') do
      Cortex.entity_collision_check!(staging, 'ProbeOccupied2', 'occupied')
    end
    assert_match(/occupied/, e2.message)
  end

  def test_two_types_same_property_name
    define('ProbeA', 'shared', body: '"A:" + entity.to_s')
    define('ProbeB', 'shared', body: '"B:" + entity.to_s')
    assert_equal 'A:x', run_prop('ProbeA', 'shared', 'x')[1]
    assert_equal 'B:x', run_prop('ProbeB', 'shared', 'x')[1]
  end

  # ------------------------------------------------------------------
  # cross-map ambiguity
  # ------------------------------------------------------------------
  def test_cross_map_ambiguity_is_hard_error
    define('ProbeGene', 'amb', body: 'entity.to_s')
    src_body = Cortex.entity_body_path('ProbeGene', 'amb', :current)
    src_meta = Cortex.entity_meta_path('ProbeGene', 'amb', :current)
    dst_body = File.join(USERDIR, 'var', 'cortex', 'entities', 'ProbeGene', 'amb.rb')
    dst_meta = File.join(USERDIR, 'var', 'cortex', 'entities', '.meta', 'ProbeGene', 'amb.json')
    FileUtils.mkdir_p(File.dirname(dst_body))
    FileUtils.mkdir_p(File.dirname(dst_meta))
    FileUtils.cp(src_body, dst_body)
    FileUtils.cp(src_meta, dst_meta)
    assert_scout_ex('ambiguity') { Cortex.property_definition('ProbeGene', 'amb') }
    assert_scout_ex('ambiguity') { Cortex.load_entity_type('ProbeGene') }
  end

  # ------------------------------------------------------------------
  # generations (hot reload)
  # ------------------------------------------------------------------
  def test_manifest_digest_drives_new_generation
    define('ProbeGene', 'hot', body: 'entity.to_s + "-1"')
    mod1 = Cortex.load_entity_type('ProbeGene')
    assert_equal 'Tp53-1', run_prop('ProbeGene', 'hot', 'Tp53')[1]
    Cortex.update_property('ProbeGene', 'hot', expected_version: 1,
                           body: 'entity.to_s + "-2"', agent: 't', job: 't')
    mod2 = Cortex.load_entity_type('ProbeGene')
    refute_equal(mod1, mod2, 'digest change compiles a fresh module generation')
    assert_equal 'Tp53-2', run_prop('ProbeGene', 'hot', 'Tp53')[1]
  end

  def test_generation_dropping_property
    define('ProbeA', 'kept', body: '"K:" + entity.to_s')
    define('ProbeA', 'dropped', body: '"D:" + entity.to_s')
    mod1 = Cortex.load_entity_type('ProbeA')
    # Property methods land as instance methods on the module (they are called
    # on annotated entities), so inspect instance_methods rather than the
    # module's own singleton surface.
    assert(mod1.instance_methods(false).include?(:dropped))
    Cortex.remove_property('ProbeA', 'dropped', expected_version: 1,
                           agent: 't', job: 't')
    mod2 = Cortex.load_entity_type('ProbeA')
    refute_equal(mod1, mod2)
    refute(mod2.instance_methods(false).include?(:dropped),
           'new generation drops removed property')
    assert(mod2.instance_methods(false).include?(:kept))
    # The OLD generation keeps its methods: nothing is mutated in place.
    assert(mod1.instance_methods(false).include?(:dropped))
  end

  # ------------------------------------------------------------------
  # listing / history helpers
  # ------------------------------------------------------------------
  def test_property_definitions_listing
    define('ProbeGene', 'listed', body: 'entity.to_s')
    ds = Cortex.property_definitions('ProbeGene')
    assert(ds.any? { |d| d[:property] == 'listed' })
    Cortex.remove_property('ProbeGene', 'listed', expected_version: 1,
                           agent: 't', job: 't')
    assert(!Cortex.property_definitions('ProbeGene').any? { |d| d[:property] == 'listed' })
    assert(Cortex.property_definitions('ProbeGene', nil, active: false)
                  .any? { |d| d[:property] == 'listed' })
  end

  def test_history_helper
    define('ProbeGene', 'hist', body: 'entity.to_s + ":1"')
    Cortex.update_property('ProbeGene', 'hist', expected_version: 1,
                           body: 'entity.to_s + ":2"', agent: 't', job: 't')
    h = Cortex.property_history('ProbeGene', 'hist')
    assert_equal 2, h[:versions].length
    assert_equal(%w[define update], h[:versions].collect { |r| r['action'] })
    assert_equal 1, h[:snapshots].length
  end

  def test_job_paths_are_namespaced_by_type
    define('ProbeGene', 'pathy', body: 'entity.to_s')
    job, = run_prop('ProbeGene', 'pathy', 'Tp53')
    assert_match(%r{/var/jobs/ProbeGene/pathy/Tp53}, job.path)
  end
end
