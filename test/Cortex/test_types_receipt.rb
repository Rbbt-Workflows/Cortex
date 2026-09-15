# ==========================================================================
# Cortex::Types + Cortex::Receipt + §3 addressing rules (design step 2)
# --------------------------------------------------------------------------
# ISOLATION: identical to test_entities.rb — scratch path maps under
# tmp/entity_test_var are installed AFTER the workflow loads (see
# test/Cortex/test_helper.rb), so job dirs land in scratch and no test
# touches the real ~/.scout/var/jobs.
#
# These are module-level tests (Types/Properties/Receipt), not tool tests;
# the tool surface is rewired in a later step.
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

STEP2_TYPES = %w[Step2A Step2Dep Step2Arr].freeze

module Step2Helpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      STEP2_TYPES.each do |t|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', t))
        FileUtils.rm_rf(File.join(root, 'var', 'jobs', t))
      end
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)
  end

  def define(type, property, body:, **rest)
    Cortex.define_property(type, property,
      body: body, description: rest.delete(:description) || 'test',
      property_type: rest.delete(:property_type) || :single,
      result_type: rest.delete(:result_type) || 'string',
      arguments: rest.delete(:arguments) || [],
      dependencies: rest.delete(:dependencies) || [],
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'step2_tests',
      test_entity: rest.delete(:test_entity), test_arguments: rest.delete(:test_arguments))
  end

  def build_job(type, property, entity, arguments = {})
    job, = Array(Cortex::Properties.build_steps(type, property, entity, arguments))
    job
  end

  def assert_32hex(label, text)
    assert_match(/\A[A-Za-z0-9_.:-]+_[0-9a-f]{32}\z/, text.to_s,
                 "#{label}: expected <id>_<32 hex md5>, got #{text.inspect}")
  end
end

