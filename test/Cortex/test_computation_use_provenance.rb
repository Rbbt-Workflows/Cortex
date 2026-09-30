require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'securerandom'

class TestCortexComputationUseProvenance < Test::Unit::TestCase
  def setup
    FileUtils.rm_rf(SCRATCH) if File.directory?(SCRATCH)
    [LIBDIR, USERDIR].each { |directory| FileUtils.mkdir_p(directory) }
    Path.path_maps[:current] = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
    Path.path_maps[:lib] = File.join(LIBDIR, '{TOPLEVEL}', '{SUBPATH}')
    Path.path_maps[:user] = File.join(USERDIR, '{TOPLEVEL}', '{SUBPATH}')
    Scout::Config::CACHE['cortex'] = [[['read_maps'], 'lib,current,user'],
                                      [['write_map'], 'current']]
    Cortex.instance_variable_set(:@entity_root, Path.setup('var'))
    @type = "ComputationUse#{Process.pid}#{SecureRandom.hex(4)}"
    @counter = File.join(SCRATCH, 'compute-count.txt')
  end

  def teardown
    FileUtils.rm_rf(SCRATCH)
    Cortex.managed_entity_registry.delete(@type) if Cortex.respond_to?(:managed_entity_registry)
  end

  def test_two_native_consumers_record_use_of_one_cached_producer_and_recover_fresh
    body = "File.open(#{@counter.dump}, 'a') { |file| file.puts('computed') }; 'cached-value'"
    Cortex.define_property(@type, 'compute', body: body, description: 'fixture',
                           property_type: :single, result_type: 'string', arguments: [],
                           dependencies: [], agent: 'test', job: 'computation-use-test')

    producer_receipt = Cortex::Properties.run_property(entity_type: @type, property: 'compute',
                                                       receiver: 'entity-1', arguments: {})
    producer_address = producer_receipt.fetch(:address)
    producer = Step.load(producer_receipt.fetch(:materialized).fetch(:path))
    assert_equal :done, producer.status
    assert_equal 1, File.readlines(@counter).length, 'producer body ran exactly once'

    consumers = [5000, 5001].collect do |max_bytes|
      step = Cortex.job(:cortex_result, nil, address: producer_address,
                        projection: 'value', max_bytes: max_bytes)
      result = step.run
      assert_equal 'cached-value', result.fetch(:value)
      step
    end
    consumer_addresses = consumers.collect { |step| step.short_path.to_s }
    assert_equal 2, consumer_addresses.uniq.length, 'the native consumer jobs are distinct'

    # Repeated reads of both durable event files in another Ruby process check
    # that neither the in-memory Execution pointer nor this process's cache is
    # required to recover the producer link.
    script = <<~'RUBY'
      require File.expand_path('workflow')
      require 'json'
      puts JSON.generate(ARGV.map { |address| Cortex.computation_use_events(address) })
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I.', '-e', script,
                                             *consumers.collect { |step| step.path.to_s }, chdir: ROOT)
    assert_predicate status, :success?, stderr
    event_groups = JSON.parse(stdout)
    assert_equal [1, 1], event_groups.map(&:length)
    events = event_groups.flatten
    assert_equal 2, events.map { |event| event.fetch('id') }.uniq.length
    assert_equal consumer_addresses.sort,
                 events.map { |event| event.dig('execution', 'address') }.sort
    assert events.all? { |event| event.fetch('kind') == 'use_computation' }
    assert_equal [producer_address, producer_address],
                 events.map { |event| event.dig('computation', 'address') }
    definition = producer_receipt.fetch(:definition)
    events.each do |event|
      assert_equal({ 'name' => "#{@type}/compute", 'version' => definition.fetch(:version),
                     'digest' => definition.fetch(:digest) },
                   event.dig('computation', 'definition'))
    end

    assert_equal 1, File.readlines(@counter).length, 'reading the cached result did not recompute it'
    assert_equal :done, Step.load(producer.path).status, 'the one producer Step remains the shared result'
  end
end
