# ==========================================================================
# Cortex tool tasks (step 4 of the redesign): cortex_property_run,
# cortex_result, rebuilt cortex_property_validate, result_kind rename in
# define/update outputs. The historical cortex_entity_property task was
# RETIRED with the execution registry (step 5); the test below pins that
# it is gone, and legacy 'property_job'/'examinations' spellings appear
# only in the legacy-history readers' fixtures.
#
# ISOLATION: same as the other entity suites (scratch path maps under
# tmp/entity_test_var installed after the workflow loads).
# ==========================================================================
require File.expand_path(__FILE__).sub(%r(/test/Cortex/.*), '/test/Cortex/test_helper.rb')
require 'fileutils'
require 'json'
require 'Cortex/cli'

FileUtils.rm_rf(SCRATCH) if File.directory?(SCRATCH)
[LIBDIR, USERDIR].each { |d| FileUtils.mkdir_p(d) }

Path.path_maps[:current] = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:lib]     = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:user]    = File.join(USERDIR, '{TOPLEVEL}', '{SUBPATH}')
Scout::Config::CACHE['cortex'] = [[['read_maps'], 'lib,current,user'],
                                  [['write_map'], 'current']]
Cortex.instance_variable_set(:@entity_root, Path.setup('var'))

STEP4_TYPES = %w[Step4A Step4B].freeze

module Step4Helpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      STEP4_TYPES.each do |t|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', t))
        FileUtils.rm_rf(File.join(root, 'var', 'jobs', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'lists', t))
      end
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', 'Cortex', 'cortex_property_run'))
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', 'Cortex', 'cortex_result'))
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', 'Cortex', 'cortex_property_validate'))
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
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'step4_tests')
  end

  def run_task(task, name, inputs)
    job = Cortex.job(task, name, inputs)
    job.run
    JSON.parse(Open.read(job.path))
  end

  def assert_32hex_label(label)
    assert_match(/\A[A-Za-z0-9_.:-]+_[0-9a-f]{32}\z/, label, label.inspect)
  end

  def json_message(e)
    JSON.parse(e.message)
  rescue JSON::ParserError
    flunk "exception message is not the structured envelope: #{e.message[0, 200]}"
  end
end

