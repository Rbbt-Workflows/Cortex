# Focused integration tests for in-memory provenance at the bounded artifact-read seam.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')
require 'fileutils'

class TestCortexTaskReadProvenance < Test::Unit::TestCase
  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "read-provenance-#{Process.pid}-#{object_id}"))
    FileUtils.rm_rf(@scratch)
    @project = File.join(@scratch, 'project')
    FileUtils.mkdir_p(@project)
    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    Dir.chdir(@project)
    ENV['SCOUT_CHAT_DIR'] = @project
    Cortex.reset_cortex!
    Cortex.configure_cortex!
  end

  def teardown
    ENV['SCOUT_CHAT_DIR'] = @old_anchor
    Dir.chdir(@old_pwd)
    Cortex.reset_cortex!
    FileUtils.rm_rf(@scratch)
  end

  def read_step(name, start_line: 2, lines: 1)
    Cortex.job(:cortex_read, nil, name: name, type: 'artifacts', start_line: start_line, lines: lines)
  end

  def test_bounded_artifact_read_records_distinct_invocation_without_changing_output
    artifact = "page/record.md"
    Cortex.write_artifact(artifact, "first\nsecond\nthird\n", :replace, job: 'fixture', agent: 'test')
    first_step = read_step(artifact)
    # A different bounded page gives Scout a distinct job identity while both
    # reads still target the same logical artifact.
    second_step = read_step(artifact, start_line: 3)

    first_output = first_step.run
    first_execution = Cortex::Execution.for_task_step(first_step)
    second_output = second_step.run
    second_execution = Cortex::Execution.for_task_step(second_step)

    assert_equal "# lines 2-2 of 4 (next: 3)\nsecond", first_output
    assert_equal "# lines 3-3 of 4 (next: 4)\nthird", second_output.to_s
    assert_not_nil first_execution
    assert_not_nil second_execution
    assert !first_execution.equal?(second_execution)
    assert first_execution.step.equal?(first_step)
    assert second_execution.step.equal?(second_step)
    assert_equal 1, first_execution.operations.length
    assert_equal 1, second_execution.operations.length
    first_operation = first_execution.operations.first
    second_operation = second_execution.operations.first
    refute_same first_operation, second_operation
    assert_same first_execution, first_operation.execution
    assert_same second_execution, second_operation.execution
    assert_equal ['artifacts', artifact, 1, nil], first_operation.resource_reference.identity
    assert_equal first_operation.resource_reference.identity.to_s, second_operation.resource_reference.identity.to_s
  end

  def test_read_operation_does_not_claim_version_not_provided_by_seam
    Cortex.write_artifact('page/unversioned.md', "x\n", :replace, job: 'fixture', agent: 'test')
    step = read_step('page/unversioned.md', start_line: 1, lines: 1)
    step.run
    reference = Cortex::Execution.for_task_step(step).operations.first.resource_reference

    assert_equal ['artifacts', 'page/unversioned.md', 1, nil], reference.identity
  end
end
