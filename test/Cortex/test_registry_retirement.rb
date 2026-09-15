# ==========================================================================
# Cortex step 5 of the property subsystem redesign — registry retirement,
# activity rewiring, migration.
#
#   * guard: a full define -> run -> fan-out -> result cycle under the new
#     engine writes NOTHING under var/cortex/properties (both roots);
#   * activity: Step-derived investigations (definition identity + address),
#     older/active marking after a definition update;
#   * activity history: a synthetic legacy record appears as registry_history;
#   * properties-namespace list/read/search over the new evidence source;
#   * migration: the real foreign definition Observation/probe loads and
#     runs under the new engine; foreign store untouched;
#   * old-vs-new path equality: address is a pure function of definition
#     identity + argument set + receiver + deps (fresh module generation
#     recomputes the SAME path, done preserved).
#
# ISOLATION: scratch path maps under tmp/entity_test_var, as every entity
# suite.  The Observation migration tests run WITHOUT the scratch maps (the
# foreign definition lives on the scout_essentials_lib map of the real
# environment) but only ever READ that store.
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

STEP5_TYPES = %w[Step5A Step5B].freeze

module Step5Helpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      STEP5_TYPES.each do |t|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', t))
        FileUtils.rm_rf(File.join(root, 'var', 'jobs', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'lists', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'properties', t))
      end
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)
  end

  def define(type, property, body:, **rest)
    Cortex.define_property(type, property,
      body: body, description: rest.delete(:description) || 'test',
      property_type: rest.delete(:property_type) || :single,
      result_type: rest.delete(:result_type) || rest.delete(:result_kind) || 'string',
      arguments: rest.delete(:arguments) || [],
      dependencies: rest.delete(:dependencies) || [],
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'step5_tests',
      test_entity: rest.delete(:test_entity), test_arguments: rest.delete(:test_arguments))
  end

  def run3(type, property, receiver, arguments: {}, **opts)
    Cortex::Properties.run_property(entity_type: type, property: property,
                                    receiver: receiver, arguments: arguments,
                                    update: opts.delete(:update) || false,
                                    timeout: opts.delete(:timeout))
  end

  def assert_32hex_label(label)
    # Step 3: structured result kinds keep their TYPE_EXTENSIONS suffix in
    # Step#name and therefore in the address (design sec2 vocabulary table:
    # 'address file extension (.tsv, .json, ...) or its absence'). The
    # authoritative content of this assertion -- the 32-hex identity digest
    # in the label -- is unchanged.
    assert_match(/\A[A-Za-z0-9_.:-]+_[0-9a-f]{32}(?:\.[A-Za-z0-9]+)?\z/, label, label.inspect)
  end
end

