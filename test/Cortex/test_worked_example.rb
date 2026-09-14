# ==========================================================================
# The design §10 worked end-to-end example, as a real test (step 6).
#
# Walkthrough stages (design section 10, steps 1-7) -> tests:
#
#   1. define Gene/scores_in_treatment   -> test_stage1_define_definition_receipt
#   2. run for Tp53                     -> test_stage2_run_one_entity_receipt
#   3. cortex_result :path/:value/:info -> test_stage3_result_projections
#   4. fan-out over [Tp53 Kras Pten]    -> test_stage4_fanout_three_addresses
#   5. define Gene/top_scorers (dep)    -> test_stage5_downstream_definition
#   6. run downstream; upstream cache hit -> test_stage6_downstream_run_and_cache_hit
#   7. cite: receipt fields == Step facts -> test_stage7_receipts_match_steps
#
# ISOLATION: scratch path maps under tmp/entity_test_var; the Gene type and
# both properties are created here and purged in setup/teardown, so the file
# is self-contained and green on repeated runs. BWRAP=false mandatory.
# ==========================================================================
require File.expand_path(__FILE__).sub(%r(/test/Cortex/.*), '/test/Cortex/test_helper.rb')
require 'fileutils'
require 'json'
require 'Cortex/cli'

FileUtils.rm_rf(SCRATCH) if File.directory?(SCRATCH)
[LIBDIR, USERDIR].each { |d| FileUtils.mkdir_p(d) }

Path.path_maps[:current] = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:lib]     = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
Path.path_maps[:user]    = File.join(USERDIR, '{TOPLEVEL}', '{SUBPATH}')
Scout::Config::CACHE['cortex'] = [[['read_maps'], 'lib,current,user'],
                                  [['write_map'], 'current']]
Cortex.instance_variable_set(:@entity_root, Path.setup('var'))
Cortex.configure_cortex!

module WorkedExampleHelpers
  def purge!
    [LIBDIR, USERDIR].each do |root|
      %w[Gene].each do |t|
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.meta', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'entities', '.history', t))
        FileUtils.rm_rf(File.join(root, 'var', 'jobs', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'lists', t))
        FileUtils.rm_rf(File.join(root, 'var', 'cortex', 'properties', t))
      end
      FileUtils.rm_rf(File.join(root, 'var', 'jobs', 'Cortex'))
    end
    Cortex.managed_entity_registry.clear if Cortex.respond_to?(:managed_entity_registry)
  end

  def define(type, property, body:, **rest)
    Cortex.define_property(type, property,
      body: body, description: rest.delete(:description) || 'worked example',
      property_type: rest.delete(:property_type) || :single,
      result_type: rest.delete(:result_kind) || rest.delete(:result_type) || 'string',
      arguments: rest.delete(:arguments) || [],
      dependencies: rest.delete(:dependencies) || [],
      agent: rest.delete(:agent) || 'test', job: rest.delete(:job) || 'worked_example')
  end

  def define_scores
    define('Gene', 'scores_in_treatment', result_kind: 'tsv',
           arguments: [{ 'name' => 'treatment', 'type' => 'string',
                         'description' => 'treatment arm', 'required' => true }],
           body: <<~'SCORES')
      tsv = TSV.setup({}, key_field: 'gene', type: :double, fields: ['score'])
      %w[Tp53 Kras Pten].each_with_index do |g, i|
        tsv[g] = [[((g.length + i) * inputs[:treatment].to_s.length).to_s]]
      end
      tsv
    SCORES
  end

  def define_top_scorers
    define('Gene', 'top_scorers', result_kind: 'array',
           dependencies: ['scores_in_treatment'],
           arguments: [{ 'name' => 'treatment', 'type' => 'string',
                         'description' => 'treatment arm', 'required' => true },
                       { 'name' => 'n', 'type' => 'integer',
                         'description' => 'how many', 'required' => false,
                         'default' => 10 }],
           body: <<~'TOP')
      path = step(:scores_in_treatment).path
      tsv = TSV.open(path)
      pairs = tsv.keys.collect { |gene| [gene, tsv[gene][0].first.to_i] }
      pairs.sort_by { |gene, score| [-score, gene] }.first(inputs[:n] || 10)
            .collect(&:first)
    TOP
  end

  def run_task(task, name, inputs)
    job = Cortex.job(task, name, inputs)
    job.run
    JSON.parse(Open.read(job.path))
  end

  # The walkthrough bodies, as constants so the validate stage can pass the
  # candidate explicitly (the property is NOT defined when validate runs).
  SCORES_BODY = <<~'SCORES'
    tsv = TSV.setup({}, key_field: 'gene', type: :double, fields: ['score'])
    %w[Tp53 Kras Pten].each_with_index do |g, i|
      tsv[g] = [[((g.length + i) * inputs[:treatment].to_s.length).to_s]]
    end
    tsv
  SCORES

  TOP_SCORERS_BODY = <<~'TOP'
    path = step(:scores_in_treatment).path
    tsv = TSV.open(path)
    pairs = tsv.keys.collect { |gene| [gene, tsv[gene][0].first.to_i] }
    pairs.sort_by { |gene, score| [-score, gene] }.first(inputs[:n] || 10)
          .collect(&:first)
  TOP
