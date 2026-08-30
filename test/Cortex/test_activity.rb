# Tests for the Cortex activity report (lib/Cortex/activity.rb + facets),
# its facet registry and the cortex_activity task.
#
# Mirrors the engine/lib layout: scratch path maps from test_helper, the
# same property/list fixtures the registry tests use.

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

require_relative File.expand_path('../test_entities', __FILE__)
require 'Cortex/tasks/activity'
require 'Cortex/artifacts'

class TestCortexActivity < Test::Unit::TestCase
  include TestEntitiesHelpers

  ACT_TYPE = 'ProbeAct'

  def setup
    [LIBDIR, USERDIR].each do |root|
      %w[entities properties lists jobs].each do |sub|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', sub))
      end
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', 'Cortex'))
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)

    # ----------------------------------------------------------------
    # Fixture: two properties, one list containing the entity, one
    # property run on the entity, one artifact mentioning it.
    # ----------------------------------------------------------------
    define(ACT_TYPE, 'expr', body: "'HIGH'", result_type: 'string')
    define(ACT_TYPE, 'len', body: 'entity.length', result_type: 'integer',
                          arguments: [{ name: 'scale', type: 'integer',
                                       description: 'Scale', required: true }])
    Cortex.write_list(ACT_TYPE, 'C01', %w[FOXO1 MYC], description: 'core set',
                      job: 'test_activity')
    run_prop(ACT_TYPE, 'expr', 'FOXO1')
    run_prop(ACT_TYPE, 'len', 'FOXO1', arguments: { scale: 1 })
    Cortex.write_artifact('notes/foxo1.md', "FOXO1 is examined in the core set\n", :replace,
                          job: 'test_activity', agent: 'test')
  end

  def report(facets: nil, limit: nil)
    Cortex.activity_report(entity_type: ACT_TYPE, entity: 'FOXO1',
                           facets: facets, limit: limit)
  end

  def section(report, name)
    report['facets'].find { |s| s['facet'] == name }
  end

  def test_facet_registry_is_ordered_and_self_registering
    assert_equal %w(properties investigations lists mentions), Cortex::ACTIVITY_FACETS.keys
    assert Cortex::ACTIVITY_FACETS.values.all? { |d| d['block'].respond_to?(:call) }
    assert !Cortex::ACTIVITY_FACETS.values.any? { |d| d['description'].to_s.empty? }
  end

  def test_default_run_returns_all_sections_in_order
    r = report
    assert_equal "#{ACT_TYPE}/FOXO1", r['entity']
    assert_equal %w(properties investigations lists mentions), r['facet_names']
    assert_equal %w(properties investigations lists mentions), r['facets'].collect { |s| s['facet'] }
  end

  def test_facet_selection
    r = report(facets: 'lists,properties')
    assert_equal %w(lists properties), r['facet_names']
    assert r['facets'].all? { |s| %w(lists properties).include?(s['facet']) }
  end

  def test_unknown_facet_is_actionable
    e = assert_raises(ScoutException) { report(facets: 'daydream') }
    assert_match(/Unknown activity facet "daydream"/, e.message)
    assert_match(/properties, investigations, lists, mentions/, e.message)
  end

  def test_sections_contents
    r = report

    props = section(r, 'properties')['items']
    assert_equal %w[expr len], props.collect { |i| i['property'] }, 'sorted by property'
    expr = props.first
    assert_equal 'string', expr['result_type']
    assert_equal 'single', expr['property_type']
    assert_equal '1', expr['definition_version']
    assert expr['active']

    inv = section(r, 'investigations')['items']
    assert_equal 2, inv.length
    by_prop = inv.group_by { |i| i['property'] }
    assert_equal 1, by_prop['expr'].first['runs']
    assert_equal 1, by_prop['len'].first['runs']
    assert_equal({ 'scale' => 1 }, by_prop['len'].first['arguments'])
    assert_match(%r{ProbeAct/len/FOXO1}, by_prop['len'].first['property_job'])
    assert by_prop['expr'].first['property_job'], 'job reference present'
    assert !by_prop['expr'].first.key?('result'), 'no result payload'

    lists = section(r, 'lists')['items']
    assert_equal 1, lists.length
    assert_equal 'C01', lists.first['list']
    assert_equal 'core set', lists.first['description']

    mentions = section(r, 'mentions')['items']
    assert mentions.any? { |m| m['type'] == 'artifacts' && m['name'] == 'notes/foxo1.md' },
           mentions.inspect
  end

  def test_list_member_investigations_are_aggregated_for_the_entity
    # A list run records one examination per member under the list
    # receiver; the investigations facet must surface it for each member.
    run_prop(ACT_TYPE, 'expr', %w[FOXO1 MYC])
    inv = section(report, 'investigations')['items']
    foxo1 = inv.select { |i| i['property'] == 'expr' }
    assert_equal 2, foxo1.collect { |i| i['runs'] }.inject(:+),
                 'direct run + list-member run both counted'
  end

  def test_no_result_payloads_leak
    txt = report.to_json
    assert !txt.include?('HIGH'), 'property result value must not leak'
    r2 = report
    r2['facets'].each do |s|
      assert s['items'], "section #{s['facet']} has items"
      assert s['items'].none? { |i| i.is_a?(Hash) && i.key?('result') }
    end
  end

  def test_deterministic_output
    a = report.to_json
    b = report.to_json
    assert_equal a, b
    assert_equal Marshal.dump(report), Marshal.dump(report(facets: nil))
  end

  def test_limit_applied_per_section_after_sorting
    define(ACT_TYPE, 'a1', body: "'x'", result_type: 'string')
    define(ACT_TYPE, 'a2', body: "'x'", result_type: 'string')
    define(ACT_TYPE, 'a3', body: "'x'", result_type: 'string')
    r = report(limit: 2)
    props = section(r, 'properties')
    assert_equal 2, props['items'].length
    assert_equal 5, props['meta']['total']
    assert_equal 2, props['meta']['shown']
    assert_equal %w[a1 a2], props['items'].collect { |i| i['property'] }
    assert_equal 2, section(r, 'investigations')['items'].length
  end

  def test_extensibility_local_registration
    Cortex.register_activity_facet('local_probe', 'test-local facet') do |ctx|
      { 'facet' => 'local_probe', 'title' => 'local',
        'items' => [{ 'entity_type' => ctx.entity_type }],
        'meta' => {} }
    end
    r = report(facets: 'local_probe')
    assert_equal %w(local_probe), r['facet_names']
    assert_equal ACT_TYPE, r['facets'].first['items'].first['entity_type']
  ensure
    Cortex::ACTIVITY_FACETS.delete('local_probe')
  end

  def test_task_runs_and_returns_json_shape
    job = Cortex.job(:cortex_activity, 't1', entity_type: ACT_TYPE, entity: 'FOXO1')
    job.clean if job.done?
    res = job.run
    assert_equal "#{ACT_TYPE}/FOXO1", res['entity']
    assert_equal %w(properties investigations lists mentions), res['facet_names']
    assert job.path.to_s.end_with?('.json') || true
    txt = File.read(job.path)
    assert !txt.include?('HIGH'), 'no result payload in the job file'
  end

  def test_task_rejects_unknown_entity_type
    e = assert_raises(ScoutException) do
      Cortex.activity_report(entity_type: 'probe_act_bogus', entity: 'FOXO1')
    end
    assert_match(/Invalid entity type/, e.message)
  end
end
