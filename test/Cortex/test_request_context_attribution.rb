# Focused end-to-end attribution tests through Scout-AI Agent#ask and
# Agent#ask_conversation. These use local chat-task fixtures; no provider or
# mocked context-construction function is involved.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')

class TestCortexRequestContextAttribution < Test::Unit::TestCase
  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch',
                                           "request-attribution-#{Process.pid}-#{rand(1_000_000)}"))
    FileUtils.mkdir_p(@scratch)
    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    ENV['SCOUT_CHAT_DIR'] = @scratch
    Dir.chdir(@scratch)
    Cortex.reset_cortex!
    @executions = []
  end

  def teardown
    ENV['SCOUT_CHAT_DIR'] = @old_anchor
    Dir.chdir(@old_pwd)
    Cortex.reset_cortex!
    FileUtils.rm_rf(@scratch)
  end

  def test_root_and_multilevel_delegation_keep_callers_root_chat_and_native_step_identity
    executions = @executions
    workflow = Workflow.annonymous_workflow("RequestAttributionProbe#{Process.pid}") do
      input :chat, :string, 'Serialized agent chat'
      task :ask => :chat do |chat|
        envelope = info[:request_context] || info['request_context']
        fields = LLM::RequestContext.fields_from(envelope)
        executions << {fields: fields, job: short_path.to_s}
        Chat.setup([{role: 'assistant', content: "reply #{short_path}"}])
      end
    end

    root_file = File.join(@scratch, 'root.chat')
    root = LLM::Agent.new(workflow: workflow, start_chat: Chat.setup([]))
    root.save_file = root_file
    root.request_context = {call_id: 'root-call', function_name: 'root_tool'}
    root.user('root invocation')
    root.ask

    template = LLM::Agent.new(workflow: workflow, start_chat: Chat.setup([]))
    child = root.ask_conversation('Worker', 'child invocation', conversation: 'one',
                                  inherit: 'none', template: template)
    child.ask
    grandchild = child.ask_conversation('Reviewer', 'grandchild invocation',
                                        conversation: 'one', inherit: 'none',
                                        template: template)
    grandchild.ask

    assert_equal 3, executions.length
    root_call, child_call, grandchild_call = executions
    [root_call, child_call, grandchild_call].each do |call|
      assert_equal root_file, call[:fields][:main_chat]
      assert_equal 'root-call', call[:fields][:call_id]
      assert_equal 'root_tool', call[:fields][:function_name]
    end
    assert_equal root_file, root_call[:fields][:caller]
    assert_equal child.save_file.to_s, child_call[:fields][:caller]
    assert_equal grandchild.save_file.to_s, grandchild_call[:fields][:caller]

    # These are native Scout Steps produced by each agent's ask, not synthetic
    # caller IDs. Their native workflow/task/job identities remain distinct.
    jobs = executions.map { |execution| execution[:job] }
    assert_equal 3, jobs.uniq.length
    jobs.each { |job| assert_match(%r{/ask/}, job) }
    assert jobs.all? { |job| job.start_with?(workflow.name.to_s + '/') }, jobs.inspect
  end

  def test_unsaved_delegated_child_retains_inherited_caller_today
    executions = @executions
    workflow = Workflow.annonymous_workflow("UnsavedRequestAttributionProbe#{Process.pid}") do
      input :chat, :string, 'Serialized agent chat'
      task :ask => :chat do |chat|
        fields = LLM::RequestContext.fields_from(info[:request_context] || info['request_context'])
        executions << fields
        Chat.setup([{role: 'assistant', content: 'reply'}])
      end
    end

    root_file = File.join(@scratch, 'saved-root.chat')
    root = LLM::Agent.new(workflow: workflow, start_chat: Chat.setup([]))
    root.save_file = root_file
    root.request_context = {caller: root_file, main_chat: root_file}
    template = LLM::Agent.new(workflow: workflow, start_chat: Chat.setup([]))
    child = root.ask_conversation('Worker', 'unsaved child', conversation: 'one',
                                  inherit: 'none', template: template)
    child.save_file = nil
    child.ask

    assert_equal 1, executions.length
    # Characterization, not endorsement: Agent#ask only overwrites caller when
    # save_file is truthy, so this unsaved child presently carries its parent's
    # caller value. Its native job remains the child ask Step.
    assert_equal root_file, executions.first[:caller]
    assert_equal root_file, executions.first[:main_chat]
    # Agent#ask does not retain its returned job on the child agent.
    assert_equal 1, executions.length
  end
end
