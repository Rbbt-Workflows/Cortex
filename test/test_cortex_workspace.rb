require 'scout-ai'
require 'fileutils'
require_relative '../workflow'

# Invariant test-suite for the Cortex workspace layer.
# Runs against the LIVE workspace but only inside the probe/test subtree,
# which it purges before and after. Never touches real research data.

$passed = 0
$failed = 0
$errored = 0

def check(label)
  result = yield
  $passed += 1
  puts "PASS  #{label}"
  result
rescue StandardError => e
  if e.message.to_s.start_with?('EXPECTED')
    $failed += 1
    puts "FAIL  #{label} :: #{e.message}"
  else
    $errored += 1
    puts "ERROR #{label} :: #{e.class} #{e.message[0, 140]}"
  end
  nil
end

def expect_raise(prefix)
  yield
  raise "EXPECTED: no exception raised (wanted #{prefix})"
rescue ScoutException => e
  raise "EXPECTED: got #{e.message[0, 60].inspect}, wanted #{prefix.inspect}" unless e.message.start_with?(prefix)
end

NAMESPACES = %i(conversations briefs artifacts)

# --- sandbox names: the only resources ever touched -------------------
ART   = 'probe/test/a.md'
ART2  = 'probe/test/b.md'
CONV  = 'probe/test/conv'
BRIEF = 'probe/test/brf'
ALL   = [ART, ART2, CONV, BRIEF].freeze

def purge
  NAMESPACES.each do |ns|
    ALL.each do |n|
      Cortex.resource_paths(ns, n).each { |p, _m| Open.rm_rf(p) if File.exist?(p) }
      Cortex.read_maps.each do |m|
        Cortex.sidecar_paths(ns, n, m).each { |p| Open.rm_rf(p) if File.exist?(p) }
      end
    end
  end
  # drop empty sandbox parents
  Cortex.read_maps.each do |m|
    dir = Cortex.namespace_dir(:artifacts, m) + '/probe'
    Dir.rmdir(dir + '/test') rescue nil
    Dir.rmdir(dir) rescue nil
  end
end

purge
at_exit { purge }

def make_conversation(name, msg)
  chat = Chat.setup([])
  chat.user msg
  chat.assistant 'ack'
  path = Cortex.resource_path(:conversations, name, Cortex.write_map)
  Open.mkdir(File.dirname(path))
  chat.save(path)
  path
end

make_conversation(CONV, 'zebra crossing note')
Cortex.write_artifact(ART, "alpha beta\nsecond line\nthird line\n", :replace, job: 'test', agent: 'tester')
raise 'test contamination: original artifact lost' unless Open.read(Cortex.resource_path(:artifacts, ART, Cortex.write_map)).include?('second line')

# ---------------------------------------------------------------------
# write -> read
# ---------------------------------------------------------------------
check('write -> read (nested name, first page reports lines/total)') do
  text = Cortex.read_artifact(ART, nil, nil)
  raise "EXPECTED: missing line header, got #{text[0, 40].inspect}" unless text =~ /^# lines 1-\d+ of \d+ \(end\)$/
  raise 'EXPECTED: content mismatch' unless text.include?('alpha beta')
  text
end

# ---------------------------------------------------------------------
# write -> search
# ---------------------------------------------------------------------
check('write -> search finds nested artifact content') do
  hits = Cortex.search_artifacts('alpha', 10)
  raise "EXPECTED: no hit for nested artifact in #{hits.inspect}" unless hits.any? { |t, n, _| n.start_with?('probe/test/a.md') }
  hits
end

check('search honors limit') do
  hits = Cortex.search_artifacts('line', 1)
  raise "EXPECTED: wanted <= 1 hit, got #{hits.length}" unless hits.length <= 1
  hits
end

# ---------------------------------------------------------------------
# write -> edit -> read ; history preserved
# ---------------------------------------------------------------------
check('edit replaces single occurrence, read reflects it, history grows') do
  Cortex.write_artifact(ART, "alpha beta\nsecond line\nthird line\n", :replace, job: 'test', agent: 'tester')
  h_before = Dir[Cortex.resource_path(:artifacts, ART, Cortex.write_map).sub('probe/test/a.md', '.history/probe/test/a.md/*')].length
  Cortex.edit_artifact(ART, 'second line', 'SECOND LINE', job: 'test-edit', agent: 'tester')
  text = Cortex.read_artifact(ART, nil, nil)
  raise 'EXPECTED: edit not visible' unless text.include?('SECOND LINE')
  h_after = Dir[Cortex.resource_path(:artifacts, ART, Cortex.write_map).sub('probe/test/a.md', '.history/probe/test/a.md/*')].length
  raise "EXPECTED: history not preserved (#{h_before} -> #{h_after})" unless h_after == h_before + 1
  text
end

