# ==========================================================================
# Cortex::Properties run path + Cortex::Error envelope (design §2.3/§2.4/§2.6)
# --------------------------------------------------------------------------
# Step 3 of the redesign: dispatch labels, fan-out partial failure with
# member envelopes, resolve_address (literal / var/jobs / loud recovery /
# ambiguity / candidates), named-list staleness.
#
# ISOLATION: identical to test_entities.rb (scratch path maps under
# tmp/entity_test_var installed after the workflow loads).
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

STEP3_TYPES = %w[Step3A Step3B].freeze

module Step3Helpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      STEP3_TYPES.each do |t|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', t))
        FileUtils.rm_rf(File.join(root, 'var', 'jobs', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'lists', t))
      end
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)
  end

  def define(type, property, body:, **rest)
    Cortex.define_property(type, property,
      body: body, description: rest.delete(:description) || 'test',
      property_type: rest.delete(:property_type) || :single,
      result_type: rest.delete(:result_type) || 'string',
      arguments: rest.delete(:arguments) || [],
      dependencies: rest.delete(:dependencies) || [],
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'step3_tests',
      test_entity: rest.delete(:test_entity), test_arguments: rest.delete(:test_arguments))
  end

  def run3(type, property, receiver, arguments: {}, **opts)
    Cortex::Properties.run_property(entity_type: type, property: property,
                                    receiver: receiver, arguments: arguments,
                                    update: opts.delete(:update) || false,
                                    timeout: opts.delete(:timeout))
  end

  def assert_32hex_label(label)
    assert_match(/\A[A-Za-z0-9_.:-]+_[0-9a-f]{32}\z/, label, label.inspect)
  end

  def json_message(e)
    JSON.parse(e.message)
  rescue JSON::ParserError
    flunk "exception message is not the structured envelope: #{e.message[0, 200]}"
  end
end

