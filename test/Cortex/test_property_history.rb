# ==========================================================================
# Definition-store semantics + legacy-record history reads.
#
# This suite REPLACES the retired test_property_registry.rb (its subject —
# the registry WRITE path — was removed in redesign step 5).  Coverage was
# re-homed, not deleted:
#
#   * define/update/version/history/digest semantics  -> here + test_entities.rb
#     (test_entities.rb already carried lifecycle/versioning/history since
#     the original suite split; those cases were duplicated only through the
#     old run path and are not reproduced here)
#   * legacy records as HISTORY (read as-is, tagged registry_history)   -> here
#   * list-mutation staleness + update:true recompute under the NEW engine
#     (Cortex::Properties.run_property)                                  -> here
#   * dispatch shapes (annotated single/array/both), entity_options flow,
#     task-level list handling                                            -> already
#     covered by test_properties_run.rb + test_property_tools.rb (the new
#     engine path); nothing further carried over
#
# ISOLATION: scratch path maps under tmp/entity_test_var, as every entity
# suite.
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
Cortex.configure_cortex!

HIST_TYPES = %w[HistTF HistA HistB].freeze

module HistoryHelpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      HIST_TYPES.each do |t|
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
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'history_tests',
      test_entity: rest.delete(:test_entity), test_arguments: rest.delete(:test_arguments))
  end

  def write_legacy_record(type, property, receiver, examinations)
    dir = File.join(LIBDIR, 'var', 'cortex', 'properties', type, property)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{receiver}.json"), JSON.pretty_generate(
      'entity_type' => type, 'property' => property, 'receiver' => receiver,
      'entity' => receiver.start_with?('list:') ? nil : receiver,
      'created' => '2026-01-01T00:00:00Z',
      'examinations' => examinations))
    File.join(dir, "#{receiver}.json")
  end
end

