# Tests for Cortex named entity lists (lib/Cortex/lists.rb).
#
# Mirrors lib/Cortex/lists.rb: replace lib/ with test/ and prefix with test_.
#
# Hermetic: the anchor (write map) and one secondary map live under tmp/.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout'
require 'fileutils'
require 'Cortex/path_maps'
require 'Cortex/storage'
require 'Cortex/lists'

class TestCortexLists < Test::Unit::TestCase

  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "lists-#{Process.pid}-#{rand(1e6).to_i}"))
    FileUtils.rm_rf @scratch
    @proj_a = File.join(@scratch, 'projA')
    @proj_b = File.join(@scratch, 'projB')
    FileUtils.mkdir_p(@proj_a)
    FileUtils.mkdir_p(@proj_b)

    File.open(File.join(@proj_a, 'cortex_path_map.yaml'), 'w') do |f|
      f.write <<~YAML
        maps:
          b:
            dir: #{@proj_b}
          ro:
            dir: #{@proj_b}
            read_only: true
      YAML
    end

    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    # :current is PWD-based and Scout's default write map: run from the
    # scratch anchor project so writes never land in the live var/cortex
    # (and :current/:lib collapse on the same directory).
    Dir.chdir(@proj_a)
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    Cortex.configure_cortex!
  end

  def teardown
    ENV['SCOUT_CHAT_DIR'] = @old_anchor
    Dir.chdir(@old_pwd)
    Cortex.reset_cortex!
    FileUtils.rm_rf @scratch
  end

  def test_write_and_read_round_trip
    name, count, path = Cortex.write_list('TF', 'C01',
                                           "TP53\nMYC\nMYCN\n\nIRF3\n",
                                           description: 'pilot core',
                                           entity_options: { 'organism' => 'Hsa' },
                                           created_by: 'worker',
                                           job: 'test-job')

    assert_equal 'TF/C01', name
    assert_equal 4, count
    assert_equal File.join(@proj_a, 'var/cortex/lists/TF/C01'), path
    assert_equal "TP53\nMYC\nMYCN\nIRF3\n", File.read(path)

    entities, meta, found, map, _all = Cortex.read_list('TF', 'C01')
    assert_equal %w(TP53 MYC MYCN IRF3), entities
    assert_equal found, path
    # :current (== :lib here, same directory) is searched first
    assert_equal :current, map
    assert_equal 'TF', meta['entity_type']
    assert_equal 'pilot core', meta['description']
    assert_equal({ 'organism' => 'Hsa' }, meta['entity_options'])
    assert_equal 'worker', meta['created_by']
    assert meta['created_at'], 'created_at missing'
    assert_equal 4, meta['count']
  end

  def test_sidecar_layout
    Cortex.write_list('Composite', 'cell-cycle.md', %w(C01 C02), description: 'd')
    base = File.join(@proj_a, 'var/cortex/lists')
    assert File.exist?(File.join(base, 'Composite', 'cell-cycle.md'))
    assert File.exist?(File.join(base, '.meta', 'Composite', 'cell-cycle.md.yaml')),
           'sidecar must live at .meta/<entity_type>/<list>.yaml'
  end

  def test_nested_list_names
    Cortex.write_list('TF', 'sets/cell-cycle.md', "MYC\n")
    entities, _meta, path, _map, _all = Cortex.read_list('TF', 'sets/cell-cycle.md')
    assert_equal %w(MYC), entities
    assert_equal File.join(@proj_a, 'var/cortex/lists/TF/sets/cell-cycle.md'), path
  end

  def test_read_through_secondary_map
    # A list written under the yaml-configured map `b` is still found: the
    # unified resolution traverses every readable map.
    list = File.join(@proj_b, 'var/cortex/lists/TF/onlyB.md')
    FileUtils.mkdir_p(File.dirname(list))
    File.write(list, "TP53\n")

    entities, _meta, path, map, _all = Cortex.read_list('TF', 'onlyB.md')
    assert_equal %w(TP53), entities
    assert_equal list, path
    assert_equal :b, map
  end

  def test_missing_list_error_mentions_available
    assert_raise(ScoutException) { Cortex.read_list('TF', 'nope') }
    Cortex.write_list('TF', 'yes.md', 'TP53')
    e = assert_raise(ScoutException) { Cortex.read_list('TF', 'nope') }
    assert e.message.include?('yes.md'), "availability hint missing from: #{e.message}"
  end

  def test_empty_list_rejected
    assert_raise(ScoutException) { Cortex.write_list('TF', 'empty', "\n \n") }
  end

  def test_invalid_type_rejected
    assert_raise(ScoutException) { Cortex.write_list('bad type!', 'x', 'TP53') }
  end

  def test_meta_sidecar_tolerates_absence
    list = File.join(@proj_a, 'var/cortex/lists/TF/raw')
    FileUtils.mkdir_p(File.dirname(list))
    File.write(list, "MYC\n")
    entities, meta, _path, map, _all = Cortex.read_list('TF', 'raw')
    assert_equal %w(MYC), entities
    assert_equal({}, meta)
    # :current (== :lib here, same directory) is searched first
    assert_equal :current, map
  end

  def test_lists_in_namespace_listing
    Cortex.write_list('TF', 'C01', 'TP53')
    names = Cortex.namespace_names(:lists)
    assert names.include?('TF/C01'), names.inspect
    assert names.none? { |n| n.include?('.meta') }, names.inspect
  end

end
