# ==========================================================================
# Foreign entity adoption (design §11) — T1..T10
# --------------------------------------------------------------------------
# Self-contained fixture: an in-process EntityWorkflow module stands in for a
# foreign workflow entity type (Finances::Security).  No Finances dependency.
#
# Regimes under test:
#   A  zero Cortex definitions on an adoptable module -> plain-method path
#   B  active Cortex definition -> task path (real Step, address, materialized)
#   C  define over an adopted module -> task path with the NEW body served
#
# ISOLATION: identical to test_entities.rb (workflow loaded by
# test_helper.rb BEFORE the scratch path maps are installed under
# tmp/entity_test_var; entity_root reset to the relative 'var').
# ==========================================================================
require File.expand_path(__FILE__).sub(%r(/test/Cortex/.*), '/test/Cortex/test_helper.rb')
require 'fileutils'
require 'json'
require 'tmpdir'

FileUtils.rm_rf(SCRATCH) if File.directory?(SCRATCH)
[LIBDIR, USERDIR].each { |d| FileUtils.mkdir_p(d) }

Path.path_maps[:current] = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:lib]     = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:user]    = File.join(USERDIR, '{TOPLEVEL}', '{SUBPATH}')
Scout::Config::CACHE['cortex'] = [[['read_maps'], 'lib,current,user'],
                                  [['write_map'], 'current']]
Cortex.instance_variable_set(:@entity_root, Path.setup('var'))

ADOPT_TYPE = 'AdoptSec'.freeze

# The FOREIGN fixture: a pre-existing EntityWorkflow module with real instance
# methods (regime A surface), exactly how Finances::Security appears.
module AdoptSec
  extend EntityWorkflow
end
AdoptSec.name = 'AdoptSec'

module AdoptSec
  def plain_marker
    "PLAIN:" + to_s
  end

  def kw_marker(k: 'x')
    "KW:#{k}:#{to_s}"
  end

  def pos_marker(opts)
    "POS:#{opts['k'] || opts[:k] || '?'}:#{to_s}"
  end
end

module TestForeignAdoptionHelpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', ADOPT_TYPE))
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', 'FreshManaged'))
      FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', ADOPT_TYPE))
      FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', ADOPT_TYPE))
      FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', ADOPT_TYPE))
      FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'lists', ADOPT_TYPE))
    end
    Workflow.job_cache.clear
    Cortex.entity_modules(ADOPT_TYPE).delete 'managed'
    Cortex.entity_modules(ADOPT_TYPE).delete 'foreign'
  end

  def run!(type, property, receiver, arguments: {})
    Cortex::Properties.run_property(entity_type: type, property: property,
                                    receiver: receiver, arguments: arguments)
  end

  def define!(type, property, body, **rest)
    Cortex.define_property(type, property,
      body: body, description: rest.delete(:description) || 't',
      property_type: rest.delete(:property_type) || 'single',
      result_type: rest.delete(:result_type) || 'string',
      arguments: rest.delete(:arguments) || [],
      dependencies: rest.delete(:dependencies) || [],
      agent: rest.delete(:agent) || 't', job: rest.delete(:job) || 'test_adoption')
  end

  # §2.6 envelope JSON from the raised ParameterException message.
  def envelope_of(error)
    JSON.parse(error.message)
  rescue JSON::ParserError
    nil
  end

  def assert_32hex(label)
    assert_match(/\A[A-Za-z0-9_.:-]+_[0-9a-f]{32}(\.\w+)?\z/, label, label.inspect)
  end
end

