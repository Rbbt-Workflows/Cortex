# Focused tests for the internal execution/operation association model.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')

require 'Cortex/execution_operation'

class TestCortexExecutionOperation < Test::Unit::TestCase
  def workflow_step
    wf = Workflow.annonymous_workflow("OperationProbe#{Process.pid}#{object_id}") do
      task :read => :string do
        'same cached payload'
      end
    end
    wf.job(:read)
  end

  def test_execution_references_exact_step_and_separate_invocations
    step = workflow_step
    first = Cortex::Execution.begin_task(step)
    second = Cortex::Execution.begin_task(step)

    assert_same step, first.step
    assert_same step, second.step
    assert_same second, Cortex::Execution.for_task_step(step)
    refute_same first, second
    assert_equal first.computation.address, second.computation.address
  end

  def test_operation_keeps_logical_reference_and_distinct_execution
    step = workflow_step
    first = Cortex::Execution.new(step: step)
    second = Cortex::Execution.new(step: step)
    reference = Cortex::ResourceReference.new(namespace: :artifacts, name: 'reports/current.md')
    first_operation = Cortex::Operation.new(execution: first, name: :read, resource_reference: reference)
    second_operation = Cortex::Operation.new(execution: second, name: :read, resource_reference: reference)
    first.record_operation(first_operation)
    second.record_operation(second_operation)

    assert_same first, first_operation.execution
    assert_same second, second_operation.execution
    assert_same reference, first_operation.resource_reference
    assert_equal ['artifacts', 'reports/current.md', nil, nil], reference.identity
    assert_equal 1, first.operations.length
    assert_equal 1, second.operations.length
    refute_same first_operation, second_operation
  end

  def test_type_specific_version_identity_is_optional
    artifact = Cortex::ResourceReference.new(namespace: :artifacts, name: 'claims/C42.md', version: 3, digest: 'sha256:abc123')
    property = Cortex::ResourceReference.new(namespace: :entities, name: 'Gene/activity', version: 2, digest: 'sha256:abc123')
    unversioned = Cortex::ResourceReference.new(namespace: :conversations, name: 'research/root')

    assert_equal ['artifacts', 'claims/C42.md', 3, 'sha256:abc123'], artifact.identity
    assert_equal ['entities', 'Gene/activity', 2, 'sha256:abc123'], property.identity
    assert_equal ['conversations', 'research/root', nil, nil], unversioned.identity
  end
end
