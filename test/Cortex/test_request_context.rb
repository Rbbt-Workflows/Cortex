# Focused Cortex consumption tests for Scout-AI's projected request context.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')

class TestCortexRequestContext < Test::Unit::TestCase
  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch',
                                           "request-context-#{Process.pid}-#{rand(1_000_000)}"))
    FileUtils.mkdir_p(@scratch)
    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    ENV['SCOUT_CHAT_DIR'] = @scratch
    Dir.chdir(@scratch)
    Cortex.reset_cortex!
    @asked = []
    @old_llm_ask = LLM.method(:ask)
    asked = @asked
    LLM.define_singleton_method(:ask) do |messages, options = {}, &block|
      asked << {messages: Chat.setup(Array(messages)).dup, options: options.dup}
      [{role: 'assistant', content: 'stubbed cortex answer'}]
    end
  end

  def teardown
    LLM.define_singleton_method(:ask, @old_llm_ask)
    ENV['SCOUT_CHAT_DIR'] = @old_anchor
    Dir.chdir(@old_pwd)
    Cortex.reset_cortex!
    FileUtils.rm_rf(@scratch)
  end

  def run_continue(context = nil, chat: nil, conversation: nil, **context_options)
    context ||= context_options unless context_options.empty?
    conversation ||= "probe/request-context-#{Process.pid}-#{rand(1_000_000)}"
    chat ||= Chat.setup([{role: 'user', content: 'continue'}])
    job = LLM.call_workflow(Cortex, :cortex_continue,
                            {conversation: conversation, prompt: 'continue',
                             agent: nil, chat: chat}, request_context: context)
    job.run
    [job, @asked.last]
  end

  def run_agent_turn(context, chat)
    job = LLM.call_workflow(Cortex, :continue, {agent: nil, chat: chat},
                            request_context: context)
    job.run
    [job, @asked.last]
  end

  def test_parent_context_reaches_cortex_continue_child_inference
    _job, call = run_continue(endpoint: 'parent-endpoint', backend: 'parent-backend',
                               model: 'parent-model', configuration: {region: 'parent'})
    assert_equal 'parent-endpoint', call[:options][:endpoint]
    assert_equal 'parent-backend', call[:options][:backend]
    assert_equal 'parent-model', call[:options][:model]
    assert_equal({region: 'parent'}, call[:options][:configuration])
  end

  def test_explicit_child_configuration_overrides_inherited_configuration
    chat = Chat.setup([
      {role: 'endpoint', content: 'child-endpoint'},
      {role: 'backend', content: 'child-backend'},
      {role: 'model', content: 'child-model'},
      {role: 'option', content: 'configuration child-config'},
      {role: 'user', content: 'continue'}
    ])
    _job, call = run_agent_turn(
      {endpoint: 'parent-endpoint', backend: 'parent-backend', model: 'parent-model',
       configuration: 'parent-config'}, chat)
    assert_equal 'child-endpoint', call[:options][:endpoint]
    assert_equal 'child-backend', call[:options][:backend]
    assert_equal 'child-model', call[:options][:model]
    assert_equal 'child-config', call[:options][:configuration]
  end

  def test_inherited_context_is_not_persisted_as_conversation_content
    conversation = "probe/request-context-persist-#{Process.pid}-#{rand(1_000_000)}"
    job, = run_continue({endpoint: 'private-parent-endpoint', backend: 'private-backend',
                         model: 'private-model'}, conversation: conversation)
    path, = Cortex.resolve_resource(:conversations, conversation)
    refute_nil path
    text = File.read(path.to_s)
    assert_not_include text, 'private-parent-endpoint'
    assert_not_include text, 'private-backend'
    assert_not_include text, 'private-model'
    assert_not_include text, 'request_context'
    assert_equal 'private-parent-endpoint', Cortex::RequestContext.for_step(job)[:endpoint]
  end

  def test_context_does_not_change_cortex_job_identity
    inputs = {conversation: "probe/request-context-job-#{Process.pid}", prompt: 'same prompt',
              agent: nil, chat: Chat.setup([{role: 'user', content: 'same'}])}
    first = LLM.call_workflow(Cortex, :cortex_continue, inputs,
                              request_context: {endpoint: 'one'})
    second = LLM.call_workflow(Cortex, :cortex_continue, inputs,
                               request_context: {endpoint: 'two'})
    assert_equal first.path.to_s, second.path.to_s
  end

  def test_identical_cached_calls_keep_context_on_independent_step_objects
    inputs = {conversation: "probe/request-context-isolation-#{Process.pid}",
              prompt: 'same prompt', agent: nil,
              chat: Chat.setup([{role: 'user', content: 'same'}])}
    first = LLM.call_workflow(Cortex, :cortex_continue, inputs,
                              request_context: {endpoint: 'first-endpoint'})
    second = LLM.call_workflow(Cortex, :cortex_continue, inputs,
                               request_context: {endpoint: 'second-endpoint'})

    refute_same first, second
    assert_equal 'first-endpoint', Cortex::RequestContext.for_step(first)[:endpoint]
    assert_equal 'second-endpoint', Cortex::RequestContext.for_step(second)[:endpoint]
    assert_equal first.path.to_s, second.path.to_s
  end

  def test_isolation_rewires_step_inputs_and_preserves_original_state
    workflow = Workflow.annonymous_workflow("RequestContextInputProbe#{Process.pid}") do
      task :source => :string do
        'source'
      end
      input :value, :string
      task :consumer => :string do |value|
        "consumed:#{value}"
      end
    end

    source = workflow.job(:source)
    consumer = workflow.job(:consumer, nil, value: source)
    original_inputs = consumer.inputs.map { |value| value }
    original_dependencies = consumer.dependencies.map { |value| value }
    original_info = consumer.info
    duplicate = Cortex::RequestContext.send(
      :isolated_tree, consumer, {endpoint: 'isolated-endpoint'}
    )

    duplicate_source = duplicate.inputs.first
    assert_kind_of Step, duplicate_source
    refute_same source, duplicate_source
    assert_equal source.path.to_s, duplicate_source.path.to_s
    assert_equal [source], original_inputs
    assert_equal original_dependencies, consumer.dependencies
    assert_equal original_info, consumer.info

    assert_equal "consumed:#{source.path}", duplicate.exec
    assert_equal [source], consumer.inputs
    assert_equal original_info, consumer.info
    refute_same consumer.inputs, duplicate.inputs
  end

  def test_child_configuration_precedence_is_child_then_agent_or_brief_then_inherited
    step = Step.new('/tmp/cortex-request-context-precedence')
    step.instance_variable_set(:@cortex_request_context,
                               Cortex::RequestContext.project(
                                 endpoint: 'inherited-endpoint',
                                 backend: 'inherited-backend',
                                 model: 'inherited-model',
                                 configuration: 'inherited-configuration'))

    agent_class = Struct.new(:other_options, :start_chat)
    agent = agent_class.new(
      {backend: 'agent-backend'},
      Chat.setup([
        {role: 'model', content: 'brief-model'},
        {role: 'option', content: 'configuration brief-configuration'}
      ])
    )
    child_chat = Chat.setup([
      {role: 'endpoint', content: 'child-endpoint'},
      {role: 'option', content: 'configuration child-configuration'},
      {role: 'user', content: 'continue'}
    ])

    assert_equal({endpoint: 'child-endpoint', backend: 'agent-backend',
                  model: 'brief-model', configuration: 'child-configuration'},
                 Cortex::RequestContext.effective_for(step, agent, child_chat))
  end
end
