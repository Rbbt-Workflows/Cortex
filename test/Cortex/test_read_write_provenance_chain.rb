require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')
require 'json'
require 'open3'
require 'rbconfig'
require 'fileutils'
require 'securerandom'
require 'Cortex/execution_operation'

class TestCortexReadWriteProvenanceChain < Test::Unit::TestCase
  def setup
    @name = "provenance-chain/#{Process.pid}-#{SecureRandom.hex(8)}.md"
    @target = Cortex.resource_path(:artifacts, @name, :current)
    FileUtils.mkdir_p(File.dirname(@target))
    Cortex.write_artifact(@name, "first value\n", :replace, job: 'fixture', agent: 'test')
    @meta, @files = Cortex.sidecar_paths(:artifacts, @name, :current)
  end

  def teardown
    FileUtils.rm_rf(@target)
    FileUtils.rm_rf(@meta)
    FileUtils.rm_rf(@files)
  end

  def test_task_read_then_write_persists_linked_chain_and_fresh_process_recovers_it
    read_inputs = {name: @name, type: 'artifacts', last: nil, range: nil, start_line: 1, lines: 20}
    read_step = Cortex.job(:cortex_read, nil, **read_inputs)
    assert_match(/first value/, read_step.run)
    read_op = Cortex::Execution.for_task_step(read_step).operations.first
    assert_equal 'read', read_op.name
    assert_equal 1, read_op.resource_reference.version
    assert_equal read_step.short_path, read_op.computation.address
    read_step_id = read_step.short_path

    write_inputs = {path: @name, content: 'second value', mode: 'append', agent: 'local-test'}
    write_step = Cortex.job(:cortex_write, nil, **write_inputs)
    assert_match(/v2/, write_step.run)
    write_op = Cortex::Execution.for_task_step(write_step).operations.first
    assert_equal 'write', write_op.name
    write_step_id = write_step.short_path

    script = <<~'RUBY'
      require File.expand_path('workflow')
      require 'Cortex/execution_operation'
      name = ARGV.fetch(0)
      puts JSON.generate(Cortex.artifact_provenance(name))
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I.', '-e', script, @name, chdir: ROOT)
    assert_predicate status, :success?, stderr
    operations = JSON.parse(stdout).fetch('operations')
    assert_equal %w[read write], operations.map { |operation| operation.fetch('kind') }
    read, write = operations
    assert_equal [1, 2], operations.map { |operation| operation.dig('resource', 'version') }
    assert_equal read_step_id, read.dig('execution', 'job')
    assert_equal write_step_id, write.dig('execution', 'job')
    assert_equal read_step_id, read.fetch('job_receipt')
    assert_equal write_step_id, write.fetch('job_receipt')
    assert_equal read.fetch('id'), write.fetch('input_operation_id')
    assert_equal read.fetch('resource'), write.fetch('input_resource')
    assert_equal 'append', JSON.parse(File.read(@meta)).dig('versions', 1, 'mode')
    assert_equal 2, JSON.parse(File.read(@meta)).dig('versions').length
  end

  def test_read_then_edit_is_recorded_as_edit_and_linked
    read_step = Cortex.job(:cortex_read, nil, name: @name, type: 'artifacts', start_line: 1, lines: 20)
    read_step.run
    edit_step = Cortex.job(:cortex_edit, nil, name: @name, find: 'first value', replace: 'edited value', all: false, agent: 'local-test')
    assert_match(/v2/, edit_step.run)

    operations = Cortex.artifact_provenance(@name).fetch('operations')
    read, edit = operations
    assert_equal %w[read edit], operations.map { |operation| operation.fetch('kind') }
    assert_equal read.fetch('id'), edit.fetch('input_operation_id')
    assert_equal 2, edit.dig('resource', 'version')
    assert_equal edit_step.short_path.to_s, edit.dig('execution', 'job')
  end
end
