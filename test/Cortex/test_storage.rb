# Tests for the unified Cortex path resolution mechanism
# (lib/Cortex/storage.rb + lib/Cortex/path_maps.rb).
#
# Mirrors lib/Cortex/storage.rb: replace lib/ with test/ and prefix with test_.
#
# Hermetic: every map root, the anchor and the PWD live under tmp/, and
# SCOUT_CHAT_DIR is pinned for the duration of each test.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout'
require 'fileutils'
require 'Cortex/path_maps'
require 'Cortex/storage'

class TestCortexStorage < Test::Unit::TestCase

  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "storage-#{Process.pid}-#{rand(1e6).to_i}"))
    FileUtils.rm_rf @scratch
    @proj_a = File.join(@scratch, 'projA')
    @proj_b = File.join(@scratch, 'projB')
    @proj_c = File.join(@scratch, 'projC')
    [@proj_a, @proj_b, @proj_c].each { |p| FileUtils.mkdir_p(p) }

    # Secondary maps B and C declared through the project yaml.
    File.open(File.join(@proj_a, 'cortex_path_map.yaml'), 'w') do |f|
      f.write <<~YAML
        maps:
          b:
            dir: #{@proj_b}
          c:
            dir: #{@proj_c}
            read_only: true
      YAML
    end

    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
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

  def make_in(proj, rel)
    path = File.join(proj, 'var', 'cortex', rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "content of #{rel}\n")
    path
  end

  # ------------------------------------------------------------------
  # Resolution across maps
  # ------------------------------------------------------------------

  def test_find_reaches_secondary_maps
    only_b = make_in(@proj_b, 'artifacts/only/b/deep.md')
    only_c = make_in(@proj_c, 'artifacts/only/c/deep.md')

    assert_equal only_b, Cortex.resolve_resource(:artifacts, 'only/b/deep.md')[0]
    assert_equal :b,     Cortex.resolve_resource(:artifacts, 'only/b/deep.md')[1]
    assert_equal only_c, Cortex.resolve_resource(:artifacts, 'only/c/deep.md')[0]
    assert_equal :c,     Cortex.resolve_resource(:artifacts, 'only/c/deep.md')[1]
  end

  def test_first_match_wins_in_read_order
    a_copy = make_in(@proj_a, 'artifacts/both/x.md')
    make_in(@proj_c, 'artifacts/both/x.md')

    path, map, all = Cortex.resolve_resource(:artifacts, 'both/x.md')
    assert_equal a_copy, path
    assert_equal :chat, map
    assert_equal 2, all.length
  end

  def test_missing_resource_returns_nil
    assert_nil Cortex.resolve_resource(:artifacts, 'nope/missing.md')
  end

  def test_arbitrary_depth_and_locate
    make_in(@proj_b, 'artifacts/one/two/three/four/deep.txt')
    found = Cortex.locate(:artifacts, 'one/two/three/four/deep.txt')
    assert found, 'nested resource not found'
    assert_match(/deep\.txt/, File.read(found))
  end

  # ------------------------------------------------------------------
  # PWD fallback anchor
  # ------------------------------------------------------------------

  def test_pwd_anchor_when_chat_dir_missing
    ENV['SCOUT_CHAT_DIR'] = nil
    Dir.chdir(@proj_c)
    Cortex.reset_cortex!
    Cortex.configure_cortex!

    assert_equal @proj_c, Cortex.project_anchor

    # Default writes land under <pwd>/var/cortex, not under ~/.scout.
    target = Cortex.resource_path(:artifacts, 'pwd_probe/x.md')
    assert_equal File.join(@proj_c, 'var', 'cortex', 'artifacts', 'pwd_probe', 'x.md'), target

    # PWD also locates cortex_path_map.yaml when present.
    File.open(File.join(@proj_c, 'cortex_path_map.yaml'), 'w') do |f|
      f.write "maps:\n  pwdmap:\n    dir: #{@proj_b}\n"
    end
    Cortex.reset_cortex!
    assert Cortex.path_map_config(@proj_c).any? { |name, _| name == 'pwdmap' }
    assert Cortex.map_names.include?(:pwdmap)
  end

  # ------------------------------------------------------------------
  # Global hygiene
  # ------------------------------------------------------------------

  def test_global_path_maps_unmutated
    global = Path.path_maps.keys.collect(&:to_s).sort
    assert global.none? { |k| %w(chat b c pwdmap).include?(k) },
           "instance maps leaked into the global table: #{global}"
  end

  def test_no_pwd_synonym_map
    assert !Cortex.map_names.include?(:pwd), 'a :pwd synonym must not exist'
    assert !Cortex.map_names.include?(:anchor), 'an :anchor synonym must not exist'
  end

  # ------------------------------------------------------------------
  # resource_paths / namespace enumeration
  # ------------------------------------------------------------------

  def test_resource_paths_lists_every_map
    make_in(@proj_a, 'artifacts/dup/z.md')
    make_in(@proj_b, 'artifacts/dup/z.md')
    paths = Cortex.resource_paths(:artifacts, 'dup/z.md').collect(&:first)
    assert paths.any? { |p| p == File.join(@proj_a, 'var/cortex/artifacts/dup/z.md') }
    assert paths.any? { |p| p == File.join(@proj_b, 'var/cortex/artifacts/dup/z.md') }
  end

  def test_same_directory_maps_collapse
    # projA yaml map `self` points at projA itself: :chat and :self resolve
    # to the same physical directory and must yield ONE candidate.
    File.open(File.join(@proj_a, 'cortex_path_map.yaml'), 'a') do |f|
      f.write "  self:\n    dir: #{@proj_a}\n"
    end
    Cortex.reset_cortex!
    make_in(@proj_a, 'artifacts/dup/z.md')

    paths = Cortex.resource_paths(:artifacts, 'dup/z.md').collect(&:first)
    unique = paths.select { |p| File.exist?(p) }
    assert_equal 1, unique.length,
                 "maps resolving to the same directory must collapse, got #{paths.inspect}"
  end

  def test_namespace_entries_across_maps
    make_in(@proj_b, 'artifacts/only/b/deep.md')
    make_in(@proj_c, 'artifacts/only/c/deep.md')
    entries = Cortex.namespace_entries(:artifacts)
    assert entries.any? { |name, map, _p| name == 'only/b/deep.md' && map == :b }
    assert entries.any? { |name, map, _p| name == 'only/c/deep.md' && map == :c }
  end

end