check('edit fails on missing text') do
  expect_raise('Cannot edit') { Cortex.edit_artifact(ART, 'nope', 'x') }
end

check('edit fails on ambiguous text unless all=true') do
  Cortex.write_artifact(ART, "dup\ndup\n", :replace, job: 'test', agent: 'tester')
  expect_raise('Cannot edit') { Cortex.edit_artifact(ART, 'dup', 'one') }
  Cortex.edit_artifact(ART, 'dup', 'X', all: true)
  text = Cortex.read_artifact(ART, nil, nil)
  raise 'EXPECTED: multi-replace wrong' unless text.scan('X').length == 2
  text
end

# ---------------------------------------------------------------------
# rename: identity, meta, history travel together
# ---------------------------------------------------------------------
check('write -> rename -> read; meta/history attached') do
  base = Cortex.resource_path(:artifacts, ART, Cortex.write_map)
  hist_dir = base.sub('probe/test/a.md', '.history/probe/test/a.md')
  meta_p = base.sub('probe/test/a.md', '.meta/probe/test/a.md.json')
  h_count = Dir[hist_dir + '/*'].length
  v_count = JSON.parse(Open.read(meta_p))['versions'].length

  Cortex.rename_resource(:artifacts, ART, ART2, job: 'test-rename', agent: 'tester')

  base2 = Cortex.resource_path(:artifacts, ART2, Cortex.write_map)
  hist2 = base2.sub('probe/test/b.md', '.history/probe/test/b.md')
  meta2 = base2.sub('probe/test/b.md', '.meta/probe/test/b.md.json')

  raise 'EXPECTED: renamed content unreadable' unless Cortex.read_artifact(ART2, nil, nil).include?('X')
  raise 'EXPECTED: old name still resolvable' if Cortex.resolve_resource(:artifacts, ART)
  raise 'EXPECTED: history lost on rename' unless Dir[hist2 + '/*'].length == h_count
  raise 'EXPECTED: meta lost on rename' unless File.exist?(meta2)
  vs = JSON.parse(Open.read(meta2))['versions']
  raise 'EXPECTED: versions lost on rename' unless vs.length == v_count + 1
  raise 'EXPECTED: rename version record missing' unless vs.last['mode'] == 'rename' && vs.last['renamed_from'] == ART
  hist2
end

check('rename to existing target fails') do
  Cortex.write_artifact(ART, 'src', :replace, job: 'test', agent: 'tester')
  expect_raise('Rename target') { Cortex.rename_resource(:artifacts, ART, ART2) }
end

check('rename missing source fails') do
  expect_raise('No artifact') { Cortex.rename_resource(:artifacts, 'probe/test/ghost.md', 'probe/test/x.md') }
end

# ---------------------------------------------------------------------
# remove: resource + sidecars vanish together
# ---------------------------------------------------------------------
check('write -> remove leaves no stale metadata/history') do
  Cortex.remove_resource(:artifacts, ART)
  base = Cortex.resource_path(:artifacts, ART, Cortex.write_map)
  meta_p = base.sub('probe/test/a.md', '.meta/probe/test/a.md.json')
  hist_dir = base.sub('probe/test/a.md', '.history/probe/test/a.md')
  raise 'EXPECTED: resource still present' if File.exist?(base)
  raise 'EXPECTED: stale metadata left behind' if File.exist?(meta_p)
  raise 'EXPECTED: stale history left behind' if File.exist?(hist_dir)
  :ok
end

check('remove missing source fails') do
  expect_raise('No artifact') { Cortex.remove_resource(:artifacts, 'probe/test/ghost.md') }
end

# ---------------------------------------------------------------------
# move: lib/current resolve to the same dir in this checkout -> no-op
# ---------------------------------------------------------------------
check('move between maps that share a directory is a safe no-op') do
  res = Cortex.move_resource(:artifacts, ART2, :current, job: 'test-move', agent: 'tester')
  raise "EXPECTED: no-op message, got #{res.inspect}" unless res =~ /no-op/
  Cortex.read_artifact(ART2, nil, nil)
end

check('move to same map fails cleanly') do
  expect_raise('No artifact') { Cortex.move_resource(:artifacts, 'probe/test/ghost.md', :current) }
end

check('move -> search still finds resource') do
  hits = Cortex.search_artifacts('X', 10)
  raise 'EXPECTED: resource not searchable after move' unless hits.any? { |t, n, _| n.start_with?('probe/test/b.md') }
  hits
end

