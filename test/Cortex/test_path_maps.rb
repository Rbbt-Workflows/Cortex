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
require 'tmpdir'
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
    # projA is a scratch repo root: the marker the PWD-fallback anchor climb
    # looks for (lib/, bin/ or README.md), like a real checkout.
    FileUtils.touch(File.join(@proj_a, 'README.md'))
    # Writes must never land in the live var/cortex: :current is PWD-based
    # and Scout's default write map, so run from the scratch project.
    Dir.chdir(@proj_a)
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
    Dir.chdir(@proj_b)
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    Cortex.reset_cortex!
    assert_equal @proj_a, Cortex.chat_anchor
    assert_equal @proj_a, Cortex.cortex_libdir
    # :lib follows the anchor, :current follows the (different) PWD
    assert_equal File.join(@proj_a, 'var', 'cortex', 'artifacts'),
                 Cortex::CORTEX[:artifacts].follow(:lib).to_s
    assert_equal File.join(@proj_b, 'var', 'cortex', 'artifacts'),
                 Cortex::CORTEX[:artifacts].follow(:current).to_s
  end

  def test_pwd_fallback_anchor_without_synonym
    Dir.chdir(@proj_a)
    Cortex.reset_cortex!
    assert_equal @proj_a, Cortex.chat_anchor
    assert !Cortex.map_names.include?(:pwd), 'must not introduce a :pwd synonym'
    # With no env anchor the PWD (a repo root here) becomes the anchor:
    # :lib == :current == {PWD}/var/cortex (identical dirs dedupe), no
    # :chat map exists.
    assert !Cortex.map?(:chat)
    assert_equal File.join(@proj_a, 'var', 'cortex'),
                 Cortex::CORTEX[:artifacts].follow(:lib).to_s.sub(/\/artifacts$/, '')
    assert_equal File.join(@proj_a, 'var', 'cortex'),
                 Cortex::CORTEX[:artifacts].follow(:current).to_s.sub(/\/artifacts$/, '')
  end

  def test_anchor_root_rejected
    Dir.chdir(@proj_b)
    ENV['SCOUT_CHAT_DIR'] = '/'
    Cortex.reset_cortex!
    assert_equal nil, Cortex.chat_anchor
    assert !Cortex.map?(:chat)
    # Unanchored (nil anchor): :lib is never pinned, neither to the scratch
    # project nor to the Cortex checkout.
    assert !Cortex::CORTEX.libdir.to_s.include?(File.basename(@scratch))
  end

  # ------------------------------------------------------------------
  # unanchored PWD fallback climbs to the repo containing the PWD (N1)
  # ------------------------------------------------------------------

  def test_unanchored_pwd_in_repo_subdir_resolves_lib_to_repo_root
    subdir = File.join(@proj_a, 'sandbox', 'pilot6')
    FileUtils.mkdir_p(subdir)
    # The scratch area must be free of repo markers so the climb cannot stop
    # at scratch/ or above; projA is the only marked root in play.
    FileUtils.rm_rf(File.join(subdir, 'lib'))
    # projA is marked as a repo root by its README.md (like a real checkout);
    # a subdir has none of the markers, so the climb must reach projA.
    FileUtils.touch(File.join(@proj_a, 'README.md'))
    Dir.chdir(subdir)
    Cortex.reset_cortex!
    assert_equal @proj_a, Cortex.chat_anchor
    assert_equal @proj_a, Cortex.cortex_libdir
    # :lib = repo store (readable), :current = subdir store (usually empty):
    # they diverge, and read order keeps :current first.
    lib_store = Cortex::CORTEX[:artifacts].follow(:lib).to_s.sub(%r{/artifacts$}, '')
    cur_store = Cortex::CORTEX[:artifacts].follow(:current).to_s.sub(%r{/artifacts$}, '')
    assert_equal File.join(@proj_a, 'var', 'cortex'), lib_store
    assert_equal File.join(subdir, 'var', 'cortex'), cur_store
    assert_equal :current, Cortex.map_order.first
    assert Cortex.map_order.include?(:lib)
  end

  def test_unanchored_pwd_in_plain_dir_keeps_pwd_anchor
    # The scratch copy itself is a repo (it has lib/, test/, workflow.rb),
    # so the climb from a plain subdir must NOT stop before the scratch
    # root... unless no marker exists above it.  Create the plain dir under
    # /tmp instead (outside any repo) and chdir there; ensure returns to
    # @scratch first so teardown still removes the suite tree.
    plain = Dir.mktmpdir('plain-', '/tmp')
    FileUtils.mkdir_p(plain)
    Dir.chdir(plain)
    Cortex.reset_cortex!
    # No lib/, bin/ or README.md anywhere above plain => the climb finds no
    # repo, so the anchor stays unset: CORTEX.libdir is not PINNED to the
    # PWD (it lazily falls back to Scout's own caller-lib resolution, which
    # is exactly the "keep today's lazy fallback" contract); nothing raises.
    assert_equal nil, Cortex.chat_anchor
    assert_not_equal plain, Cortex.cortex_libdir
    assert_equal nil, Cortex::CORTEX.instance_variable_get(:@libdir)
    assert Cortex.map?(:lib)
  ensure
    FileUtils.remove_entry(plain) if plain && File.directory?(plain)
    Dir.chdir(@scratch)
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
    assert_equal [:current, :lib, :user], order.first(3)
    assert order.index(:b) > order.index(:user), order.inspect
    assert order.index(:b) < order.index(:fast), order.inspect
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
    # :lib keeps its HEAD position even when redefined by yaml
    assert_equal :lib, Cortex.map_order[1]
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
    a = Cortex.resource_path(:artifacts, 'x.md', :lib)

    ENV['SCOUT_CHAT_DIR'] = @proj_b
    Cortex.reset_cortex!
    b = Cortex.resource_path(:artifacts, 'x.md', :lib)

    assert a != b
    assert_equal File.join(@proj_b, 'var/cortex/artifacts/x.md'), b
  end

  def test_unanchored_keeps_historical_maps
    # SCOUT_CHAT_DIR unset and PWD inside a scratch repo (README.md marker,
    # no yaml): the anchor is that repo, so :lib resolves to its store and
    # :current collapses onto the same directory at the repo root.
    ENV.delete('SCOUT_CHAT_DIR')
    FileUtils.touch(File.join(@proj_a, 'README.md'))
    Dir.chdir(@proj_a)
    Cortex.reset_cortex!
    Cortex.configure_cortex!
    assert Cortex.map?(:lib)
    lib_dir = Cortex::CORTEX[:artifacts].follow(:lib).to_s
    assert_equal File.join(@proj_a, 'var', 'cortex', 'artifacts'), lib_dir
    cur_dir = Cortex::CORTEX[:artifacts].follow(:current).to_s
    assert_equal lib_dir, cur_dir
  end

  def test_full_map_order_pin
    ENV['SCOUT_CHAT_DIR'] = @proj_a
    write_yaml(@proj_a, "maps:\n  zz:\n    dir: #{@proj_b}\n")
    Cortex.reset_cortex!
    Cortex.configure_cortex!
    # Head is fixed, extras come in yaml order, then Scout's base table tail
    # minus :default; the exact tail depends on Scout's own map table, so
    # pin the invariant, not the literal list.
    order = Cortex.map_order
    assert_equal [:current, :lib, :user, :zz], order.first(4)
    tail   = Path.map_order - [:current, :lib, :user, :zz, :default]
    assert_equal tail, order[4..-1]
    assert !order.include?(:chat)
    assert !order.include?(:default)
  end
end
