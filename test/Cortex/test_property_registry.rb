# Tests for the property-execution registry: recording semantics,
# argument-distinguishable examinations, the properties listing surface,
# AnnotatedArray receivers, and named-list execution through the task.
require_relative 'test_helper'
require 'fileutils'

FileUtils.rm_rf(SCRATCH) if File.directory?(SCRATCH)
[LIBDIR, USERDIR].each { |d| FileUtils.mkdir_p(d) }

Path.path_maps[:current] = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:lib]     = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:user]    = File.join(USERDIR, '{TOPLEVEL}', '{SUBPATH}')
Scout::Config::CACHE['cortex'] = [[['read_maps'], 'lib,current,user'],
                                  [['write_map'], 'current']]
Cortex.instance_variable_set(:@entity_root, Path.setup('var'))
Cortex.configure_cortex!

require_relative File.expand_path('../test_entities', __FILE__)

class TestPropertyRegistry < Test::Unit::TestCase
  include TestEntitiesHelpers

  def setup
    purge!
    (TEST_TYPES + %w[TF]).each do |t|
      [LIBDIR, USERDIR].each do |root|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'properties', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'lists', t))
      end
    end
  end

  def teardown
    setup
  end

  def define_simple_property(property_type: 'single', arguments: [])
    define('TF', 'probe',
           body: "{ base: entity.respond_to?(:entity_classes) ? entity.entity_classes.last.to_s : entity.class.to_s, aa: AnnotatedArray === entity }",
           property_type: property_type, result_type: 'json', arguments: arguments)
  end

  def define_opts(type, property, body:, **rest)
    Cortex.define_property(type, property,
      body: body, description: rest.delete(:description) || 'test',
      property_type: rest.delete(:property_type) || :single,
      result_type: rest.delete(:result_type) || :string,
      arguments: rest.delete(:arguments) || [],
      dependencies: rest.delete(:dependencies) || [],
      entity_options: rest.delete(:entity_options),
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'test_entities')
  end

  def run_prop_opts(entity_type:, property:, entity:, arguments: {}, entity_options: nil)
    job, result = Cortex.run_entity_property(entity_type: entity_type, property: property,
                                             entity: entity, arguments: arguments,
                                             entity_options: entity_options, update: false)
    [job, result]
  end

  def run_prop(entity_type, property, entity, arguments: {}, update: false)
    _job, result = run_prop_opts(entity_type: entity_type, property: property,
                                 entity: entity, arguments: arguments)
    result
  end

  # run_prop returns loaded task values: a Hash for vector (:array/:both)
  # bodies and a JSON String (or Array of them) for fan-out (:single)
  # bodies. Normalize to a single Hash when possible.
  def as_result_hash(result)
    STDERR.puts "PARSE_DBG type=" + result.class.to_s + " val=" + result.inspect[0,120]
    result = JSON.parse(result) if String === result rescue result
    STDERR.puts "PARSE_DBG after=" + result.class.to_s + " val=" + result.inspect[0,120]
    result = result.first if Array === result && result.length == 1
    result
  end

  def test_record_after_execution
    define_simple_property
    job, = run_prop('TF', 'probe', 'FOXO1')
    assert_not_nil job

    names = Cortex.execution_record_names
    assert names.include?('TF/probe/FOXO1'), names.inspect

    record = Cortex.load_execution_record('TF', 'probe', 'FOXO1')
    assert_equal 1, record['examinations'].length
    exam = record['examinations'].first
    assert_equal 1, exam['runs']
    assert_not_nil exam['property_job']
    assert_match(/\ATF\/probe\/FOXO1/, exam['property_job'])
  end

  def test_examinations_distinguished_by_arguments
    define_simple_property(arguments: [{ name: 'treatment', type: 'string', description: 'Treatment', required: true }])
    2.times { run_prop('TF', 'probe', 'FOXO1', arguments: { treatment: 'PD' }) }
    run_prop('TF', 'probe', 'FOXO1', arguments: { treatment: 'PI' })

    record = Cortex.load_execution_record('TF', 'probe', 'FOXO1')
    assert_equal 2, record['examinations'].length
    pd = record['examinations'].find { |e| e['arguments']['treatment'] == 'PD' }
    pi = record['examinations'].find { |e| e['arguments']['treatment'] == 'PI' }
    assert_not_nil pd
    assert_not_nil pi
    assert_equal 2, pd['runs']
    assert_equal 1, pi['runs']
    assert_not_equal pd['property_job'], pi['property_job']
  end

  def test_update_refreshes_same_entry
    define_simple_property(arguments: [{ name: 'treatment', type: 'string', description: 'Treatment', required: true }])
    run_prop('TF', 'probe', 'FOXO1', arguments: { treatment: 'PD' })
    run_prop('TF', 'probe', 'FOXO1', arguments: { treatment: 'PD' }, update: true)

    record = Cortex.load_execution_record('TF', 'probe', 'FOXO1')
    assert_equal 1, record['examinations'].length
    assert_equal 2, record['examinations'].first['runs']
    assert_equal true, record['examinations'].first['forced_update']
  end

  def test_definition_version_tracked_after_update
    define_simple_property
    run_prop('TF', 'probe', 'FOXO1')
    Cortex.update_property('TF', 'probe',

      body: "{ base: entity.respond_to?(:entity_classes) ? entity.entity_classes.last.to_s : entity.class.to_s, aa: AnnotatedArray === entity, v: 2 }",
      description: 'test', expected_version: 1, property_type: :single,
      result_type: :json, agent: 'test', job: 'test_entities')

    run_prop('TF', 'probe', 'FOXO1')

    record = Cortex.load_execution_record('TF', 'probe', 'FOXO1')
    assert_equal 2, record['examinations'].first['definition_version']
  end

  def test_named_list_execution_registers_list_and_members
    define_simple_property
    Cortex.write_list('TF', 'C01', %w[FOXO1 TP53], description: 'test', job: 'test_registry')
    Cortex.run_entity_property(entity_type: 'TF', property: 'probe',
                               entity: %w[FOXO1 TP53], arguments: {},
                               list_name: 'C01')

    names = Cortex.execution_record_names
    assert names.include?('TF/probe/list:TF_C01'), names.inspect
    assert names.include?('TF/probe/FOXO1')
    assert names.include?('TF/probe/TP53')

    list_record = Cortex.load_execution_record('TF', 'probe', 'list:TF_C01')
    assert_equal 'list:TF_C01', list_record['receiver']
    assert_equal 1, list_record['examinations'].length
    assert_equal 'C01', list_record['examinations'].first['list']
  end

  def test_listing_and_read_cover_properties
    assert_not_nil Cortex.list_properties_rows

    define_simple_property
    run_prop('TF', 'probe', 'FOXO1')

    rows = Cortex.list_properties_rows
    assert rows.include?('TF/probe/FOXO1')

    content = Cortex.read_execution_record('TF/probe/FOXO1')
    assert_match(/FOXO1/, content)
    assert_match(/property_job/, content)
  end

  def test_annotated_array_single_dispatch
    define_simple_property(property_type: 'single')
    Cortex.write_list('TF', 'AA1', %w[FOXO1 TP53], description: 'aa', job: 'test_registry')
    _job, result = Cortex.run_entity_property(entity_type: 'TF', property: 'probe',
                                              entity: %w[FOXO1 TP53], arguments: {},
                                              list_name: 'AA1')
    # :single fan-out: one result per member, each executed as an
    # annotated scalar of the entity type.
    assert_equal 2, result.length
    assert(result.all? { |r| r['base'].to_s == 'TF' })
  end

  def test_annotated_array_array_dispatch
    define('TF', 'vector',
           body: "{ aa: AnnotatedArray === entity, base: entity.respond_to?(:entity_classes) ? entity.entity_classes.last.to_s : entity.class.to_s }",
           property_type: 'array', result_type: 'json')
    _job, result = run_prop("TF", "vector", %w[FOXO1 TP53])
    assert_equal true, as_result_hash(result)['aa']
    assert_equal 'TF', as_result_hash(result)['base']
  end

  def test_annotated_array_both_dispatch
    define('TF', 'bothp',
           body: "{ aa: AnnotatedArray === entity, base: entity.respond_to?(:entity_classes) ? entity.entity_classes.last.to_s : entity.class.to_s }",
           property_type: 'both', result_type: 'json')
    _job, result = run_prop('TF', 'bothp', %w[FOXO1 TP53])
    assert_equal true, as_result_hash(result)['aa']
    assert_equal 'TF', as_result_hash(result)['base']
  end

  def test_entity_options_flow_to_setup
    define('TF', 'optsp',
           body: "{ organism: (entity.annotations.last[:organism] rescue nil) }",
           property_type: 'both', result_type: 'json')
    _job, result = run_prop_opts(entity_type: 'TF', property: 'optsp',
                                 entity: %w[FOXO1], arguments: {},
                                 entity_options: { organism: 'Hsa' })
    assert_equal 'Hsa', as_result_hash(result)['organism']
  end
end
