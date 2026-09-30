# Focused integration tests for in-memory provenance at the artifact-write seam.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')
require 'fileutils'
require 'json'

class TestCortexTaskWriteProvenance < Test::Unit::TestCase
  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "write-provenance-#{Process.pid}-#{object_id}"))
    FileUtils.rm_rf(@scratch)
    FileUtils.mkdir_p(@scratch)
    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    Dir.chdir(@scratch)
    ENV['SCOUT_CHAT_DIR'] = @scratch
    Cortex.reset_cortex!
    Cortex.configure_cortex!
  end

  def teardown
    ENV['SCOUT_CHAT_DIR'] = @old_anchor
    Dir.chdir(@old_pwd)
    Cortex.reset_cortex!
    FileUtils.rm_rf(@scratch)
  end

  def write_step(path, content: 'artifact body', mode: 'replace')
    Cortex.job(:cortex_write, nil, path: path, content: content, mode: mode, agent: 'phase7-test')
  end

  def test_successful_write_records_producing_operation_and_version_reference
    artifact = "phase7/write-#{Process.pid}-#{object_id}.md"
    step = write_step(artifact)
    output = step.run
    execution = Cortex::Execution.for_task_step(step)

    assert_equal "Artifact written: #{artifact} (13 bytes, v1)", output
    assert_not_nil execution
    assert_equal 1, execution.operations.length
    operation = execution.operations.first
    assert_same execution, operation.execution
    assert_equal 'write', operation.name
    assert_equal ['artifacts', artifact, 1, nil], operation.resource_reference.identity

    metadata = JSON.parse(File.read(Cortex.artifact_meta_path(artifact)))
    version = metadata.fetch('versions').last
    assert_equal step.short_path.to_s, version['job']
    assert_equal 'phase7-test', version['agent']
    assert_equal 'replace', version['mode']
    assert_equal 13, version['size']

    read_step = Cortex.job(:cortex_read, nil, name: artifact, type: 'artifacts', start_line: 1, lines: 1)
    read_output = read_step.run
    read_execution = Cortex::Execution.for_task_step(read_step)
    assert_match(/artifact body/, read_output)
    assert_equal ['read'], read_execution.operations.collect(&:name)
    refute_same execution, read_execution
    assert_equal operation.resource_reference.identity, read_execution.operations.first.resource_reference.identity
  ensure
    cleanup_artifact(artifact)
  end

  def test_checkpoint_bearing_write_preserves_metadata_and_records_version_edge
    artifact = "phase7/checkpoint-#{Process.pid}-#{object_id}.md"
    step = Cortex.job(:cortex_write, nil, path: artifact, content: 'checkpoint body', mode: 'replace', agent: 'phase7-test')
    context = {conversation: 'phase7/provenance', call_id: 'call-write-7', function_name: 'cortex_write'}
    attached = Cortex::RequestContext.attach(step, context)

    output = attached.run
    execution = Cortex::Execution.for_task_step(attached)
    metadata = JSON.parse(File.read(Cortex.artifact_meta_path(artifact)))
    version = metadata.fetch('versions').last

    assert_equal "Artifact written: #{artifact} (15 bytes, v1)", output
    assert_equal 1, execution.operations.length
    assert_equal ['artifacts', artifact, 1, nil], execution.operations.first.resource_reference.identity
    assert_equal attached.short_path.to_s, version['job']
    assert_equal 'phase7-test', version['agent']
    assert_equal 'replace', version['mode']
    assert_equal({'call_id' => 'call-write-7', 'function_name' => 'cortex_write'}, version['checkpoint'])
    assert_equal version['checkpoint']['call_id'], context[:call_id]
    assert_equal version.length, 7, 'existing durable version metadata shape is preserved'
  ensure
    cleanup_artifact(artifact)
  end

  def test_failed_write_does_not_record_successful_operation
    step = write_step('../invalid.md')
    assert_raise(ScoutException) { step.run }

    execution = Cortex::Execution.for_task_step(step)
    assert_not_nil execution
    assert_empty execution.operations
  end

  private

  def cleanup_artifact(name)
    return unless name
    Cortex.resource_paths(:artifacts, name).each { |path, _map| FileUtils.rm_rf(path) }
    Cortex.read_maps.each do |map|
      Cortex.sidecar_paths(:artifacts, name, map).each { |path| FileUtils.rm_rf(path) }
    end
  end
end