class TestRegistryRetirement < Test::Unit::TestCase
  include Step5Helpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # ------------------------------------------------------------------
  # The guard: NO code path writes var/cortex/properties anymore
  # ------------------------------------------------------------------
  def test_full_cycle_writes_nothing_under_properties
    define('Step5A', 'risky', body: 'raise ScoutException if entity.to_s == "B"; "ok:" + entity.to_s')
    snapshot = proc do
      [LIBDIR, USERDIR].flat_map do |root|
        Dir.glob(File.join(root, 'var', 'cortex', 'properties', '**', '*'))
      end.sort
    end
    before = snapshot.call

    run3('Step5A', 'risky', 'A')
    run3('Step5A', 'risky', %w[A B C])              # fan-out incl. a failure
    run3('Step5A', 'risky', 'A', update: true)      # forced recompute
    addr = Cortex.step_evidence('Step5A').first['address']
    step = Cortex::Properties.resolve_address(addr)[:step]
    refute_nil step

    assert_equal before, snapshot.call,
                 'define/run/fan-out/result/resolution wrote NOTHING under var/cortex/properties'
  end

  def test_no_registry_writer_methods_remain
    refute Cortex.respond_to?(:record_property_execution),
           'the registry write path is deleted from the engine'
  end

  def test_old_run_task_is_gone
    assert_nil Cortex.tasks[:cortex_entity_property],
               'cortex_entity_property no longer exists as a task'
    assert Cortex.tasks[:cortex_property_run]
  end

  # ------------------------------------------------------------------
  # Activity rewiring: Step-derived current evidence
  # ------------------------------------------------------------------
  def test_activity_investigations_step_derived
    define('Step5B', 'expr', body: '"HIGH"')
    define('Step5B', 'len', body: 'entity.length', result_type: 'integer')
    run3('Step5B', 'expr', 'FOXO1')
    run3('Step5B', 'len', 'FOXO1', arguments: {})

    rep = Cortex.activity_report(entity_type: 'Step5B', entity: 'FOXO1', limit: 10)
    inv = rep['facets'].find { |f| f['facet'] == 'investigations' }
    assert_not_nil inv
    items = inv['items']
    assert_equal 2, items.length
    items.each do |i|
      assert_equal 'step_info', i['source']
      assert_match(%r{\AStep5B/(expr|len)/FOXO1_[0-9a-f]{32}\z}, i['address'])
      assert_equal '1', i['definition_version']
      assert i['definition_digest'] =~ /\A[0-9a-f]{8}\z/
      assert_equal 'active', i['status']
      assert_equal 'done', i['step_status']
      assert_equal({}, i['arguments'])
    end
    expr = items.find { |i| i['property'] == 'expr' }
    assert_match(/Step5B\/expr\/FOXO1_/, expr['address'])
  end

  def test_activity_marks_older_after_definition_update
    define('Step5B', 'clock', body: '"v1"')
    run3('Step5B', 'clock', 'MYC')
    addr_v1 = Cortex.step_evidence('Step5B').find { |e| e['receiver'] == 'MYC' }['address']

    Cortex.update_property('Step5B', 'clock', expected_version: 1,
                           body: '"v2"', agent: 't', job: 't')
    run3('Step5B', 'clock', 'MYC')

    rep = Cortex.activity_report(entity_type: 'Step5B', entity: 'MYC', limit: 10)
    items = rep['facets'].find { |f| f['facet'] == 'investigations' }['items']
    assert_equal 2, items.length, 'both the old and the new evidence appear'
    older = items.find { |i| i['address'] == addr_v1 }
    assert_not_nil older, 'the v1 Step is still reported'
    assert_equal 'older', older['status']
    assert_equal '1', older['definition_version']
    fresh = items.find { |i| i['address'] != addr_v1 }
    assert_equal 'active', fresh['status']
    assert_equal '2', fresh['definition_version']
    assert_not_equal older['definition_digest'], fresh['definition_digest']
  end

  def test_activity_history_from_legacy_record
    define('Step5B', 'legacy', body: 'entity.to_s')
    run3('Step5B', 'legacy', 'NEW1')
    legacy_dir = File.join(LIBDIR, 'var', 'cortex', 'properties', 'Step5B', 'legacy')
    FileUtils.mkdir_p(legacy_dir)
    File.write(File.join(legacy_dir, 'OLDE1.json'), JSON.pretty_generate(
      'entity_type' => 'Step5B', 'property' => 'legacy', 'receiver' => 'OLDE1',
      'entity' => 'OLDE1', 'created' => '2026-01-01T00:00:00Z',
      'examinations' => [{
        'arguments' => { 't' => 'x' }, 'arguments_digest' => 'abc123', 'runs' => 3,
        'first_run' => '2026-01-01T00:00:00Z', 'last_run' => '2026-01-02T00:00:00Z',
        'property_job' => 'Step5B/legacy/OLDE1_00000000000000000000000000000000',
        'definition_version' => 1,
        'definition_digest' => 'cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe'
      }]
    ))

    rep = Cortex.activity_report(entity_type: 'Step5B', entity: 'OLDE1', limit: 10)
    inv = rep['facets'].find { |f| f['facet'] == 'investigations' }
    assert_equal 1, inv['items'].length, 'legacy record surfaces as history'
    item = inv['items'].first
    assert_equal 'registry_history', item['source']
    assert_equal 'legacy', item['property']
    assert_equal 3, item['runs']
    assert_equal 'Step5B/legacy/OLDE1_00000000000000000000000000000000',
                 item['property_job']
    assert_equal 'active', item['status'], 'matches the current active version'
    assert_equal 'cafebabe', item['definition_digest']

    # NEW1's report is unaffected by the legacy record (per-entity filtering)
    rep2 = Cortex.activity_report(entity_type: 'Step5B', entity: 'NEW1', limit: 10)
    items2 = rep2['facets'].find { |f| f['facet'] == 'investigations' }['items']
    assert items2.all? { |i| i['source'] == 'step_info' }
  end

  def test_activity_removed_marking
    define('Step5B', 'gone', body: 'entity.to_s')
    run3('Step5B', 'gone', 'X1')
    Cortex.remove_property('Step5B', 'gone', expected_version: 1, agent: 't', job: 't')
    rep = Cortex.activity_report(entity_type: 'Step5B', entity: 'X1', limit: 10)
    items = rep['facets'].find { |f| f['facet'] == 'investigations' }['items']
    assert_equal 1, items.length
    assert_equal 'removed', items.first['status'],
                 'evidence of a removed definition is a historical fact'
  end

  # ------------------------------------------------------------------
  # Properties-namespace reads over the new source
  # ------------------------------------------------------------------
  def test_list_properties_shows_both_sources
    define('Step5A', 'echo', body: 'entity.to_s')
    run3('Step5A', 'echo', 'TP53')
    legacy_dir = File.join(LIBDIR, 'var', 'cortex', 'properties', 'Step5A', 'echo')
    FileUtils.mkdir_p(legacy_dir)
    File.write(File.join(legacy_dir, 'LEG1.json'), JSON.pretty_generate(
      'entity_type' => 'Step5A', 'property' => 'echo', 'receiver' => 'LEG1',
      'entity' => 'LEG1', 'examinations' => [
        { 'arguments' => {}, 'runs' => 1,
          'first_run' => '2026-01-01T00:00:00Z', 'last_run' => '2026-01-01T00:00:00Z',
          'definition_version' => 1, 'definition_digest' => '0' * 64 }
      ]))

    text = Cortex.job(:cortex_list, 'p1', type: 'properties').run
    assert text.include?('step_info'), 'current evidence rows are tagged'
    assert_match(/Step5A\/echo\/TP53_[0-9a-f]{32}/, text)
    assert text.include?('registry_history'), 'legacy rows are tagged'
    assert text.include?('Step5A/echo/LEG1')
  end

  def test_read_properties_resolves_current_address_first
    define('Step5A', 'echo', body: 'entity.to_s')
    r = run3('Step5A', 'echo', 'TP53')
    label = r[:address].split('/').last
    text = Cortex.job(:cortex_read, 'p2', type: 'properties',
                                        name: "Step5A/echo/#{label}").run
    assert text.include?('step_info')
    assert text.include?('CURRENT')
    assert text.include?(r[:address])
  end

  def test_read_properties_falls_back_to_legacy_record
    legacy_dir = File.join(LIBDIR, 'var', 'cortex', 'properties', 'Step5A', 'echo')
    FileUtils.mkdir_p(legacy_dir)
    File.write(File.join(legacy_dir, 'LEG9.json'), JSON.pretty_generate(
      'entity_type' => 'Step5A', 'property' => 'echo', 'receiver' => 'LEG9',
      'entity' => 'LEG9', 'examinations' => [
        { 'arguments' => {}, 'runs' => 2,
          'first_run' => '2026-01-01T00:00:00Z', 'last_run' => '2026-01-02T00:00:00Z',
          'property_job' => 'Step5A/echo/LEG9_00000000000000000000000000000000',
          'definition_version' => 1, 'definition_digest' => '1' * 64 }
      ]))
    text = Cortex.job(:cortex_read, 'p3', type: 'properties',
                                        name: 'Step5A/echo/LEG9').run
    assert text.include?('registry_history')
    assert text.include?('LEGACY')
    assert text.include?('LEG9_00000000000000000000000000000000')
  end

  def test_search_properties_finds_current_evidence
    define('Step5A', 'echo', body: 'entity.to_s')
    run3('Step5A', 'echo', 'UNIQMARKER1')
    rows = Cortex.search_properties('UNIQMARKER1', 10)
    assert rows.any? { |r| r[1] == 'UNIQMARKER1_0f' || r[3].to_s.include?('UNIQMARKER1') },
           "step evidence found by receiver id: #{rows.inspect}"
  end

  # ------------------------------------------------------------------
  # Migration: the real foreign definition runs under the new engine
  # ------------------------------------------------------------------
  def test_foreign_observation_probe_runs_and_store_untouched
    defn = Cortex.property_definition('Observation', 'probe')
    if defn.nil?
      omit 'Observation/probe not present on this environment maps'
      return
    end
    foreign_meta = defn['meta_path']
    foreign_body = defn['body_path']
    snap = [foreign_meta, foreign_body].collect do |p|
      [File.exist?(p), File.exist?(p) ? File.mtime(p) : nil,
       File.exist?(p) ? File.read(p) : nil]
    end

    r = Cortex::Properties.run_property(entity_type: 'Observation',
                                        property: 'probe',
                                        receiver: 'OBS_TEST_1', arguments: {})
    assert Hash === r
    label = r[:address].split('/').last
    assert_32hex_label label
    assert_match(/\AOBS_TEST_1_/, label)
    info = Step.load(r[:materialized][:path]).info
    inputs = Array(info[:inputs])
    names = Array(info[:input_names])
    digest_idx = names.index('_cortex_definition_digest')
    assert digest_idx, 'definition identity travels in info[:inputs]'
    assert_equal defn['digest'], inputs[digest_idx],
                 'the run is keyed by the foreign definition digest'

    snap.each_with_index do |(ex, mt, content), i|
      path = [foreign_meta, foreign_body][i]
      assert ex, "#{path} existed before"
      assert_equal mt, File.mtime(path), "#{path} mtime unchanged (read-only store)'
      assert_equal content, File.read(path), "#{path} content unchanged"
    end
  end

  # ------------------------------------------------------------------
  # Old-vs-new path equality (§9): address = f(identity, args, receiver, deps)
  # ------------------------------------------------------------------
  def test_address_is_pure_function_of_identity_and_inputs
    define('Step5B', 'scored', body: 'entity.to_s',
           arguments: [{ 'name' => 't', 'type' => 'string',
                         'description' => '', 'required' => false,
                         'default' => 'none' }])
    first = run3('Step5B', 'scored', 'TP53', arguments: { 't' => 'DMBA' })
    addr1 = first[:address]
    path1 = first[:materialized][:path]
    mtime1 = File.mtime(path1)
    info1 = Step.load(path1).info

    # Fresh module generation with IDENTICAL inputs must land on the SAME
    # path with the done state preserved (no recompute).
    Cortex.managed_entity_registry.clear
    mod = Cortex.load_entity_type('Step5B')
    refute_nil mod
    args = { 't' => 'DMBA' }.merge(Cortex.entity_identity_inputs('Step5B', 'scored'))
    job = mod.job(:scored, 'TP53', args)
    assert_equal path1, job.path.to_s,
                 'address recomputed identically across module generations'
    assert job.done?, 'done status preserved (no recompute)'
    assert_equal mtime1, File.mtime(path1)
    assert_equal info1[:inputs], job.info[:inputs]

    # A different argument set must move the address
    other = mod.job(:scored, 'TP53',
                    { 't' => 'TPA' }.merge(Cortex.entity_identity_inputs('Step5B', 'scored')))
    assert_not_equal path1, other.path.to_s
  end
end
