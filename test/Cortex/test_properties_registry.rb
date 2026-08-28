# Registry + annotation + named-list tests for the properties execution
# registry milestone.  Uses the same isolation scheme as test_entities.rb.
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
Cortex.instance_variable_set(:@properties_root, nil) if Cortex.instance_variables.include?(:@properties_root)

class TestCortexPropertiesRegistry < Test::Unit::TestCase
  TYPE = 'ProbeReg'

  def setup
    %w[properties lists].each do |ns|
      [LIBDIR, USERDIR].each do |root|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', ns, TYPE))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', ns, '.meta', TYPE))
      end
    end
    [LIBDIR, USERDIR].each { |r| FileUtils.rm_rf(File.join(r, 'var', 'jobs', TYPE)) }
    [LIBDIR, USERDIR].each { |r| FileUtils.rm_rf(File.join(r, 'var', 'jobs', 'Cortex')) }
    [LIBDIR, USERDIR].each do |root|
      %w[entities .meta .history].each do |sub|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', sub, TYPE))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', sub, TYPE))
      end
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)
  end

  def records_for(property)
    exams = Cortex.all_examinations.select { |e| e['entity_type'] == TYPE && e['property'] == property }
    # The engine flattens record + examination; group back into records keyed
    # by receiver to assert record-level invariants.
    recs = {}
    exams.each do |e|
      recs[e['receiver']] ||= { 'receiver' => e['receiver'], 'entity' => e['entity'], 'list' => e['list'], 'examinations' => [] }
      recs[e['receiver']]['examinations'] << e
      recs[e['receiver']]['runs'] = e['runs']
      recs[e['receiver']]['forced'] = e['forced_update']
    end
    recs.values
  end

  def define_prop(property, body:, property_type: :single, arguments: [])
    Cortex.define_property(TYPE, property,
      body: body, description: 'reg test', property_type: property_type,
      result_type: :string, arguments: arguments, dependencies: [],
      agent: 'test', job: 'test_registry')
  end

  def test_two_arguments_two_examinations
    define_prop('act', body: 'entity.to_s', arguments: [{ name: :treatment, type: :string }])
    run1 = Cortex.run_entity_property(entity_type: TYPE, property: 'act', entity: 'Foxo1',
                                      arguments: { 'treatment' => 'PD' })
    run2 = Cortex.run_entity_property(entity_type: TYPE, property: 'act', entity: 'Foxo1',
                                      arguments: { 'treatment' => 'PI' })
    refute_nil run1
    refute_nil run2

    entries = records_for('act')
    assert_equal 2, entries.length, 'one examination per (entity, property, arguments)'
    rec = entries.first
    assert_equal 'Foxo1', rec['entity']
    assert_equal 2, rec['examinations'].length, 'two examinations, one per treatment'
    treat = rec['examinations'].collect { |e| e.dig('arguments', 'treatment') }.sort
    assert_equal %w[PD PI], treat
    jobs = rec['examinations'].collect { |e| e['property_job'] }
    assert jobs.all? { |j| j && !j.empty? }, 'every examination references its property job'
    assert_equal 2, jobs.uniq.length, 'different arguments => different property jobs'
  end

  def test_rerun_is_idempotent
    define_prop('act', body: 'entity.to_s', arguments: [{ name: :treatment, type: :string }])
    args = { 'treatment' => 'PD' }
    2.times { Cortex.run_entity_property(entity_type: TYPE, property: 'act', entity: 'Foxo1', arguments: args) }
    entries = records_for('act')
    assert_equal 1, entries.length, 're-execution does not duplicate records'
    assert entries.first['runs'] >= 2, 'runs incremented on re-execution'
  end

  def test_update_refreshes_same_entry
    define_prop('act', body: 'entity.to_s', arguments: [{ name: :treatment, type: :string }])
    args = { 'treatment' => 'PD' }
    Cortex.run_entity_property(entity_type: TYPE, property: 'act', entity: 'Foxo1', arguments: args)
    Cortex.run_entity_property(entity_type: TYPE, property: 'act', entity: 'Foxo1', arguments: args, update: true)
    entries = records_for('act')
    assert_equal 1, entries.length, 'forced update refreshes the same record'
    assert_equal true, entries.first['forced'], 'update: true is reflected'
  end

  def test_named_list_execution
    Cortex.write_list(TYPE, 'C01', "Foxo1\nNrf2\n", description: 'probe list')
    define_prop('act', body: 'entity.to_s + "!"', property_type: :single)
    job, _res = Cortex.run_entity_property(entity_type: TYPE, property: 'act',
                                           entity: %w[Foxo1 Nrf2], list_name: 'C01')
    assert_not_nil job

    recs = records_for('act')
    list_rec = recs.find { |r| r['list'] == 'C01' }
    assert_not_nil list_rec, 'the named list execution itself is recorded'
    member_recs = recs.select { |r| r['entity'] && r['list'] == 'C01' }
    assert_equal 2, member_recs.length, 'each list member is recorded with its list reference'
  end

  def test_annotation_reaches_body
    define_prop('kind', body: 'AnnotatedArray === entity_list ? "array" : (Array === entity_list ? "array-plain" : "scalar")',
                property_type: :both)
    _j1, r1 = Cortex.run_entity_property(entity_type: TYPE, property: 'kind', entity: %w[Foxo1 Nrf2])
    assert_equal 'array', r1, ':both list receiver must see an AnnotatedArray'
    _j2, r2 = Cortex.run_entity_property(entity_type: TYPE, property: 'kind', entity: 'Foxo1')
    assert_equal 'scalar', r2
  end

  def test_array_dispatch_annotation
    define_prop('members', body: 'AnnotatedArray === entity_list ? "aa" : "??"', property_type: :array)
    _j, r = Cortex.run_entity_property(entity_type: TYPE, property: 'members', entity: %w[Foxo1 Nrf2])
    assert_equal 'aa', r, ':array dispatch receiver must be an AnnotatedArray'
  end

  def test_single_dispatch_members_annotated
    define_prop('self_annotation', body: 'respond_to?(:annotation_id) ? "annotated" : "plain"', property_type: :single)
    _j, r = Cortex.run_entity_property(entity_type: TYPE, property: 'self_annotation', entity: %w[Foxo1 Nrf2])
    assert_equal %w[annotated annotated], r, ':single fan-out must annotate each member'
  end

  def test_entity_options_reach_body
    define_prop('opt', body: 'respond_to?(:annotation_options) ? annotation_options.inspect : (respond_to?(:options) ? options.inspect : "none")')
    _j, r = Cortex.run_entity_property(entity_type: TYPE, property: 'opt', entity: 'Foxo1',
                                       entity_options: { 'organism' => 'hsa' })
    assert r.to_s.include?('hsa'), "entity_options must reach the body (got #{r.inspect})"
  end
end