class TestPropertyRunTool < Test::Unit::TestCase
  include Step4Helpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # ------------------------------------------------------------------
  # cortex_property_run (§2.3 / §2.7 through the task)
  # ------------------------------------------------------------------
  def test_run_task_scalar_receipt
    define('Step4A', 'echo', body: '"E:" + entity.to_s')
    r = run_task(:cortex_property_run, 'r1', entity_type: 'Step4A',
                 property: 'echo', entity: 'Tp53')
    assert_equal 'Step4A', r['entity_type']
    assert_equal 'Tp53', r['receiver']
    assert_32hex_label r['address'].split('/').last
    assert_equal 'E:Tp53', r['value']
    assert_equal 'done', r['status']
    assert File.exist?(r['info_path'])
  end

  def test_run_task_fanout_array_and_partial_failure
    define('Step4A', 'risky', body: <<~'RB')
      raise ScoutException if entity.to_s == 'B'
      'ok:' + entity.to_s
    RB
    rs = run_task(:cortex_property_run, 'fan1', entity_type: 'Step4A',
                  property: 'risky', entity: '["A","B","C"]')
    assert Array === rs
    assert_equal 3, rs.length
    assert_equal %w[done error done], rs.collect { |r| r['status'] }
    bad = rs.find { |r| r['receiver'] == 'B' }
    env = bad['error']
    assert env['message_is_bare']
    assert_equal 'definition_error', env['verdict']
    assert_equal 1, bad['failed_members']
    assert_equal 3, bad['total_members']
  end

  def test_run_task_named_list_receiver
    define('Step4A', 'echo', body: '"E:" + entity.to_s')
    Cortex.write_list('Step4A', 'panel', %w[FOXO1 MYC])
    rs = run_task(:cortex_property_run, 'nl1', entity_type: 'Step4A',
                  property: 'echo', list: 'Step4A/panel')
    assert Array === rs
    assert_equal 2, rs.length
    assert_equal %w[FOXO1 MYC], rs.collect { |r| r['receiver'] }
    rs.each { |r| assert_equal 'Step4A/panel', r['entity_list'] }
  end

  def test_run_task_timeout_input_accepted
    define('Step4A', 'fast', body: 'entity.to_s')
    r = run_task(:cortex_property_run, 'to1', entity_type: 'Step4A',
                 property: 'fast', entity: 'X', timeout: 30)
    assert_equal 'done', r['status']
  end

  def test_run_task_writes_no_registry
    define('Step4A', 'echo', body: '"E:" + entity.to_s')
    before = [LIBDIR, USERDIR].flat_map do |root|
      Dir.glob(File.join(root, 'var', 'cortex', 'properties', '**', '*.json'))
    end
    run_task(:cortex_property_run, 'nr1', entity_type: 'Step4A',
             property: 'echo', entity: 'Tp53')
    after = [LIBDIR, USERDIR].flat_map do |root|
      Dir.glob(File.join(root, 'var', 'cortex', 'properties', '**', '*.json'))
    end
    assert_equal before, after, 'the new run path never writes var/cortex/properties'
  end

  # ------------------------------------------------------------------
  # cortex_result (§2.4 through the task)
  # ------------------------------------------------------------------
  TSV_BODY = <<~'RB'.freeze
    TSV.setup("gene\tscore\n" + %w[TP53 KRAS].collect { |g| "#{g}\t#{g.length}" } * "\n",
              :key => 'gene')
  RB

  def test_result_three_projections_over_tsv
    define('Step4A', 'scores', body: TSV_BODY, result_type: 'tsv')
    run = run_task(:cortex_property_run, 'tsv1', entity_type: 'Step4A',
                   property: 'scores', entity: 'arm1')
    addr = run['address']
    assert addr.end_with?('.tsv'), 'typed kind carries the extension'

    v = run_task(:cortex_result, 'v', address: addr, projection: 'value')
    assert_equal addr, v['address']
    assert_equal 'done', v['status']
    assert_equal 'tsv', v['result_kind']
    assert v['value'].include?('TP53')

    p = run_task(:cortex_result, 'p', address: addr, projection: 'path')
    assert_equal addr, p['address']
    assert_equal 'tsv', p['result_kind']
    assert_equal true, p['exists']
    assert p['bytes'] > 0
    # THE PATH STRING is readable as a real TSV file
    tsv = TSV.open(p['path'])
    assert_include tsv.keys, 'TP53'
    assert_include tsv.keys, 'KRAS'

    i = run_task(:cortex_result, 'i', address: addr, projection: 'info')
    assert_equal 'done', i['status']
    info = i['info']
    assert_equal addr, i['address']
    assert info.key?('inputs') || info.key?(:inputs), 'full sidecar returned'
    assert File.exist?(i['info_path'] || addr.sub(%r{\A[^/]*/[^/]*/}, '')
             .then { |rel| File.join(USERDIR, 'var', 'jobs', rel) } + '.info') ||
           info['status'] == 'done'
  end

  def test_result_missing_address_error_envelope
    define('Step4A', 'echo', body: '"E:" + entity.to_s')
    run_task(:cortex_property_run, 'mk1', entity_type: 'Step4A',
             property: 'echo', entity: 'REAL1')
    e = assert_raises(ScoutException) do
      run_task(:cortex_result, 'missing', address: 'Step4A/echo/NOPE_deadbeefdeadbeefdeadbeefdeadbeef')
    end
    env = json_message(e)
    assert_equal 'ParameterException', env['exception_class']
    assert_equal 'argument_error', env['verdict']
    assert_not_empty env['context']['candidates']
  end

  def test_result_recovery_loud_in_tool_output
    define('Step4A', 'echo', body: '"E:" + entity.to_s')
    run = run_task(:cortex_property_run, 'rec1', entity_type: 'Step4A',
                   property: 'echo', entity: 'FOXO1')
    label = run['address'].split('/').last
    mangled = "Step4A/echo/MANGLEDPREFIX_#{label.split('_').last}"
    r = run_task(:cortex_result, 'rec2', address: mangled, projection: 'path')
    assert_equal true, r['recovered'], 'recovery is reported in tool output'
    assert r['recovered_from'].to_s =~ /\A[0-9a-f]{16,32}\z/
    assert_equal run['address'], r['address'], 'canonical address returned'
  end

  # ------------------------------------------------------------------
  # cortex_property_validate (§2.2 rebuilt)
  # ------------------------------------------------------------------
  def test_validate_candidate_valid_with_clean_smoke
    define('Step4B', 'good', body: 'entity.to_s + "-ok"')
    v = run_task(:cortex_property_validate, 'v1', entity_type: 'Step4B',
                 property: 'good', test_entity: 'TP53')
    assert_equal true, v['valid']
    assert v['checks'].any? { |c| c.include?('smoke') }
    assert_empty v['errors']
    assert_equal 'done', v['smoke']['status']
    assert v['smoke']['address'] =~ /good/, 'smoke names its scratch Step'
  end

  def test_validate_bare_raise_pinned_in_smoke_envelope
    define('Step4B', 'angry', body: 'raise ScoutException')
    v = run_task(:cortex_property_validate, 'v2', entity_type: 'Step4B',
                 property: 'angry', test_entity: 'TP53')
    assert_equal false, v['valid']
    smoke = v['smoke']
    assert_equal 'error', smoke['status']
    assert_equal 'ScoutException', smoke['exception_class']
    assert_equal true, smoke['message_is_bare'], 'bare raise is flagged'
    assert_equal 'definition_error', smoke['verdict']
  end

  def test_validate_kind_check_reports_mismatch
    define('Step4B', 'wrongkind', body: 'entity.to_s')
    v = run_task(:cortex_property_validate, 'v3', entity_type: 'Step4B',
                 property: 'wrongkind', body: "'not a float'",
                 result_kind: 'float', test_entity: 'TP53')
    assert_equal false, v['valid']
    assert v['errors'].any? { |e| e.downcase.include?('kind') },
           "kind check reported: #{v['errors'].inspect}"
  end

  def test_validate_never_serves_cached_stale_error
    # a FAILED previous run of a DIFFERENT body must not leak its error text
    # into a later validate of a FIXED body
    define('Step4B', 'flaky', body: 'raise ScoutException, "OLD BROKEN BODY"')
    v_bad = run_task(:cortex_property_validate, 'cs1', entity_type: 'Step4B',
                     property: 'flaky', test_entity: 'TP53')
    assert_equal false, v_bad['valid']

    v_good = run_task(:cortex_property_validate, 'cs2', entity_type: 'Step4B',
                      property: 'flaky', body: 'entity.to_s + "-fixed"',
                      test_entity: 'TP53')
    assert_equal true, v_good['valid'], v_good['errors'].inspect
    assert_equal 'done', v_good['smoke']['status']
    refute(JSON.generate(v_good).include?('OLD BROKEN BODY'),
           'stale error text from the earlier run is gone')
    refute_equal v_bad['smoke']['scratch_root'], v_good['smoke']['scratch_root'],
                 'each smoke runs in a FRESH scratch root (never a cache hit)'
  end

  def test_validate_does_not_mutate_the_store
    define('Step4B', 'stable', body: 'entity.to_s')
    meta_before = File.read(Cortex.entity_meta_path('Step4B', 'stable'))
    body_before = File.read(Cortex.entity_body_path('Step4B', 'stable'))
    v = run_task(:cortex_property_validate, 'mut1', entity_type: 'Step4B',
                 property: 'stable', body: 'entity.to_s + "-candidate"',
                 test_entity: 'TP53')
    assert_equal true, v['valid']
    assert_equal meta_before, File.read(Cortex.entity_meta_path('Step4B', 'stable')),
                 'no .meta change'
    assert_equal body_before, File.read(Cortex.entity_body_path('Step4B', 'stable')),
                 'no body rewrite'
    assert_equal 1, JSON.parse(meta_before)['version'], 'no version bump'
  end

  # ------------------------------------------------------------------
  # define / update (§2.1 contracts + result_kind rename)
  # ------------------------------------------------------------------
  def test_define_receipt_shape
    r = run_task(:cortex_property_define, 'd1', entity_type: 'Step4B',
                 property: 'receipted', body: 'entity.length',
                 description: 't', property_type: 'single',
                 result_kind: 'integer')
    assert_equal 'Step4B/receipted', r['address']
    assert_equal 1, r['version']
    assert r['digest'] =~ /\A[0-9a-f]{64}\z/
    assert_equal 'single', r['property_type']
    assert_equal 'integer', r['result_kind']
    assert_equal 'entities/Step4B/receipted', r['definition_path']
  end

  def test_define_accepts_result_type_loudly
    r = run_task(:cortex_property_define, 'd2', entity_type: 'Step4B',
                 property: 'legacy', body: 'entity.to_s',
                 description: 't', property_type: 'single',
                 result_type: 'float')
    assert_equal 'float', r['result_kind']
    assert r['warnings'].any? { |w| w.include?('deprecated') },
           'old callers get a LOUD deprecation note'
  end

  def test_update_receipt_and_kind
    define('Step4B', 'up', body: 'entity.to_s + "-1"')
    r = run_task(:cortex_property_update, 'u1', entity_type: 'Step4B',
                 property: 'up', expected_version: 1,
                 body: 'entity.to_s + "-2"')
    assert_equal 2, r['version']
    assert_equal 'string', r['result_kind']
    assert r['digest'] =~ /\A[0-9a-f]{64}\z/
  end

  # ------------------------------------------------------------------
  # old run task is GONE (step 5): the surface is cortex_property_run only
  # ------------------------------------------------------------------
  def test_old_run_task_is_gone
    assert_nil Cortex.tasks[:cortex_entity_property],
               'cortex_entity_property was retired with the registry'
    e = assert_raises(TaskNotFound) do
      Cortex.job(:cortex_entity_property, 'alias1',
                 entity_type: 'Step4A', property: 'echo', entity: 'Tp53')
    end
    assert_match(/cortex_entity_property/, e.message)
  end

  # ------------------------------------------------------------------
  # CLI build_inputs for the new tasks (table-driven, mirrors test_cli.rb)
  # ------------------------------------------------------------------
  def test_cli_build_inputs_for_new_tasks
    r = Cortex::CLI.build_inputs('cortex_result',
                                 { 'address' => 'A/B/C_abc', 'projection' => 'path',
                                   'max_bytes' => '7' }, [])
    assert_equal 'A/B/C_abc', r[:address]
    assert_equal 'path', r[:projection]

    pr = Cortex::CLI.build_inputs('cortex_property_run',
                                  { 'entity_type' => 'T', 'property' => 'p',
                                    'entity' => 'X', 'update' => 'true' }, [])
    assert_equal 'T', pr[:entity_type]
    assert_include ['true', true], pr[:update]

    d = Cortex::CLI.build_inputs('cortex_property_define',
                                 { 'entity_type' => 'T', 'property' => 'p',
                                   'body' => 'entity', 'result_kind' => 'tsv',
                                   'property_type' => 'single' }, [])
    assert_equal 'tsv', d[:result_kind]
  end
end