# ---------------------------------------------------------------------
# path maps: same logical name in two maps (needs distinct dirs; here
# lib == current, so we exercise the dedupe/ambiguity logic instead)
# ---------------------------------------------------------------------
check('resource_paths dedupes maps that resolve to the same dir') do
  # From the scout-ai libdir the session runs anchored: :chat and :current
  # both resolve to the anchor project, so asking for exactly those two maps
  # must collapse to a single physical path.  (When unanchored, :lib and
  # :current play the same role.)
  dup_pair = %i(chat current lib).each_cons(2).map { |a,b| [a,b] }.
    find { |a,b| Cortex.resource_path(:artifacts, ART2, a) == Cortex.resource_path(:artifacts, ART2, b) }
  raise 'PRECONDITION failed: no two maps share a directory' unless dup_pair
  pairs = Cortex.resource_paths(:artifacts, ART2, dup_pair)
  raise "EXPECTED: 1 unique path, got #{pairs.inspect}" unless pairs.length == 1
  pairs
end

check('resource_paths keeps genuinely distinct maps distinct') do
  # :user is a different physical directory (~/.scout/var/cortex), so the
  # full read map list yields one entry per distinct directory.
  pairs = Cortex.resource_paths(:artifacts, ART2)
  dirs  = pairs.collect { |_path, map| File.dirname(File.dirname(Cortex.resource_path(:artifacts, ART2, map))) }.uniq
  raise "EXPECTED: 2 unique roots, got #{dirs.inspect}" unless dirs.length == pairs.length
  # Baseline order is [:lib, :current, :user]; from the Cortex checkout
  # :lib and :current collapse (same physical dir) so :lib leads.
  raise "EXPECTED: wanted #{Cortex.read_maps.first} first, got #{pairs.inspect}" unless pairs.first.last == Cortex.read_maps.first
  pairs
end

check('resolve_resource reports single location, no false ambiguity') do
  path, map, all_paths = Cortex.resolve_resource(:artifacts, ART2)
  raise "EXPECTED: got #{all_paths.inspect}" unless all_paths.length == 1 && map == Cortex.read_maps.first
  path
end

check('legacy :current data is listable/readable/searchable') do
  # Self-contained: create the legacy fixture in :current first instead of
  # depending on live workspace data that may have been cleaned up.
  fixture = 'probe/test/legacy'
  make_conversation(fixture, 'bash legacy fixture note')
  begin
    names = Cortex.namespace_names(:conversations, :current)
    raise 'EXPECTED: :current conversations not enumerable' unless names.any? { |n| n == fixture }
    list = Cortex.listing_text('conversations', nil, 0, 50)
    raise 'EXPECTED: legacy conversation missing from listing' unless list.include?(fixture)
    hits = Cortex.search_conversations('bash', 'conversations', 10)
    raise "EXPECTED: legacy conversation not searchable #{hits.inspect[0, 80]}" unless hits.any? { |t, n, _| n == fixture }
    hits
  ensure
    Cortex.resource_paths(:conversations, fixture).each { |path, _m| Open.rm_rf(path) if File.exist?(path) }
  end
end

# ---------------------------------------------------------------------
# pagination
# ---------------------------------------------------------------------
check('listing pagination: offset/limit + next info') do
  Cortex.write_artifact('probe/test/pg1.md', 'p1', :replace, job: 'test', agent: 'tester')
  Cortex.write_artifact('probe/test/pg2.md', 'p2', :replace, job: 'test', agent: 'tester')
  page = Cortex.listing_text('artifacts', 'probe/test/', 0, 1)
  raise "EXPECTED: one-entry page, got:\n#{page[0, 200]}" unless page =~ /1\/\d+ entries/
  page2 = Cortex.listing_text('artifacts', 'probe/test/', 1, 1)
  raise 'EXPECTED: second page differs' if page == page2
  page
end

check('listing beyond end returns empty page') do
  page = Cortex.listing_text('artifacts', 'probe/test/nonexistent-prefix-', 100, 10)
  raise "EXPECTED: empty section, got #{page[0, 80].inspect}" unless page =~ /0\/0 entries/
  page
end

check('artifact read: middle page reports next start line') do
  Cortex.write_artifact(ART2, (1..5).to_a.collect { |i| "L#{i}" } * "\n", :replace, job: 'test', agent: 'tester')
  text = Cortex.read_artifact(ART2, 2, 2)
  raise "EXPECTED: header with next, got #{text.lines.first.inspect}" unless text.lines.first.strip == '# lines 2-3 of 5 (next: 4)'
  raise 'EXPECTED: wrong page body' unless text.include?("L2\nL3")
  text
end

check('artifact read: last page reports end') do
  text = Cortex.read_artifact(ART2, 4, 10)
  raise 'EXPECTED: end marker missing' unless text.lines.first.strip == '# lines 4-5 of 5 (end)'
  text
end

check('artifact read beyond end fails cleanly') do
  expect_raise('Artifact has') { Cortex.read_artifact(ART2, 99, 1) }
end

# ---------------------------------------------------------------------
# invalid paths / traversal
# ---------------------------------------------------------------------
check('path traversal rejected (write)') do
  expect_raise('Invalid Cortex resource name') { Cortex.write_artifact('../escape.md', 'x', :replace) }