class TestPropertyHistory < Test::Unit::TestCase
  include HistoryHelpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # ------------------------------------------------------------------
  # Definition-store semantics (re-homed from the registry suite)
  # ------------------------------------------------------------------
  def test_define_update_digest_moves_and_history_grows
    define('HistA', 'tracked', body: 'entity.to_s + "-1"')
    d1 = Cortex.property_definition('HistA', 'tracked')
    assert_equal 1, d1['version']
    assert d1['digest'] =~ /\A[0-9a-f]{64}\z/

    e = assert_raises(ScoutException) do
      Cortex.update_property('HistA', 'tracked', expected_version: 9,
                             body: 'x', agent: 't', job: 't')
    end
    assert_match(/Version mismatch/, e.message)

    Cortex.update_property('HistA', 'tracked', expected_version: 1,
                           body: 'entity.to_s + "-2"', agent: 't', job: 't')
    d2 = Cortex.property_definition('HistA', 'tracked')
    assert_equal 2, d2['version']
    assert_not_equal d1['digest'], d2['digest'], 'body change moves the digest'
    assert_equal 2, d2['versions'].length
    assert_equal 1, Dir[File.join(Cortex.entity_history_dir('HistA', 'tracked'), '*.rb')].length
  end

  def test_description_only_update_keeps_digest
    define('HistA', 'docd', body: 'entity.to_s')
    d1 = Cortex.property_definition('HistA', 'docd')
    Cortex.update_property('HistA', 'docd', expected_version: 1,
                           description: 'new words', agent: 't', job: 't')
    d2 = Cortex.property_definition('HistA', 'docd')
    assert_equal d1['digest'], d2['digest'], 'documentation edits must not invalidate caches'
    assert_equal 'new words', d2['description']
    assert_equal 2, d2['version']
  end

  def test_remove_tombstones_and_preserves_history
    define('HistA', 'gone', body: 'entity.to_s')
    Cortex.remove_property('HistA', 'gone', expected_version: 1, agent: 't', job: 't')
    d = Cortex.property_definition('HistA', 'gone')
    assert_equal false, d['active']
    assert_equal true, d['removed']
    assert !File.exist?(Cortex.entity_body_path('HistA', 'gone'))
    assert_equal 1, Dir[File.join(Cortex.entity_history_dir('HistA', 'gone'), '*.rb')].length
    r = define('HistA', 'gone', body: 'entity.to_s + "-again"')
    assert_equal 1, r[:version], 'redefine after removal restarts at v1'
  end

  # ------------------------------------------------------------------
  # Legacy records as HISTORY (read as-is, never written)
  # ------------------------------------------------------------------
  def test_legacy_records_readable_as_is
    path = write_legacy_record('HistB', 'probe', 'FOXO1', [
      { 'arguments' => { 't' => 'x' }, 'arguments_digest' => 'aaa', 'runs' => 2,
        'first_run' => '2026-01-01T00:00:00Z', 'last_run' => '2026-01-02T00:00:00Z',
        'property_job' => 'HistB/probe/FOXO1_00000000000000000000000000000000',
        'definition_version' => 1,
        'definition_digest' => 'dd' * 32 }
    ])
    rec = Cortex.load_execution_record('HistB', 'probe', 'FOXO1')
    assert_not_nil rec
    assert_equal 'FOXO1', rec['receiver']
    assert_equal 1, rec['examinations'].length
    assert_equal 2, rec['examinations'].first['runs']

    all = Cortex.all_examinations
    mine = all.find { |e| e['receiver'] == 'FOXO1' && e['property'] == 'probe' }
    assert_not_nil mine
    assert_equal 'registry_history', mine['source']
    assert_equal path, write_legacy_record('HistB', 'probe', 'FOXO1', rec['examinations']),
                 'records are never modified by the reader'
  end

  def test_legacy_list_receiver_records_keep_list_label
    write_legacy_record('HistB', 'probe', 'list:HistB_C01', [
      { 'arguments' => {}, 'arguments_digest' => 'bbb', 'runs' => 1,
        'first_run' => '2026-01-01T00:00:00Z', 'last_run' => '2026-01-01T00:00:00Z',
        'property_job' => 'HistB/probe/Default_00000000000000000000000000000000',
        'definition_version' => 1, 'definition_digest' => 'ee' * 32,
        'list' => 'C01' }
    ])
    entry = Cortex.all_examinations.find { |e| e['receiver'] == 'list:HistB_C01' }
    assert_not_nil entry
    assert_equal 'C01', entry['list']
    assert_nil entry['entity']
  end

  def test_new_engine_never_touches_legacy_records
    path = write_legacy_record('HistB', 'stable', 'KEEP', [
      { 'arguments' => {}, 'arguments_digest' => 'ccc', 'runs' => 1,
        'first_run' => '2026-01-01T00:00:00Z', 'last_run' => '2026-01-01T00:00:00Z',
        'property_job' => 'HistB/stable/KEEP_00000000000000000000000000000000',
        'definition_version' => 1, 'definition_digest' => 'ff' * 32 }
    ])
    before = File.read(path)
    define('HistB', 'stable', body: 'entity.to_s')
    Cortex::Properties.run_property(entity_type: 'HistB', property: 'stable',
                                    receiver: 'KEEP', arguments: {})
    Cortex::Properties.run_property(entity_type: 'HistB', property: 'stable',
                                    receiver: 'KEEP', arguments: {}, update: true)
    assert_equal before, File.read(path), 'runs never rewrite legacy records'
  end

  # ------------------------------------------------------------------
  # List-mutation staleness under the NEW engine (re-homed semantics)
  # ------------------------------------------------------------------
  def run_new(type, property, receiver, arguments: {}, **opts)
    Cortex::Properties.run_property(entity_type: type, property: property,
                                    receiver: receiver, arguments: arguments,
                                    update: opts.delete(:update) || false)
  end

  def touch_future(path)
    File.utime(Time.now + 10, Time.now + 10, path)
  end

  def test_list_mutation_invalidates_fanout_under_new_engine
    define('HistTF', 'clock', body: 'Time.now.to_f.to_s')
    Cortex.write_list('HistTF', 'MUT1', %w[FOXO1 TP53])
    r1 = run_new('HistTF', 'clock', { list: 'HistTF/MUT1' })
    assert_equal 2, r1.length
    values1 = r1.collect { |x| x[:value] }

    _entities, _meta, list_path = Cortex.read_list('HistTF', 'MUT1')
    File.write(list_path, "FOXO1\nTP53\nMYC\n")
    touch_future(list_path)

    r2 = run_new('HistTF', 'clock', { list: 'HistTF/MUT1' })
    assert_equal 3, r2.length
    assert r2.none? { |x| values1.include?(x[:value]) },
           'every member recomputed after the list grew'
  end

  def test_untouched_list_keeps_cache_under_new_engine
    define('HistTF', 'clock2', body: 'Time.now.to_f.to_s')
    Cortex.write_list('HistTF', 'MUT2', %w[FOXO1 TP53])
    r1 = run_new('HistTF', 'clock2', { list: 'HistTF/MUT2' })
    r2 = run_new('HistTF', 'clock2', { list: 'HistTF/MUT2' })
    assert_equal r1.collect { |x| x[:value] }, r2.collect { |x| x[:value] },
                 'untouched list: cached values replayed'
    assert_equal r1.collect { |x| x[:address] }, r2.collect { |x| x[:address] }
  end

  def test_update_true_force_recomputes_under_new_engine
    define('HistTF', 'clock3', body: 'Time.now.to_f.to_s')
    r1 = run_new('HistTF', 'clock3', 'FOXO1')
    r2 = run_new('HistTF', 'clock3', 'FOXO1')
    assert_equal r1[:value], r2[:value], 'second run replays the cache'
    r3 = run_new('HistTF', 'clock3', 'FOXO1', update: true)
    assert_not_equal r1[:value], r3[:value], 'update:true must recompute'
    assert_equal r1[:address], r3[:address], 'same address after forced recompute'
  end
end