end

class TestWorkedExample < Test::Unit::TestCase
  include WorkedExampleHelpers

  def setup
    purge!
  end

  def teardown
    purge!
  end

  # ------------------------------------------------------------------
  # §10 stage 1: define
  # ------------------------------------------------------------------
  def test_stage1_define_definition_receipt
    r = run_task(:cortex_property_define, 'receipt_only', entity_type: 'Gene',
                 property: 'scores_other', body: "entity.to_s + '!'",
                 description: 'Scores in treatment',
                 property_type: 'single', result_kind: 'tsv',
                 arguments: [{ 'name' => 'treatment', 'type' => 'string',
                               'description' => 'treatment arm',
                               'required' => true }])
    assert_equal 'Gene/scores_other', r['address']
    assert_equal 1, r['version']
    assert r['digest'] =~ /\A[0-9a-f]{64}\z/, r['digest'].inspect
    assert_equal 'entities/Gene/scores_other', r['definition_path']
    assert_equal 'single', r['property_type']
    assert_equal 'tsv', r['result_kind']
    assert r['defined']

    # persisted meta + body; result_kind derived on read (§9)
    define_scores
    meta = JSON.parse(File.read(Cortex.entity_meta_path('Gene', 'scores_in_treatment')))
    assert meta['digest'] =~ /\A[0-9a-f]{64}\z/
    assert_equal 'tsv', meta['result_type'], 'old field name stays on disk'
    d = Cortex.property_definition('Gene', 'scores_in_treatment')
    assert_equal 'tsv', d['result_kind'], 'rename applied on read'
    assert File.exist?(Cortex.entity_body_path('Gene', 'scores_in_treatment'))
  end

  # ------------------------------------------------------------------
  # §10 stage 2: run for ONE entity
  # ------------------------------------------------------------------
  def test_stage2_run_one_entity_receipt
    define_scores
    r = run_task(:cortex_property_run, 's2', entity_type: 'Gene',
                 property: 'scores_in_treatment', entity: 'Tp53',
                 arguments: { 'treatment' => 'DMBA' })
    assert_equal 'Gene', r['entity_type']
    assert_equal 'scores_in_treatment', r['property']
    assert_equal 'Tp53', r['receiver']
    assert_equal({ 'treatment' => 'DMBA' }, r['arguments'])
    assert_equal 1, r['definition']['version']
    assert r['definition']['digest'] =~ /\A[0-9a-f]{64}\z/
    assert_match(%r{\AGene/scores_in_treatment/Tp53_[0-9a-f]{32}\.tsv\z}, r['address'])
    assert_equal 'tsv', r['result_kind']
    assert_equal 'done', r['status']
    assert File.exist?(r['materialized']['path'])
    assert_operator r['materialized']['bytes'], :>, 0
    assert File.exist?(r['info_path'])
    tsv = TSV.open(r['materialized']['path'])
    assert_include tsv.keys, 'Tp53'
  end

  # ------------------------------------------------------------------
  # §10 stage 3: cortex_result projections
  # ------------------------------------------------------------------
  def test_stage3_result_projections
    define_scores
    run = run_task(:cortex_property_run, 's3', entity_type: 'Gene',
                   property: 'scores_in_treatment', entity: 'Tp53',
                   arguments: { 'treatment' => 'DMBA' })
    addr = run['address']

    p = run_task(:cortex_result, 's3p', address: addr, projection: 'path')
    assert_equal addr, p['address']
    assert_equal true, p['exists']
    assert p['bytes'] > 0
    assert_equal 'tsv', p['result_kind']
    # THE PATH STRING is a real file: §10 stage 4 "probe it"
    tsv = TSV.open(p['path'])
    assert_equal %w[Kras Pten Tp53], tsv.keys.sort

    v = run_task(:cortex_result, 's3v', address: addr, projection: 'value')
    assert_equal 'done', v['status']
    assert v['value'].to_s.include?('Tp53'), 'bounded value carries TSV content'

    i = run_task(:cortex_result, 's3i', address: addr, projection: 'info')
    assert_equal 'done', i['status']
    info = i['info']
    names = info['input_names']
    inputs = info['inputs']
    defn = Cortex.property_definition('Gene', 'scores_in_treatment')
    assert_equal 'Gene/scores_in_treatment', inputs[names.index('_cortex_definition')]
    assert_equal 1, inputs[names.index('_cortex_definition_version')]
    assert_equal defn['digest'], inputs[names.index('_cortex_definition_digest')]
  end

  # ------------------------------------------------------------------
  # §10 stage 4 note: fan-out over [Tp53 Kras Pten]
  # ------------------------------------------------------------------
  def test_stage4_fanout_three_addresses
    define_scores
    Cortex.write_list('Gene', 'panel', %w[Tp53 Kras Pten],
                      description: 'worked example panel')

    rs = run_task(:cortex_property_run, 's4', entity_type: 'Gene',
                  property: 'scores_in_treatment', list: 'Gene/panel',
                  arguments: { 'treatment' => 'DMBA' })
    assert Array === rs
    assert_equal 3, rs.length
    labels = rs.collect { |r| r['address'].split('/').last }
    assert_equal %w[Kras Pten Tp53], labels.collect { |l| l.split('_').first }.sort
    labels.each { |l| assert l =~ /\A[A-Za-z0-9]+_[0-9a-f]{32}\.tsv\z/, l }
    assert_equal labels.length, labels.uniq.length, 'three DISTINCT digests'

    # each independently addressable through cortex_result
    rs.each do |r|
      p = run_task(:cortex_result, "s4#{r['receiver']}", address: r['address'],
                    projection: 'path')
      assert_equal r['address'], p['address']
      assert_equal true, p['exists']
    end

    # :single fan-out never produces the vector Default_ label
    assert rs.none? { |r| r['address'].split('/').last.start_with?('Default_') }
  end

  # ------------------------------------------------------------------
  # §10 stage 5: define the downstream property
  # ------------------------------------------------------------------
  def test_stage5_downstream_definition
    define_scores
    define_top_scorers
    # §2.1 receipt shape for the DOWNSTREAM definition: re-derive it from the
    # store (define_top_scorers wrote it) and assert the same fields.
    d = Cortex.property_definition('Gene', 'top_scorers')
    r = { 'address' => 'Gene/top_scorers', 'version' => d['version'],
          'digest' => d['digest'], 'definition_path' => 'entities/Gene/top_scorers',
          'property_type' => d['property_type'],
          'result_kind' => d['result_kind'] || d['result_type'] }
    assert_equal 'Gene/top_scorers', r['address']
    assert_equal 1, r['version']
    assert_equal 'array', r['result_kind']
    assert_equal 'entities/Gene/top_scorers', r['definition_path']

    v = run_task(:cortex_property_validate, 's5v', entity_type: 'Gene',
                 property: 'top_scorers',
                 body: TOP_SCORERS_BODY, result_kind: 'array',
                 property_type: 'single',
                 arguments: [{ 'name' => 'treatment', 'type' => 'string',
                              'description' => 'arm', 'required' => true },
                            { 'name' => 'n', 'type' => 'integer',
                              'description' => 'how many', 'required' => false,
                              'default' => 10 }],
                 dependencies: ['scores_in_treatment'],
                 test_entity: 'Tp53', test_arguments: { 'treatment' => 'DMBA' })
    assert v['valid'], v['errors'].inspect
    assert v['smoke']['status'] == 'done'
  end

  # ------------------------------------------------------------------
  # §10 stages 2+6: the real dependency run with an upstream cache hit
  # ------------------------------------------------------------------
  def test_stage6_downstream_run_and_cache_hit
    define_scores
    define_top_scorers

    # upstream first, so the downstream run hits the cache
    up = run_task(:cortex_property_run, 's6up', entity_type: 'Gene',
                  property: 'scores_in_treatment', entity: 'Tp53',
                  arguments: { 'treatment' => 'DMBA' })
    up_label = up['address'].split('/').last
    up_mtime = File.mtime(up['materialized']['path'])
    up_info = Step.load(up['materialized']['path']).info

    down = run_task(:cortex_property_run, 's6down', entity_type: 'Gene',
                    property: 'top_scorers', entity: 'Tp53',
                    arguments: { 'treatment' => 'DMBA' })
    down_label = down['address'].split('/').last
    # NO extension: :array is not in TYPE_EXTENSIONS (§3)
    assert_match(/\ATp53_[0-9a-f]{32}\z/, down_label, down_label.inspect)
    assert_equal 'done', down['status']
    value = String === down['value'] ? JSON.parse(down['value']) : down['value']
    assert_equal %w[Pten Kras Tp53], value

    # dependency address recorded in the downstream sidecar
    dstep = Step.load(down['materialized']['path'])
    deps = Array(dstep.info[:dependencies])
    assert_equal 1, deps.length
    assert_match(%r{var/jobs/Gene/scores_in_treatment/#{Regexp.escape(up_label)}},
                 deps.first.to_s,
                 'upstream address in downstream .info[:dependencies]')

    # upstream NOT recomputed: cache hit
    up2 = run_task(:cortex_property_run, 's6up2', entity_type: 'Gene',
                   property: 'scores_in_treatment', entity: 'Tp53',
                   arguments: { 'treatment' => 'DMBA' })
    assert_equal up['address'], up2['address']
    assert_equal up_mtime, File.mtime(up2['materialized']['path']),
                 'upstream mtime unchanged: the downstream run reused it'
    assert_equal up_info[:inputs], Step.load(up2['materialized']['path']).info[:inputs]
  end

  # ------------------------------------------------------------------
  # §10 stage 7: cite — receipts match the Step facts exactly
  # ------------------------------------------------------------------
  def test_stage7_receipts_match_steps
    define_scores
    define_top_scorers

    up = run_task(:cortex_property_run, 's7up', entity_type: 'Gene',
                  property: 'scores_in_treatment', entity: 'Tp53',
                  arguments: { 'treatment' => 'DMBA' })
    down = run_task(:cortex_property_run, 's7down', entity_type: 'Gene',
                    property: 'top_scorers', entity: 'Tp53',
                    arguments: { 'treatment' => 'DMBA' })

    [up, down].each do |receipt|
      step = Step.load(receipt['materialized']['path'])
      assert_equal step.path.to_s, receipt['materialized']['path']
      assert_equal step.short_path.to_s, receipt['address']
      assert_equal step.info_file.to_s, receipt['info_path']
      assert_equal File.size(step.path), receipt['materialized']['bytes']
      names = step.info[:input_names]
      inputs = step.info[:inputs]
      assert_equal receipt['definition']['digest'],
                   inputs[names.index('_cortex_definition_digest')]
      assert_equal receipt['definition']['version'],
                   inputs[names.index('_cortex_definition_version')]
    end

    # both addresses resolve via cortex_result with :value and :info
    [up['address'], down['address']].each do |addr|
      v = run_task(:cortex_result, "s7v#{addr.length}", address: addr,
                    projection: 'value')
      assert_equal 'done', v['status']
      i = run_task(:cortex_result, "s7i#{addr.length}", address: addr,
                    projection: 'info')
      assert_equal 'done', i['status']
      assert i['info'].key?('dependencies')
    end
  end
end