class TestPropertiesRun < Test::Unit::TestCase
  include Step3Helpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # ------------------------------------------------------------------
  # §2.3 dispatch labels
  # ------------------------------------------------------------------
  def test_dispatch_single_scalar_one_step_hash_receipt
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    r = run3('Step3A', 'echo', 'Tp53')
    assert Hash === r, ':single scalar returns ONE receipt, not an array'
    assert_32hex_label r[:address].split('/').last
    assert_equal 'Tp53', r[:receiver]
    assert_equal 'E:Tp53', r[:value]
    assert_equal :done, r[:status]
  end

  def test_dispatch_single_list_fanout_array_of_receipts
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    rs = run3('Step3A', 'echo', %w[A B C])
    assert Array === rs
    assert_equal 3, rs.length
    labels = rs.collect { |r| r[:address].split('/').last }
    labels.each { |l| assert_32hex_label l }
    assert_equal %w[A B C], labels.collect { |l| l.split('_').first }
    assert_equal labels.length, labels.uniq.length
    assert rs.all? { |r| r[:status] == :done }
  end

  def test_dispatch_single_named_list_fanout_never_vector
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    Cortex.write_list('Step3A', 'panel', %w[FOXO1 MYC])
    rs = run3('Step3A', 'echo', { list: 'Step3A/panel' })
    assert Array === rs
    assert_equal 2, rs.length
    # :single fan-out never produces a Default_ label (vector form)
    rs.each do |r|
      refute_match(/\ADefault_/, r[:address].split('/').last,
                   ':single list receiver must fan out, not vector')
      assert_equal 'Step3A/panel', r[:entity_list]
    end
  end

  def test_dispatch_array_and_both_vector_default_label
    define('Step3B', 'joined',
           body: 'Array === entity_list ? entity_list.join("+") : entity.to_s',
           property_type: :array)
    r = run3('Step3B', 'joined', %w[Tp53 Kras])
    assert Hash === r, ':array returns ONE vector receipt'
    assert_match(/\ADefault_[0-9a-f]{32}\z/, r[:address].split('/').last)
    assert_equal 'Tp53+Kras', r[:value]

    define('Step3B', 'anyboth',
           body: 'Array === entity_list ? entity_list.join("-") : entity.to_s',
           property_type: :both)
    r2 = run3('Step3B', 'anyboth', 'Tp53')
    assert Hash === r2
    assert_match(/\ADefault_[0-9a-f]{32}\z/, r2[:address].split('/').last)
    assert_equal 'Tp53', r2[:value]
  end

  # ------------------------------------------------------------------
  # §2.6 fan-out partial failure
  # ------------------------------------------------------------------
  def test_fanout_partial_failure_member_envelopes
    define('Step3A', 'risky', body: <<~'RB')
      raise ScoutException if entity.to_s == 'B'
      'ok:' + entity.to_s
    RB
    rs = run3('Step3A', 'risky', %w[A B C])
    assert Array === rs, 'a partial failure is a COMPLETED run'
    assert_equal 3, rs.length
    assert_equal %i[done error done], rs.collect { |r| r[:status] }
    ok = rs.find { |r| r[:receiver] == 'A' }
    assert_equal 'ok:A', ok[:value]
    assert_nil ok[:error]
    bad = rs.find { |r| r[:receiver] == 'B' }
    assert_equal :error, bad[:status]
    env = bad[:error]
    assert_equal 'ScoutException', env[:exception_class]
    assert_equal 'ScoutException', env[:exception_message], 'message VERBATIM (bare)'
    assert env[:message_is_bare], 'bare raise: message == class name'
    assert_match(/bare exception/, env[:warning])
    assert_equal 'definition_error', env[:verdict]
    assert_equal 1, bad[:failed_members]
    assert_equal 3, bad[:total_members]
    assert bad[:materialized][:bytes].nil?, 'no payload for the failed member'
  end

  def test_error_envelope_execution_error_for_non_scout_exception
    e = StandardError.new('boom')
    env = Cortex::Error.envelope(e, context: { phase: 'unit' })
    assert_equal 'execution_error', env[:verdict]
    assert_equal 'boom', env[:exception_message]
    refute env[:message_is_bare]

    pe = ParameterException.new('missing input')
    env2 = Cortex::Error.envelope(pe, context: {})
    assert_equal 'argument_error', env2[:verdict]
  end

  # ------------------------------------------------------------------
  # §2.4 resolution
  # ------------------------------------------------------------------
  def test_resolve_literal_short_path_and_var_jobs_prefix
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    first = run3('Step3A', 'echo', %w[FOXO1 A2B])
    target = first.find { |r| r[:receiver] == 'FOXO1' }
    full = target[:materialized][:path]

    r1 = Cortex::Properties.resolve_address(target[:address])
    refute r1[:recovered]
    assert_equal full, r1[:step].path.to_s
    assert_equal target[:address], r1[:address]

    r2 = Cortex::Properties.resolve_address(full)
    assert_equal full, r2[:step].path.to_s
    refute r2[:recovered]

    r3 = Cortex::Properties.resolve_address("var/jobs/#{target[:address]}")
    assert_equal full, r3[:step].path.to_s
    refute r3[:recovered]
  end

  def test_resolve_mangled_prefix_recovers_loudly
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    first = run3('Step3A', 'echo', %w[FOXO1])
    target = first.first
    label = target[:address].split('/').last
    mangled = "Step3A/echo/MANGLEDPREFIX_#{label.split('_').last}"

    r = Cortex::Properties.resolve_address(mangled)
    assert r[:recovered], 'recovery pass fired'
    assert_equal target[:materialized][:path], r[:step].path.to_s
    assert r[:recovered_from].to_s =~ /\A[0-9a-f]{16,32}\z/,
           "recovered_from reports the matched hex tail: #{r[:recovered_from].inspect}"
    assert r[:recovered_from].length >= 16
    assert label.end_with?(r[:recovered_from].to_s)
    assert_equal target[:address], r[:address], 'canonical address returned'
  end

  def test_resolve_missing_reports_candidates
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    run3('Step3A', 'echo', %w[FOXO1 MYC])
    e = assert_raises(ParameterException) do
      Cortex::Properties.resolve_address('Step3A/echo/NOPE_deadbeefdeadbeefdeadbeefdeadbeef')
    end
    env = json_message(e)
    assert_equal 'ParameterException', env['exception_class']
    assert env['exception_message'].include?('Cannot resolve address')
    assert_equal 'argument_error', env['verdict']
    candidates = env['context']['candidates']
    assert candidates.any? { |c| c.start_with?('FOXO1_') }
    assert candidates.any? { |c| c.start_with?('MYC_') }
  end

  def test_resolve_ambiguous_suffix_errors_with_both_candidates
    # two runs with the same entity id and different argument sets -> the
    # 16-hex tail is unique per label, so forge an ambiguity by creating
    # two jobs whose labels share a tail: use distinct ids and pass one
    # label's tail against another id's suffix… instead, directly craft
    # two files sharing the last-16-hex inside the property directory.
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    first = run3('Step3A', 'echo', %w[FOXO1])
    dir = File.dirname(first.first[:materialized][:path])
    tail = first.first[:address].split('/').last.split('_').last[-16, 16]
    twin = File.join(dir, "TWINPREFIX_ffff#{tail}")
    FileUtils.touch(twin)

    e = assert_raises(ParameterException) do
      Cortex::Properties.resolve_address("Step3A/echo/OTHERPREFIX_#{tail}")
    end
    env = json_message(e)
    assert env['exception_message'].include?('Ambiguous')
    cands = env['context']['candidates']
    assert_equal 2, cands.length
    assert cands.include?('TWINPREFIX_ffff' + tail)
    assert cands.any? { |c| c.start_with?('FOXO1_') }
  ensure
    FileUtils.rm_f(twin) if defined?(twin)
  end

  # ------------------------------------------------------------------
  # update + staleness
  # ------------------------------------------------------------------
  def test_update_cleans_and_recomputes_same_address
    define('Step3A', 'upper', body: 'entity.to_s + "-u1"')
    r1 = run3('Step3A', 'upper', 'Tp53')
    assert_equal 'Tp53-u1', r1[:value]
    Cortex.update_property('Step3A', 'upper', expected_version: 1,
                           body: 'entity.to_s + "-u2"', agent: 't', job: 't')
    r2 = run3('Step3A', 'upper', 'Tp53')
    assert_equal 'Tp53-u2', r2[:value]
    assert_not_equal r1[:address], r2[:address],
                     'definition change moves the address (identity inputs)'
  end

  def test_named_list_staleness_recomputes
    define('Step3A', 'echo', body: '"E:" + entity.to_s')
    Cortex.write_list('Step3A', 'panel', %w[FOXO1 MYC])
    r1 = run3('Step3A', 'echo', { list: 'Step3A/panel' })
    info_before = r1.collect { |x| File.mtime(x[:info_path]) }

    # make the list file NEWER than the done Steps -> stale, recompute
    list_path = File.join(LIBDIR, 'var', 'cortex', 'lists', 'Step3A', 'panel')
    assert File.exist?(list_path)
    FileUtils.touch(list_path)
    future = Time.now + 5
    File.utime(future, future, list_path)

    r2 = run3('Step3A', 'echo', { list: 'Step3A/panel' })
    # same addresses (same inputs), but the jobs were re-run: fresh .info
    assert_equal r1.collect { |x| x[:address] },
                 r2.collect { |x| x[:address] }
    info_after = r2.collect { |x| File.mtime(x[:info_path]) }
    assert info_after.zip(info_before).all? { |a, b| a > b },
           'staleness cleaned + recomputed the member jobs at the same address'
    assert r2.all? { |x| x[:status] == :done }
  end
end
