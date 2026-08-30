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

  # run_prop returns loaded task values: a Hash for vector (:array/:both)
  # bodies and a JSON String (or Array of them) for fan-out (:single)
  # bodies. Normalize to a single Hash when possible.
  # Loaded :json task values are Ruby-native Hashes with SYMBOL keys (the
  # body's literal). IndiferentHash.setup makes string access work.
  def as_result_hash(result)
    result = JSON.parse(result) if String === result rescue result
    result = result.first if Array === result && result.length == 1
    result = IndiferentHash.setup(result) if Hash === result
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
    assert rows.any? { |r| r.first == 'TF/probe/FOXO1' }, rows.inspect

    content = Cortex.read_execution_record('TF/probe/FOXO1')
    assert_match(/FOXO1/, content)
    assert_match(/property_job/, content)
  end

  def test_task_level_named_list_without_entity
    define_simple_property(property_type: 'both')
    Cortex.write_list('TF', 'TL1', %w[FOXO1 TP53], job: 'test_registry')

    job = Cortex.job(:cortex_entity_property, 'tl_only',
                     entity_type: 'TF', property: 'probe',
                     list: 'TF/TL1', arguments: '{}')
    job.exec
    receipt = job.load
    receipt = JSON.parse(receipt) if String === receipt

    assert_equal 'TF/TL1', receipt[:entity_list]
    assert_equal 2, receipt[:entity_count]
    assert_equal %w[FOXO1 TP53], Array(receipt[:entity])

    names = Cortex.execution_record_names
    assert names.include?('TF/probe/list:TF_TL1'), names.inspect
    %w[FOXO1 TP53].each do |member|
      assert names.include?("TF/probe/#{member}"), names.inspect
    end
  end

  def test_task_level_inline_array_guidance_note
    define('TF', 'probe5',
           body: 'entity.to_s.length',
           property_type: 'both', result_type: 'integer')

    five = %w[A BB CCC DDDD EEEEE]
    job = Cortex.job(:cortex_entity_property, 'inline5',
                     entity_type: 'TF', property: 'probe5',
                     entity: five.to_json)
    job.exec
    receipt = job.load
    receipt = JSON.parse(receipt) if String === receipt
    receipt = IndiferentHash.setup(receipt.dup)

    # Large inline arrays execute fine but carry the steering note...
    assert receipt.include?(:note), receipt.inspect
    assert_match(/cortex_write_list/, receipt[:note])
    # ...while the provenance contract is unchanged.
    assert_equal 'TF', receipt[:entity_type]
    assert_equal 5, Array(receipt[:entity]).length
    assert receipt.include?(:property_job)
    assert !receipt.include?(:entity_list)

    # Small arrays (3 members or fewer) do not get the note.
    three = %w[A BB CCC]
    job3 = Cortex.job(:cortex_entity_property, 'inline3',
                      entity_type: 'TF', property: 'probe5',
                      entity: three.to_json)
    job3.exec
    r3 = job3.load
    r3 = JSON.parse(r3) if String === r3
    r3 = IndiferentHash.setup(r3.dup)
    assert !r3.include?(:note), r3.inspect
  end

  def test_task_level_named_list_no_note
    define_simple_property(property_type: 'both')
    Cortex.write_list('TF', 'TLG', %w[A BB CCC DDDD EEEEE], job: 'test_registry')

    job = Cortex.job(:cortex_entity_property, 'tl_note',
                     entity_type: 'TF', property: 'probe',
                     list: 'TF/TLG')
    job.exec
    receipt = job.load
    receipt = JSON.parse(receipt) if String === receipt
    receipt = IndiferentHash.setup(receipt.dup)

    # Named lists (even with many members) never carry the inline note.
    assert !receipt.include?(:note), receipt.inspect
    assert_equal 'TF/TLG', receipt[:entity_list]
    assert_equal 5, receipt[:entity_count]
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
    # Fan-out results are per-member values (Hashes after :json load).
    assert(result.all? { |r| IndiferentHash.setup(r.dup)['base'].to_s == 'TF' })
  end

  def test_annotated_array_array_dispatch
    define('TF', 'vector',
           body: "{ aa: AnnotatedArray === entity, base: entity.respond_to?(:entity_classes) ? entity.entity_classes.last.to_s : entity.class.to_s }",
           property_type: 'array', result_type: 'json')
    _job, result = run_prop("TF", "vector", %w[FOXO1 TP53])
    h = as_result_hash(result)
    assert_equal true, h['aa']
    assert_equal 'TF', h['base']
  end

  def test_annotated_array_both_dispatch
    define('TF', 'bothp',
           body: "{ aa: AnnotatedArray === entity, base: entity.respond_to?(:entity_classes) ? entity.entity_classes.last.to_s : entity.class.to_s }",
           property_type: 'both', result_type: 'json')
    _job, result = run_prop('TF', 'bothp', %w[FOXO1 TP53])
    h = as_result_hash(result)
    assert_equal true, h['aa']
    assert_equal 'TF', h['base']
  end

  def test_entity_options_flow_to_setup
    define('TF', 'optsp',
           body: "{ organism: (entity.organism rescue nil) }",
           property_type: 'both', result_type: 'json')
    _job, result = run_prop_opts(entity_type: 'TF', property: 'optsp',
                                 entity: %w[FOXO1], arguments: {},
                                 entity_options: { organism: 'Hsa' })
    assert_equal 'Hsa', as_result_hash(result)['organism']
  end

  # ------------------------------------------------------------------
  # List-mutation invalidation
  # ------------------------------------------------------------------
  # Body is non-deterministic ('Time.now.to_f.to_s'): an identical value
  # means the cached job was reused, a different value means it was
  # recomputed. List mtimes are future-dated so that Path.newer? sees
  # job_path < list_file even on coarse filesystems (equal mtimes are
  # treated as fresh by the scout-gear idiom).

  def run_list_prop(property, list_name)
    _entities, _meta, list_path = Cortex.read_list('TF', list_name)
    members = File.readlines(list_path).map(&:strip).reject(&:empty?)
    job, result = Cortex.run_entity_property(entity_type: 'TF', property: property,
                                             entity: members, arguments: {},
                                             list_name: list_name, update: false)
    [job, result, list_path]
  end

  def touch_future(path)
    File.utime(Time.now + 10, Time.now + 10, path)
  end

  def test_list_mutation_invalidates_single_dispatch
    define('TF', 'clock', body: 'Time.now.to_f.to_s',
           property_type: 'single', result_type: 'string')
    Cortex.write_list('TF', 'MUT1', %w[FOXO1 TP53], job: 'test_registry')

    job1, result1, list_path = run_list_prop('clock', 'MUT1')
    assert_equal 2, result1.length

    File.write(list_path, "FOXO1\nTP53\nMYC\n")
    touch_future(list_path)

    job2, result2, = run_list_prop('clock', 'MUT1')
    assert_equal 3, result2.length
    # Every member was recomputed: none of the new values can equal a
    # value from the cached run (body is Time.now.to_f.to_s).
    assert result2.none? { |v| result1.include?(v) },
           "expected recompute, got cached #{result2.inspect}"
  end

  def test_list_mutation_invalidates_both_dispatch
    define('TF', 'vclock', body: 'Time.now.to_f.to_s',
           property_type: 'both', result_type: 'string')
    Cortex.write_list('TF', 'MUT2', %w[TP53 CDKN1A], job: 'test_registry')

    _job1, result1, list_path = run_list_prop('vclock', 'MUT2')

    File.write(list_path, "TP53\nCDKN1A\nMYC\n")
    touch_future(list_path)

    _job2, result2, = run_list_prop('vclock', 'MUT2')
    assert result2 != result1, 'expected recompute of the vector job'
  end

  def test_untouched_list_keeps_cache
    define('TF', 'clock3', body: 'Time.now.to_f.to_s',
           property_type: 'single', result_type: 'string')
    Cortex.write_list('TF', 'MUT3', %w[FOXO1 TP53], job: 'test_registry')

    job1, result1, = run_list_prop('clock3', 'MUT3')
    job2, result2, = run_list_prop('clock3', 'MUT3')
    assert_equal result1, result2
    # Same jobs, not cleaned/recreated between the two runs.
    paths1 = Array(job1).map(&:path).sort
    paths2 = Array(job2).map(&:path).sort
    assert_equal paths1, paths2
    assert Array(job2).all?(&:done?)
  end

  def test_update_true_still_force_recomputes
    define('TF', 'clock4', body: 'Time.now.to_f.to_s',
           property_type: 'single', result_type: 'string')
    Cortex.write_list('TF', 'MUT4', %w[FOXO1 TP53], job: 'test_registry')

    _j1, result1, = run_list_prop('clock4', 'MUT4')
    _j2, result2, = run_list_prop('clock4', 'MUT4')
    assert_equal result1, result2 # untouched: cached

    members = Cortex.read_list('TF', 'MUT4').first
    _j3, result3, = Cortex.run_entity_property(entity_type: 'TF', property: 'clock4',
                                               entity: members, arguments: {},
                                               list_name: 'MUT4', update: true)
    assert result3 != result2, 'update:true must force recompute'
  end
end
