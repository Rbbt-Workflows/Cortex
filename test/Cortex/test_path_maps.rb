# Tests for the Cortex anchor / path-map configuration
# (lib/Cortex/path_maps.rb).
#
# Mirrors lib/Cortex/path_maps.rb: replace lib/ with test/ and prefix with
# test_.
#
# Hermetic: anchors, yaml configs and map directories all live under
# tmp/; SCOUT_CHAT_DIR is saved/restored around every test.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout'
require 'fileutils'
require 'Cortex/path_maps'
require 'Cortex/storage'

class TestCortexPathMaps < Test::Unit::TestCase

  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "maps-#{Process.pid}-#{rand(1e6).to_i}"))
    FileUtils.rm_rf @scratch
    @proj_a = File.join(@scratch, 'projA')
    @proj_b = File.join(@scratch, 'projB')
    @proj_c = File.join(@scratch, 'projC')
    [@proj_a, @proj_b, @proj_c].each { |d| FileUtils.mkdir_p(d) }

    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    ENV.delete('SCOUT_CHAT_DIR')
    FileUtils.rm_rf(File.join(@proj_a, 'cortex_path_map.yaml'))
  end

  def teardown
    ENV['SCOUT_CHAT_DIR'] = @old_anchor
    Dir.chdir(@old_pwd)
    Cortex.reset_cortex!
    FileUtils.rm_rf @scratch
  end

  def write_yaml(project, body)
    File.open(File.join(project, 'cortex_path_map.yaml'), 'w') { |f| f.write(body) }
  end

  def make_in(project, rel)
    path = File.join(project, 'var', 'cortex', rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "content of #{rel} in #{File.basename(project)}\n")
    path
  end

  # ------------------------------------------------------------------
  # anchor
  # ------------------------------------------------------------------

  def test_anchor_from_env_wins
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    assert_equal @proj_a, Cortex.chat_anchor
    assert_equal @proj_a, Cortex.cortex_libdir
  end

  def test_pwd_fallback_anchor_without_synonym
    Dir.chdir(@proj_a)
    Cortex.reset_cortex!
    assert_equal @proj_a, Cortex.chat_anchor
    assert !Cortex.map_names.include?(:pwd), 'must not introduce a :pwd synonym'
    assert Cortex.map?(:chat)
    assert_equal File.join(@proj_a, 'var', 'cortex'),
                 Cortex::CORTEX[:artifacts].follow(:chat).to_s.sub(/\/artifacts$/, '')
  end

  def test_anchor_root_rejected
    ENV['SCOUT_CHAT_DIR'] = '/'
    Cortex.reset_cortex!
    assert_equal nil, Cortex.chat_anchor
    assert !Cortex.map?(:chat)
  end

  # ------------------------------------------------------------------
  # yaml maps
  # ------------------------------------------------------------------

  def test_yaml_maps_extend_order_and_read_only
    write_yaml(@proj_a, <<~YAML)
      maps:
        b:
          dir: #{@proj_b}
        ro:
          dir: #{@proj_c}
          read_only: true
    YAML
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    Cortex.configure_cortex!

    order = Cortex.map_order
    assert_equal :chat, order.first
    assert order.index(:b) < order.index(:lib), order.inspect
    assert order.include?(:ro)

    assert_equal false, Cortex.read_only_map?(:b)
    assert_equal true,  Cortex.read_only_map?(:ro)
    assert Cortex.writable_maps.include?(:b)
    assert !Cortex.writable_maps.include?(:ro)
  end

  def test_yaml_redefines_lib
    write_yaml(@proj_a, <<~YAML)
      maps:
        lib:
          dir: #{@proj_b}
    YAML
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    Cortex.configure_cortex!

    assert_equal File.join(@proj_b, 'var/cortex/artifacts/x.md'),
                 Cortex.resource_path(:artifacts, 'x.md', :lib)
    # :lib stays in the tail of the map order even when redefined
    assert_equal :lib, Cortex.map_order.last(3).first
  end

  def test_yaml_lookup_root_then_etc
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Dir.chdir(@proj_a)
    FileUtils.mkdir_p(File.join(@proj_a, 'etc'))
    write_yaml(@proj_a, "maps:\n  rootmap:\n    dir: #{@proj_b}\n")
    File.open(File.join(@proj_a, 'etc', 'cortex_path_map.yaml'), 'w') do |f|
      f.write("maps:\n  etcmap:\n    dir: #{@proj_c}\n")
    end
    Cortex.reset_cortex!
    assert Cortex.map?(:rootmap), 'root yaml must take precedence over etc/'
    assert !Cortex.map?(:etcmap)
  end

  def test_invalid_yaml_raises
    write_yaml(@proj_a, "maps:\n  - a\n  - b\n")
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    assert_raise(ScoutException) { Cortex.path_map_config(@proj_a) }
  end

  # ------------------------------------------------------------------
  # global table untouched
  # ------------------------------------------------------------------

  def test_global_path_maps_not_mutated
    before = Path.path_maps.keys.sort
    write_yaml(@proj_a, "maps:\n  zzz:\n    dir: #{@proj_b}\n")
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    Cortex.configure_cortex!
    assert_equal before, Path.path_maps.keys.sort
    assert Cortex.map?(:zzz), 'zzz must exist on the CORTEX instance only'
  end

  def test_reconfigure_on_anchor_change
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    a = Cortex.resource_path(:artifacts, 'x.md', :chat)

    ENV['SCOUT_CHAT_DIR'] = @proj_b
    Cortex.reset_cortex!
    b = Cortex.resource_path(:artifacts, 'x.md', :chat)

    assert a != b
    assert_equal File.join(@proj_b, 'var/cortex/artifacts/x.md'), b
  end

  def test_unanchored_keeps_historical_maps
    # SCOUT_CHAT_DIR unset and PWD inside the pristine :lib checkout itself
    # (no yaml): the anchor IS the checkout, so :chat == :lib collapse and
    # there is no separate anchor map to configure.
    ENV.delete('SCOUT_CHAT_DIR')
    checkout = File.expand_path(File.join(File.dirname(__FILE__), '..', '..'))
    Dir.chdir(checkout)
    Cortex.reset_cortex!
    Cortex.configure_cortex!
    assert Cortex.map?(:lib)
    chat_dir = Cortex::CORTEX[:artifacts].follow(:lib).to_s
    assert_equal File.join(checkout, 'var', 'cortex', 'artifacts'), chat_dir
  end

end
