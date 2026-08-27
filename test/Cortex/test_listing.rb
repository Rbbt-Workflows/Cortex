# Tests for the Cortex listing/search presentation layer
# (lib/Cortex/listing.rb + lib/Cortex/tasks/listing.rb).
#
# Mirrors lib/Cortex/listing.rb: replace lib/ with test/ and prefix with
# test_.
#
# Hermetic: every map root, the anchor and the PWD live under tmp/, and
# SCOUT_CHAT_DIR is pinned for the duration of each test.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')

require 'scout'
require 'fileutils'
require 'scout-ai'
require 'Cortex/path_maps'
require 'Cortex/storage'
require 'Cortex/conversations'
require 'Cortex/briefs'
require 'Cortex/artifacts'
require 'Cortex/lists'
require 'Cortex/listing'

class TestCortexListing < Test::Unit::TestCase

  # Chat.setup(...).follow requires an LLM backend; build the chat by hand
  # like test/test_cortex_workspace.rb does.
  def make_conversation(name, msg)
    chat = Chat.setup([])
    chat.user msg
    chat.assistant 'ack'
    path = Cortex.resource_path(:conversations, name, Cortex.write_map)
    Open.mkdir(File.dirname(path))
    chat.save(path)
    path
  end

  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "listing-#{Process.pid}-#{rand(1e6).to_i}"))
    FileUtils.rm_rf @scratch
    @proj_a = File.join(@scratch, 'projA')
    @proj_b = File.join(@scratch, 'projB')
    [@proj_a, @proj_b].each { |p| FileUtils.mkdir_p(p) }

    File.open(File.join(@proj_a, 'cortex_path_map.yaml'), 'w') do |f|
      f.write <<~YAML
        maps:
          b:
            dir: #{@proj_b}
      YAML
    end

    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    # :current is PWD-based and Scout's default write map: run from the
    # scratch anchor project so writes never land in the live var/cortex.
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

  # ------------------------------------------------------------------
  # Row shape: the map is its OWN column and `name` stays clean
  # ------------------------------------------------------------------

  def test_conversation_rows_carry_separate_map_column
    make_conversation('probe/both', 'hello from current')
    rows = Cortex.namespace_listing('conversations')
    row  = rows.find { |r| r[0] == 'probe/both' }
    assert row, rows.inspect
    # header: #name map messages bytes mtime
    assert_equal %w(#name map messages bytes mtime), Cortex.listing_header('conversations')
    assert_equal 'probe/both', row[0], 'name column must stay clean'
    assert_equal '2', row[2], row.inspect
    refute row[0].include?(':'), "name leaked a map tag: #{row[0]}"
  end

  def test_artifact_rows_carry_separate_map_column
    Cortex.write_artifact('design/cortex-path-map-yaml.md', 'contents', :replace,
                          job: 'test', agent: 'tester')
    rows = Cortex.namespace_listing('artifacts')
    row  = rows.find { |r| r[0] == 'design/cortex-path-map-yaml.md' }
    assert row, rows.inspect
    assert_equal %w(#name map bytes mtime), Cortex.listing_header('artifacts')
    assert_equal 'design/cortex-path-map-yaml.md', row[0]
    assert_equal 'current', row[1], 'write map :current must be reported'
    assert_equal '8', row[2], row.inspect
  end

  def test_entry_in_two_maps_occupies_two_rows_with_clean_names
    # Same logical name in :current (projA) and in the yaml map :b (projB)
    make_conversation('probe/both', 'hello from current')
    other = File.join(@proj_b, 'var/cortex/conversations/probe/both')
    FileUtils.mkdir_p(File.dirname(other))
    File.write(other, "user\nhello from b\nassistant\nok\n")

    rows = Cortex.namespace_listing('conversations')
    hits = rows.select { |r| r[0] == 'probe/both' }
    assert_equal 2, hits.length, rows.collect { |r| r[0, 2] }.inspect
    assert_equal %w(b current), hits.collect { |r| r[1] }.sort,
                 'one row per map, map in its own column'
    assert(hits.all? { |r| r[0] == 'probe/both' }, 'no :map suffix on names')
  end

  def test_listing_text_all_uses_the_new_columns
    make_conversation('convo/one', 'text')
    Cortex.write_artifact('claims/C42.md', 'x', :replace, job: 't', agent: 't')
    Cortex.write_list('TF', 'C01', "TP53\n", description: 'd')

    text = Cortex.listing_text('all')
    assert_includes text, "#name\tmap\tmessages\tbytes\tmtime"
    assert_includes text, "#name\tmap\tbytes\tmtime"
    assert_includes text, "#name\tmap\tentities\tmtime"
    assert_includes text, "convo/one\tcurrent\t2\t"
    assert_includes text, "claims/C42.md\tcurrent\t"
    assert_includes text, "TF/C01\tcurrent\t1\t"
    refute text =~ /:[a-z]+\t\d+\t/, 'no :map suffix glued onto any name'
  end

  def test_list_rows_carry_separate_map_column
    Cortex.write_list('TF', 'C01', "TP53\nMYC\n", description: 'd')
    rows = Cortex.namespace_listing('lists')
    row  = rows.find { |r| r[0] == 'TF/C01' }
    assert row, rows.inspect
    assert_equal %w(#name map entities mtime), Cortex.listing_header('lists')
    assert_equal 'TF/C01', row[0]
    assert_equal 'current', row[1]
    assert_equal '2', row[2], row.inspect
  end

  def test_secondary_map_list_row_reports_b
    list = File.join(@proj_b, 'var/cortex/lists/TF/onlyB.md')
    FileUtils.mkdir_p(File.dirname(list))
    File.write(list, "TP53\n")
    rows = Cortex.namespace_listing('lists')
    row  = rows.find { |r| r[0] == 'TF/onlyB.md' }
    assert row, rows.inspect
    assert_equal 'b', row[1], rows.inspect
  end

  # ------------------------------------------------------------------
  # Search rows: same shape change (#type name map match)
  # ------------------------------------------------------------------

  def test_search_rows_report_map_in_own_column
    make_conversation('probe/both', 'zebra crossing here')
    Cortex.write_artifact('design/z.md', 'zebra artifact text', :replace,
                          job: 't', agent: 't')
    hits = Cortex.search_conversations('zebra', 'conversations', 10)
    assert hits.any? { |t, n, _m, _s| t == 'conversations' && n == 'probe/both' },
           hits.inspect
    assert(hits.none? { |_t, n, _m, _s| n.include?(':') },
           "search names must stay clean: #{hits.inspect}")
    assert hits.any? { |_t, _n, m, _s| m == 'current' }, hits.inspect

    hits2 = Cortex.search_artifacts('zebra', 10)
    assert hits2.any? { |t, n, m, _s| t == 'artifacts' && n == 'design/z.md' && m == 'current' },
           hits2.inspect
  end

end