end

check('path traversal rejected (rename)') do
  expect_raise('Invalid Cortex resource name') { Cortex.rename_resource(:artifacts, ART2, '../../escape.md') }
end

check('absolute path rejected') do
  expect_raise('Invalid Cortex resource name') { Cortex.resource_path(:artifacts, '/etc/passwd') }
end

check('tilde path rejected') do
  expect_raise('Invalid Cortex resource name') { Cortex.resource_path(:artifacts, '~/x') }
end

# ---------------------------------------------------------------------
# briefs separation
# ---------------------------------------------------------------------
check('brief namespace is isolated from conversations') do
  p1 = Cortex.resource_path(:briefs, BRIEF, Cortex.write_map)
  p2 = Cortex.resource_path(:conversations, BRIEF, Cortex.write_map)
  raise 'EXPECTED: same physical path' unless p1 != p2
  Open.mkdir(File.dirname(p1))
  Open.write(p1, "user brief content\nassistant ok\n")
  names = Cortex.namespace_names(:conversations, Cortex.write_map)
  raise 'EXPECTED: brief leaked into conversations' if names.include?(BRIEF)
  p1
end

# ---------------------------------------------------------------------
# listing is metadata-only
# ---------------------------------------------------------------------
check('listing never returns contents') do
  Cortex.write_artifact(ART2, 'SECRET-MARKER-123', :replace, job: 'test', agent: 'tester')
  page = Cortex.listing_text('artifacts', 'probe/test/', 0, 50)
  raise 'EXPECTED: listing leaked content' if page.include?('SECRET-MARKER-123')
  page
end



# === DEFECT regression checks (appended by 2026-08-26 pass) ===

# DEFECT-1 / DEFECT-2: property bodies bind declared arguments by name and
# support early `return`. Uses a throwaway entity type so the live registry is
# untouched.
check('property bodies bind named arguments and allow early return') do
  type = "D1Probe#{Time.now.to_i}"
  res1 = Cortex.job(:cortex_property_define, type,
                    entity_type: type, property: 'named_args',
                    body: "{ treatment: treatment, timepoint: timepoint, entity: entity }",
                    description: 'named argument binding regression',
                    property_type: 'single', result_type: 'json',
                    arguments: [{ 'name' => 'treatment' }, { 'name' => 'timepoint' }],
                    test_entity: 'E2F1', test_arguments: { 'treatment' => 'DMSO', 'timepoint' => '1' }).exec

  res2 = Cortex.job(:cortex_property_define, type,
                    entity_type: type, property: 'early_return',
                    body: "return { early: true } if entity == \"E2F1\"\n{ early: false }",
                    description: 'early return regression',
                    property_type: 'single', result_type: 'json',
                    arguments: [],
                    test_entity: 'E2F1').exec
  # The smoke test ran each property inside define; verify the compiled
  # module generation binds declared arguments by name (DEFECT-1) and allows
  # an early `return` in the author body (DEFECT-2).
  mod  = Cortex.load_entity_type(type)
  ent  = mod.setup('E2F1')
  got1 = ent.named_args('treatment' => 'DMSO', 'timepoint' => '1')
  raise "NAMED: got #{got1.inspect}" unless got1[:treatment] == 'DMSO' && got1[:timepoint] == '1' && got1[:entity] == 'E2F1'
  got2 = ent.early_return
  raise "RETURN: got #{got2.inspect}" unless got2[:early] == true
end

# DEFECT-4: cortex_write keeps path/name routing under long multi-line content
check('cortex_write path/name routing survives long multi-line content') do
  long = (1..80).collect { |i| "line \#{i} " + ('x' * 60) } * "\n"
  t = "F10Probe#{Time.now.to_i}"
  # Unique path: the historical one exists in a second path map, which makes
  # cortex_read prefix a cross-map [note] line and break the byte comparison.
  art = "scratch/f10_regression_#{t}.md"
  Cortex.job(:cortex_write, t, path: art, content: long, mode: 'replace').exec
  read = Cortex.job(:cortex_read, t, name: art, type: 'artifacts').exec
  read = read.sub(/\A# lines [^\n]*\n/, '').sub(/\n\z/, '')
  raise "ROUNDTRIP failed (#{read.length} vs #{long.length})" unless read == long

  # Malformed use (content passed as path) must be rejected, not written
  begin
    Cortex.job(:cortex_write, t + 'b', path: long, content: 'x', mode: 'replace').exec
    raise 'expected rejection for multi-line path'
  rescue ScoutException
    nil
  end
end

# ---------------------------------------------------------------------
puts format("\nSUITE: %d passed, %d failed, %d errored", $passed, $failed, $errored)
exit($failed + $errored > 0 ? 1 : 0)