class TestCortexTypes < Test::Unit::TestCase
  include Step2Helpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # §3 rule 1: distinct argument sets -> distinct addresses (probe_u2c).
  def test_distinct_arguments_distinct_addresses
    define('Step2A', 'echo', body: '"E:" + entity.to_s',
           arguments: [{ 'name' => 'arm', 'type' => 'string',
                         'description' => 'a', 'required' => false,
                         'default' => 'none' }])
    a = build_job('Step2A', 'echo', 'Tp53', 'arm' => 'DMBA')
    b = build_job('Step2A', 'echo', 'Tp53', 'arm' => 'PD')
    assert_32hex('job a', a.name)
    assert_32hex('job b', b.name)
    assert_not_equal a.path, b.path
    assert_match(/\ATp53_/, a.name, 'entity id is the readable prefix')
  end

  # §3 rule 2: provided-argument Hash order irrelevant -> same address
  # (probe_u2c reordered args).
  def test_argument_order_irrelevant
    define('Step2A', 'two', body: '"#{entity}:#{inputs[:x]}#{inputs[:y]}"',
           arguments: [{ 'name' => 'x', 'type' => 'integer',
                         'description' => '', 'required' => false, 'default' => 0 },
                       { 'name' => 'y', 'type' => 'integer',
                         'description' => '', 'required' => false, 'default' => 0 }])
    first  = build_job('Step2A', 'two', 'Tp53', 'y' => 2, 'x' => 1)
    second = build_job('Step2A', 'two', 'Tp53', 'x' => 1, 'y' => 2)
    assert_equal first.path, second.path
  end

  # §3 rule 3: identity inputs ALWAYS force the hash — a single-entity run
  # is labeled <id>_<md5>, never the clean <id>.  Pins mechanism U4(a)
  # (pre-redesign entities.rb:492-510) so it can never regress.
  def test_identity_inputs_always_force_hash
    define('Step2A', 'plain', body: 'entity.to_s')
    job = build_job('Step2A', 'plain', 'Tp53')
    assert_32hex('no-arg single run', job.name)
    assert_equal 'Tp53', job.name.split('_').first
    # and it is the identity inputs that do it: the job's provided inputs
    # always include the three _cortex_definition* values.
    task = Cortex.load_entity_type('Step2A').tasks[:plain]
    names = Array(task.inputs).collect { |i| (Array === i ? i.first : i).to_s }
    assert_include names, '_cortex_definition'
    assert_include names, '_cortex_definition_version'
    assert_include names, '_cortex_definition_digest'
    identity = names.select { |n| n.start_with?('_cortex_') }
    assert_equal 3, identity.length
    declared_defaults = Array(task.inputs).select do |i|
      (Array === i ? i.first.to_s : i.to_s).start_with?('_cortex_')
    end
    assert declared_defaults.all? { |i| i.length <= 3 },
           'identity inputs are declared defaultless (no default slot)'
  end

  # §3 rule 3 (second half): definition change moves the address.
  def test_definition_change_moves_address
    define('Step2A', 'moving', body: 'entity.to_s + "-v1"')
    before = build_job('Step2A', 'moving', 'Tp53')
    Cortex.update_property('Step2A', 'moving', expected_version: 1,
                           body: 'entity.to_s + "-v2"', agent: 't', job: 't')
    after = build_job('Step2A', 'moving', 'Tp53')
    assert_not_equal before.path, after.path,
                     'definition change must move the address'
  end

  # §3 rule 4: :single fan-out over a list — per-member labels <member>_<md5>,
  # pairwise distinct, member id as readable prefix (probe_rule5).
  def test_single_fanout_per_member_labels
    define('Step2A', 'echo', body: '"E:" + entity.to_s')
    jobs = Array(Cortex::Properties.build_steps('Step2A', 'echo', %w[FOXO1 MYC TP53]))
    assert_equal 3, jobs.length
    jobs.each do |job|
      assert_32hex('fan-out member', job.name)
      assert_include %w[FOXO1 MYC TP53], job.name.split('_').first
    end
    paths = jobs.collect(&:path)
    assert_equal paths.length, paths.uniq.length, 'fan-out members pairwise distinct'
    assert_equal %w[FOXO1 MYC TP53], jobs.collect { |j| j.name.split('_').first }
  end

  # §3 rule 5: dependency address recurses into the downstream digest.
  # Upstream moves -> downstream moves; the downstream .info[:dependencies]
  # records the upstream address (probe_u2c greet_len/table_len, probe_u3b).
  def test_dependency_recursion_into_downstream_digest
    define('Step2Dep', 'base', body: 'entity.to_s + "-b1"')
    define('Step2Dep', 'derived',
           body: 'step(:base).load + "/d"', dependencies: ['base'])

    down1 = build_job('Step2Dep', 'derived', 'Tp53')
    down1.run
    dep_paths = Array(down1.info[:dependencies])
    assert_equal 1, dep_paths.length
    assert_match(%r{var/jobs/Step2Dep/base/Tp53_[0-9a-f]{32}}, dep_paths.first.to_s,
                 'upstream address recorded in downstream .info[:dependencies]')
    assert_32hex('upstream dep label', File.basename(dep_paths.first.to_s))
    assert_not_equal down1.path, dep_paths.first.to_s

    # update the upstream definition -> its address moves -> downstream moves
    up_before = dep_paths.first.to_s
    Cortex.update_property('Step2Dep', 'base', expected_version: 1,
                           body: 'entity.to_s + "-b2"', agent: 't', job: 't')
    down2 = build_job('Step2Dep', 'derived', 'Tp53')
    assert_not_equal down1.path, down2.path,
                     'upstream definition change must move the downstream address'

    down2.run
    dep_paths2 = Array(down2.info[:dependencies])
    assert_not_equal up_before, dep_paths2.first.to_s,
                     'upstream address recorded in the new downstream run differs'
    assert_equal 'Tp53-b2/d', down2.load
  end

  # §3 rule 6 (step 3 update, design §11.4): an anonymous module named
  # exactly <Type> roots jobs at var/jobs/<Type>/ under the CHECKOUT
  # jobs root (LIBDIR-anchored, CWD-independent), never under the Cortex
  # workflow dir.  The address grammar assertion is authoritative.
  def test_anonymous_module_roots_jobs_at_var_jobs_type
    define('Step2A', 'plain', body: 'entity.to_s')
    mod = Cortex.load_entity_type('Step2A')
    assert_equal 'Step2A', mod.name
    job = build_job('Step2A', 'plain', 'Tp53')
    job.run
    assert_match(%r{#{LIBDIR}/var/jobs/Step2A/plain/}, job.path.find.to_s)
    refute File.exist?(File.join(USERDIR, 'var', 'jobs', 'Cortex', 'plain')),
           'jobs are NOT rooted under the Cortex workflow dir'
  end

  # ------------------------------------------------------------------
  # Cortex::Types unit level
  # ------------------------------------------------------------------
  def test_types_for_returns_fresh_anonymous_module_named_type
    first  = Cortex::Types.for('Step2A')
    second = Cortex::Types.for('Step2A')
    assert_equal 'Step2A', first.name
    assert_equal 'Step2A', second.name
    assert_not_same first, second, 'each compile pass needs a fresh generation'
    # helpers live in the step_module (the exec context), not on the module
    assert first.helpers.key?(:entity) && first.helpers.key?(:entity_list),
           'EntityWorkflow helpers installed'
  end

  def test_types_definition_inputs_order
    defn = { type: 'Step2A', property: 'probe_inputs', meta: {
      'arguments' => [
        { 'name' => 'treatment', 'type' => 'string', 'description' => 'arm',
          'required' => true },
        { 'name' => 'n', 'type' => 'integer', 'description' => 'count',
          'required' => false, 'default' => 10 }
      ]
    } }
    decls = Cortex::Types.definition_inputs(defn)
    names = decls.collect { |d| d[:name] }
    assert_equal %i[treatment n _cortex_definition
                    _cortex_definition_version _cortex_definition_digest], names,
                 'author arguments first, then the three identity inputs'
    assert_equal({ required: true }, decls.first[:options])
    assert_equal 10, decls[1][:default]
    identity = decls.last(3)
    assert(identity.none? { |d| d.key?(:default) || d.key?(:options) },
           'identity inputs carry no default and no options')
  end

  def test_types_register_declares_task_in_order
    define('Step2A', 'reg', body: '"#{entity}@#{inputs[:arm]}"',
           arguments: [{ 'name' => 'arm', 'type' => 'string',
                         'description' => 'a', 'required' => true }])
    defn = Cortex.entity_manifest('Step2A').find { |d| d[:property] == 'reg' }
    mod = Cortex::Types.for('Step2A')
    identities = {}
    identities[:reg] = { _cortex_definition: 'Step2A/reg',
                         _cortex_definition_version: defn[:meta]['version'],
                         _cortex_definition_digest: defn[:meta]['digest'] }
    Cortex::Types.register(mod, defn, identities)

    task = mod.tasks[:reg]
    assert_not_nil task
    names = Array(task.inputs).collect { |i| (Array === i ? i.first : i).to_s }
    assert_equal %w[arm _cortex_definition _cortex_definition_version
                    _cortex_definition_digest], names.first(4)

    # the registered property runs through mod.job with identity pinned
    job = mod.job(:reg, 'Tp53', arm: 'PD',
                             _cortex_definition: 'Step2A/reg',
                             _cortex_definition_version: defn[:meta]['version'],
                             _cortex_definition_digest: defn[:meta]['digest'])
    job.run
    assert_equal 'Tp53@PD', job.load
    assert_match(%r{var/jobs/Step2A/reg/Tp53_[0-9a-f]{32}}, job.path)
  end

  # ------------------------------------------------------------------
  # Cortex::Receipt unit level (with a real Step)
  # ------------------------------------------------------------------
  def test_receipt_build_envelope_from_real_step
    define('Step2A', 'receipted', body: 'entity.to_s + "!"',
           arguments: [{ 'name' => 'arm', 'type' => 'string',
                         'description' => 'a', 'required' => false,
                         'default' => 'none' }])
    job = build_job('Step2A', 'receipted', 'Tp53', 'arm' => 'PD')
    job.run
    defn = Cortex.entity_manifest('Step2A').find { |d| d[:property] == 'receipted' }

    env = Cortex::Receipt.build(entity_type: 'Step2A', property: 'receipted',
                                receiver: 'Tp53',
                                arguments: { 'arm' => 'PD' }, defn: defn[:meta],
                                step: job)
    assert_equal 'Step2A', env[:entity_type]
    assert_equal 'receipted', env[:property]
    assert_equal 'Tp53', env[:receiver]
    assert_equal({ 'arm' => 'PD' }, env[:arguments])
    assert_equal 1, env[:definition][:version]
    assert_equal defn[:meta]['digest'], env[:definition][:digest]
    assert_equal "Step2A/receipted/#{job.name}", env[:address]
    assert_equal 'string', env[:result_kind]
    assert_equal :done, env[:status]
    assert_equal 'Tp53!', env[:value]
    assert_equal job.path, env[:materialized][:path]
    assert_equal File.size(job.path), env[:materialized][:bytes]
    assert_equal job.info_file, env[:info_path]
    assert File.exist?(env[:info_path]), 'info sidecar materialized by the run'
  end

  def test_receipt_build_bounded_value
    define('Step2A', 'big', body: '"x" * 5000')
    job = build_job('Step2A', 'big', 'Tp53')
    job.run
    defn = Cortex.entity_manifest('Step2A').find { |d| d[:property] == 'big' }
    env = Cortex::Receipt.build(entity_type: 'Step2A', property: 'big',
                                receiver: 'Tp53', arguments: {}, defn: defn[:meta],
                                step: job, value_bound: 100)
    assert env[:value].bytesize < 100 + 40, 'bounded copy stays bounded'
    assert_match(/truncated/, env[:value])
    assert_equal 5000, env[:materialized][:bytes], 'authoritative byte size recorded'
  end

  def test_receipt_build_list_receiver_and_fanout
    define('Step2A', 'echo', body: '"E:" + entity.to_s')
    jobs = Array(Cortex::Properties.build_steps('Step2A', 'echo', %w[A B]))
    jobs.each(&:run)
    defn = Cortex.entity_manifest('Step2A').find { |d| d[:property] == 'echo' }
    env = Cortex::Receipt.build(entity_type: 'Step2A', property: 'echo',
                                receiver: { list: 'Step2A/duo', members: 2 },
                                arguments: {}, defn: defn[:meta], step: jobs.first)
    assert_equal({ list: 'Step2A/duo', members: 2 }, env[:receiver])
    assert_equal "Step2A/echo/#{jobs.first.name}", env[:address]
    assert_equal 'E:A', env[:value]
  end
end