class TestForeignEntityAdoption < Test::Unit::TestCase
  include TestForeignAdoptionHelpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # --------------------------------------------------------------- regime A
  # T1: zero-definition plain-method receipt shape (§11.2 fallback keys).
  def test_t1_zero_definition_plain_method_receipt
    r = run!(ADOPT_TYPE, 'plain_marker', 'GOOG')
    assert_equal 0, r[:definition][:version]
    assert_nil r[:definition][:digest]
    assert_equal 'GOOG', r[:receiver], 'receiver is POPULATED (§2.7)'
    assert_nil r[:address]
    assert_nil r[:materialized]
    assert_nil r[:info_path]
    assert_equal 'PLAIN:GOOG', r[:value], 'raw plain-method value'
  end

  # --------------------------------------------------------------- regime C
  # T2: define-on-foreign -> task-path receipt (real Step on disk).
  def test_t2_define_on_foreign_yields_task_path_receipt
    define!(ADOPT_TYPE, 'fee_mark', '"FEE:" + entity.to_s')
    r = run!(ADOPT_TYPE, 'fee_mark', 'GOOG')
    assert r[:definition][:version] >= 1, 'version >= 1'
    assert_match(/\A[0-9a-f]{64}\z/, r[:definition][:digest].to_s, '64-hex digest')
    segments = r[:address].to_s.split('/')
    assert_equal 3, segments.length, "3-segment address: #{r[:address]}"
    assert_32hex segments.last
    assert_equal 'FEE:GOOG', r[:value]
    assert File.exist?(r[:materialized][:path]), 'materialized path on disk'
    assert File.exist?(r[:info_path]), 'info sidecar on disk'
  end

  # T3: redefinition serves the NEW body at a MOVED address.
  def test_t3_redefinition_serves_new_body_at_moved_address
    define!(ADOPT_TYPE, 'mark', '"MARK-A:" + entity.to_s')
    r1 = run!(ADOPT_TYPE, 'mark', 'GOOG')
    assert r1[:value].start_with?('MARK-A:')

    Cortex.update_property(ADOPT_TYPE, 'mark', expected_version: 1,
                           body: '"MARK-B:" + entity.to_s', agent: 't', job: 'test_adoption')
    r2 = run!(ADOPT_TYPE, 'mark', 'GOOG')
    assert r2[:value].start_with?('MARK-B:'), 'serves body B after update'
    assert_equal 2, r2[:definition][:version]
    refute_equal r1[:address], r2[:address], 'address digest moved with the body'
  end

  # T4: fresh MANAGED type roots at the checkout var/jobs even from a
  # subdirectory CWD (pins the step-3 placement fix, §11.4).
  def test_t4_managed_type_roots_at_checkout_var_jobs_from_subdir
    define!('FreshManaged', 'mark', '"M:" + entity.to_s')
    Dir.mktmpdir do |sub|
      Dir.chdir(sub) do
        r = run!('FreshManaged', 'mark', 'Tp53')
        assert_equal 3, r[:address].to_s.split('/').length
        rooted = r[:materialized][:path].to_s
        assert_match(%r{/var/jobs/FreshManaged/mark/Tp53_[0-9a-f]{32}}, rooted)
        assert_equal 'M:Tp53', r[:value]
      end
    end
  end

  # ------------------------------------------------------------- §2.6 gates
  # T5: argument-validation failure RAISES (never a fallback receipt).
  def test_t5_argument_validation_envelope_not_swallowed
    define!(ADOPT_TYPE, 'echo', 'entity.to_s',
            arguments: [{ 'name' => 'k', 'type' => 'string' }])
    begin
      run!(ADOPT_TYPE, 'echo', 'GOOG', arguments: { 'nope' => 1 })
      flunk 'argument mismatch must raise, not fall back'
    rescue ScoutException => e
      env = envelope_of(e)
      assert env, 'raised message carries the §2.6 envelope JSON'
      assert_match(/Unknown argument/, env['exception_message'].to_s)
      assert env['verdict'], ' envelope verdict present'
    end
  end

  # T6: a genuine body failure RAISES (definition_error), never falls back.
  def test_t6_body_failure_raises_not_falls_back
    define!(ADOPT_TYPE, 'boom', "raise ScoutException, 'kaboom-mark'")
    r = run!(ADOPT_TYPE, 'boom', 'GOOG')
    env = r[:error]
    assert env, '§2.6 envelope present on the error receipt'
    assert_equal 'definition_error', env[:verdict]
    assert_match(/kaboom-mark/, env[:exception_message].to_s)
    assert r[:address], 'task-path shape kept (address present, no fallback)'
    assert_equal :error, r[:status]
  end

  # --------------------------------------------- plain-path arguments rule
  # T7: Method#parameters introspection (§11.3).
  def test_t7_plain_path_argument_dispatch_rules
    # empty Hash -> zero args
    assert_equal 'PLAIN:MSFT', run!(ADOPT_TYPE, 'plain_marker', 'MSFT')[:value]

    # keyword method receives keywords
    r = run!(ADOPT_TYPE, 'kw_marker', 'MSFT', arguments: { 'k' => 'v' })
    assert_equal 'KW:v:MSFT', r[:value]

    # positional method receives the Hash as ONE positional argument
    r = run!(ADOPT_TYPE, 'pos_marker', 'MSFT', arguments: { 'k' => 'w' })
    assert_equal 'POS:w:MSFT', r[:value]

    # unsatisfiable: zero-arity method + non-empty arguments -> argument_error
    begin
      run!(ADOPT_TYPE, 'plain_marker', 'MSFT', arguments: { 'k' => 'v' })
      flunk 'unsatisfiable arguments must raise, not be swallowed'
    rescue ScoutException => e
      assert envelope_of(e) || e.message =~ /argument/i,
             "§2.6 envelope or argument error message: #{e.message[0, 120]}"
    end
  end

  # ------------------------------------------------------------ named lists
  # T8: task-path fan-out vs plain-path per-member execution.
  def test_t8_named_list_receivers_on_both_paths
    Cortex.write_list(ADOPT_TYPE, 'panel', %w[GOOG MSFT])
    # task path: one receipt per member
    define!(ADOPT_TYPE, 'fee_mark', '"FEE:" + entity.to_s')
    outs = run!(ADOPT_TYPE, 'fee_mark', { list: "#{ADOPT_TYPE}/panel" })
    assert_equal 2, outs.length, 'fan-out: one receipt per member'
    assert_equal %w[FEE:GOOG FEE:MSFT], outs.collect { |r| r[:value] }
    assert outs.all? { |r| r[:address].to_s.split('/').length == 3 }

    # plain path: per-member execution, one fallback receipt each
    Cortex.entity_modules(ADOPT_TYPE).delete 'managed'
    FileUtils.rm_rf(File.join(LIBDIR, 'var', 'cortex', 'entities', ADOPT_TYPE))
    FileUtils.rm_rf(File.join(LIBDIR, 'var', 'cortex', 'entities', '.meta', ADOPT_TYPE))
    outs2 = run!(ADOPT_TYPE, 'plain_marker', { list: "#{ADOPT_TYPE}/panel" })
    assert_equal 2, outs2.length, 'plain path: one fallback receipt per member'
    assert_equal %w[PLAIN:GOOG PLAIN:MSFT], outs2.collect { |r| r[:value] }
    assert outs2.all? { |r| r[:definition] == { version: 0, digest: nil } }
    assert outs2.all? { |r| r[:address].nil? }
  end

  # ------------------------------------------------------------- staleness
  # T9: covered-by-cite (same engine path, already asserted):
  #   test/Cortex/test_properties_run.rb#test_named_list_staleness_recomputes
  # pins the done-result-older-than-list-file recompute.  Here we assert only
  # the adoption-facing leg: a named list on an ADOPTED type actually
  # materializes (so the staleness rule has something to act on).
  def test_t9_named_list_on_adopted_type_materializes_for_staleness_rule
    define!(ADOPT_TYPE, 'fee_mark', '"FEE:" + entity.to_s')
    Cortex.write_list(ADOPT_TYPE, 'panel', %w[GOOG MSFT])
    r1 = run!(ADOPT_TYPE, 'fee_mark', { list: "#{ADOPT_TYPE}/panel" })
    list_path = File.join(LIBDIR, 'var', 'cortex', 'lists', ADOPT_TYPE, 'panel')
    assert File.exist?(list_path), 'list file exists'
    assert r1.all? { |x| File.exist?(x[:info_path]) }, 'done member Steps exist'

    FileUtils.touch(list_path)
    future = Time.now + 5
    File.utime(future, future, list_path)
    r2 = run!(ADOPT_TYPE, 'fee_mark', { list: "#{ADOPT_TYPE}/panel" })
    assert_equal r1.collect { |x| x[:address] }, r2.collect { |x| x[:address] },
                 'same addresses (same inputs)'
    assert r2.all? { |x| x[:status] == :done }, 'stale members recomputed done'
    assert r2.all? { |x| File.exist?(x[:info_path]) },
           'adopted-type list run materializes (staleness rule applies)'
  end

  # --------------------------------------------------------- eviction hook
  # T10: after define/update no memo key carries the sanitized
  # Task_job_<property>: prefix (step-5 repaired hook; step-4 H2 evidence).
  def test_t10_define_and_update_evict_task_job_memo_keys
    prefix = 'Task_job_mark:'
    run!(ADOPT_TYPE, 'plain_marker', 'GOOG') # irrelevant: no memo entry
    Workflow.job_cache.clear

    define!(ADOPT_TYPE, 'mark', '"MARK-A:" + entity.to_s')
    run!(ADOPT_TYPE, 'mark', 'GOOG')
    assert Workflow.job_cache.keys.collect(&:to_s).any? { |k| k.include?(prefix) },
           'memo entry existed before the hook runs'

    Cortex.update_property(ADOPT_TYPE, 'mark', expected_version: 1,
                           body: '"MARK-B:" + entity.to_s', agent: 't', job: 'test_adoption')
    residual = Workflow.job_cache.keys.collect(&:to_s).select { |k| k.include?(prefix) }
    assert_equal [], residual, 'eviction hook left no stale Task_job_mark: keys'
  end
end
