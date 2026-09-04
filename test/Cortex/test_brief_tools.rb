# Tests for the `tools` input of cortex_brief (lib/Cortex/tasks/conversation.rb
# + lib/Cortex/briefs.rb): spec grammar, expansion into tool:/introduce:
# messages, replace/keep persistence, task schema, and one end-to-end
# continue-through-brief run under a mock backend.
#
# Hermetic: anchor/map directories live under tmp/ scratch; SCOUT_CHAT_DIR is
# saved/restored around every test.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')

class TestCortexBriefTools < Test::Unit::TestCase

  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "brftools-#{Process.pid}-#{rand(1e6).to_i}"))
    FileUtils.rm_rf @scratch
    @proj = File.join(@scratch, 'proj')
    @other = File.join(@scratch, 'other')
    FileUtils.mkdir_p(@proj)
    FileUtils.mkdir_p(File.join(@other, 'var', 'cortex'))

    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    ENV.delete('SCOUT_CHAT_DIR')
    Dir.chdir(@other)
    anchor_at(@proj)
  end

  def teardown
    ENV['SCOUT_CHAT_DIR'] = @old_anchor
    Dir.chdir(@old_pwd)
    Cortex.reset_cortex!
    FileUtils.rm_rf @scratch
  end

  def anchor_at(dir)
    ENV['SCOUT_CHAT_DIR'] = dir
    Cortex.reset_cortex!
  end

  def block_of(tools)
    Cortex.tool_messages(tools).collect { |m| [m[:role], m[:content]] }
  end

  # A unique brief name per process: read order is lib-first, so a probe
  # leftover in the live store would otherwise shadow the scratch :current
  # copy and make the persistence assertions read stale turns.
  def brief_name
    @brief_name ||= "probe/brftools-#{Process.pid}-#{rand(1e6).to_i}"
  end

  def save_brief_with(tools, prompt: 'brief turn', turn: 'assistant answer')
    res = Chat.setup([{role: 'user', content: prompt}, {role: 'assistant', content: turn}])
    Cortex.save_brief(brief_name, prompt, res, agent: 'Worker', job: 'Cortex/continue/x', tools: tools)
    Cortex.load_brief(brief_name)
  end

  # ------------------------------------------------------------------
  # Grammar variants -> exact messages
  # ------------------------------------------------------------------

  def test_whole_workflow_spec
    assert_equal [['introduce', 'Baking'], ['tool', 'Baking']], block_of(['Baking'])
  end

  def test_bare_task_spec
    assert_equal [['tool', 'ScoutCoder help_workflow']], block_of(['ScoutCoder help_workflow'])
  end

  def test_task_with_one_allowed_input
    assert_equal [['tool', 'Boolean trap_spaces network']], block_of(['Boolean trap_spaces network'])
  end

  def test_task_with_noinputs
    assert_equal [['tool', 'Boolean trap_spaces noinputs']], block_of(['Boolean trap_spaces noinputs'])
    assert_equal [['tool', 'Boolean trap_spaces none']], block_of(['Boolean trap_spaces none'])
  end

  def test_task_with_name_value_default
    assert_equal [['tool', 'Boolean trap_spaces network cft=default']],
                 block_of(['Boolean trap_spaces network cft=default'])
  end

  def test_task_with_mixed_tokens
    spec = 'Boolean trap_spaces network cft=default blueberries=false blueberries'
    assert_equal [['tool', 'Boolean trap_spaces network cft=default blueberries=false blueberries']],
                 block_of([spec])

    # The canonical mixed-variant literal documented in README.md /
    # doc/user/WorkspaceTools.md: one tool message, verbatim token order,
    # no introduce (task-level spec).
    documented = "Baking bake_muffin_tray blueberries=false wheat_type"
    assert_equal [["tool", documented]],
                 block_of([documented])
  end

  # Spec strings are pasted verbatim: no re-quoting, no expansion, shell
  # quoting in the spec survives Shellwords only, whitespace rejoined by
  # single spaces between tokens.
  def test_verbatim_pass_through_with_shellwords_values
    assert_equal [['tool', 'WF task net=with space']], block_of(['WF task net=with\\ space'])
  end

  def test_array_order_is_preserved
    specs = ['Cortex cortex_list', 'Baking', 'ScoutCoder help_workflow']
    assert_equal [['tool', 'Cortex cortex_list'],
                  ['introduce', 'Baking'], ['tool', 'Baking'],
                  ['tool', 'ScoutCoder help_workflow']], block_of(specs)
  end

  # ------------------------------------------------------------------
  # Worked example from the delegation
  # ------------------------------------------------------------------

  def test_worked_example
    specs = ['ScoutCoder help_workflow',
             'Boolean trap_spaces network cft=default',
             'Baking']
    assert_equal [['tool', 'ScoutCoder help_workflow'],
                  ['tool', 'Boolean trap_spaces network cft=default'],
                  ['introduce', 'Baking'],
                  ['tool', 'Baking']], block_of(specs)
  end

  # ------------------------------------------------------------------
  # Malformed specs -> actionable ScoutException
  # ------------------------------------------------------------------

  def assert_invalid_spec(spec, fragment)
    yield
    flunk "spec #{spec.inspect} was accepted"
  rescue ScoutException => e
    assert e.message.include?(spec.inspect), "error does not name the offending spec: #{e.message}"
    assert e.message.include?(fragment), "error does not explain the grammar: #{e.message}"
  end

  def saved_shape(chat)
    chat.collect { |m| %w(tool introduce).include?(m[:role].to_s) ? [m[:role], m[:content]] : m[:role] }
  end

  def test_empty_spec_rejected
    assert_invalid_spec('', 'must be a non-empty string') { Cortex.validate_tool_spec('') }
    assert_invalid_spec('   ', 'must be a non-empty string') { Cortex.validate_tool_spec('   ') }
    assert_invalid_spec('', 'must be a non-empty string') { Cortex.tool_messages(['']) }
  end

  # NOTE: a leading '-' is a legal shell word for Shellwords, and a legal
  # identifier for our regex, so this spec is NOT rejected as a workflow
  # token; it is rejected one token later as an input token.  The genuinely
  # bad workflow token is something like '/nope' or 'x=y'.
  def test_bad_workflow_token_rejected
    assert_invalid_spec('/nope', 'first token (workflow name)') { Cortex.validate_tool_spec('/nope') }
    assert_invalid_spec('x=y', 'first token (workflow name)') { Cortex.validate_tool_spec('x=y') }
  end

  def test_bad_task_token_rejected
    assert_invalid_spec('WF /bad', 'second token (task name)') { Cortex.validate_tool_spec('WF /bad') }
  end

  def test_bad_input_token_rejected
    assert_invalid_spec('WF task =v', 'input token') { Cortex.validate_tool_spec('WF task =v') }
    assert_invalid_spec('WF task bad name$', 'input token') { Cortex.validate_tool_spec('WF task bad name$') }
  end

  def test_noinputs_not_sole_rejected
    assert_invalid_spec('WF task noinputs net', "'noinputs' may only appear as the sole input token") do
      Cortex.validate_tool_spec('WF task noinputs net')
    end
    assert_invalid_spec('WF task none net', "'none' may only appear as the sole input token") do
      Cortex.validate_tool_spec('WF task none net')
    end
  end

  def test_task_identifiers_with_dots_are_legal
    assert_equal [['tool', 'W.f-1:x t_2']], block_of(['W.f-1:x t_2'])
  end

  # ------------------------------------------------------------------
  # Persistence: block at top, replace / keep / strip
  # ------------------------------------------------------------------

  def test_creation_persists_block_then_prompt
    saved = save_brief_with(['ScoutCoder help_workflow', 'Baking'])
    assert_equal [['tool', 'ScoutCoder help_workflow'],
                  ['introduce', 'Baking'], ['tool', 'Baking'],
                  'user', 'user', 'assistant'], saved_shape(saved)
  end

  def test_update_with_tools_replaces_tooling
    save_brief_with(['Baking'])
    saved = save_brief_with(['ScoutCoder help_workflow'])
    tools = saved.select { |m| %w(tool introduce).include?(m[:role].to_s) }
    assert_equal [['tool', 'ScoutCoder help_workflow']], tools.collect { |m| [m[:role], m[:content]] }
  end

  def test_update_without_tools_keeps_tooling
    save_brief_with(['Baking'])
    saved = save_brief_with(nil)
    tools = saved.select { |m| %w(tool introduce).include?(m[:role].to_s) }
    assert_equal [['introduce', 'Baking'], ['tool', 'Baking']], tools.collect { |m| [m[:role], m[:content]] }
  end

  def test_empty_tools_strips_all_tooling
    save_brief_with(['Baking', 'ScoutCoder help_workflow'])
    saved = save_brief_with([])
    assert saved.none? { |m| %w(tool introduce kb mcp).include?(m[:role].to_s) },
           "tooling roles survived tools: []: #{saved.collect { |m| m[:role] }.inspect}"
  end

  # ------------------------------------------------------------------
  # Task schema
  # ------------------------------------------------------------------

  def test_cortex_brief_schema_is_exactly_conversation_prompt_agent_tools
    info = Cortex.task_info(:cortex_brief)
    # Exact-schema pin: stronger than a per-input probe, it freezes the
    # whole input surface (no extra input may appear).
    assert_equal [:conversation, :prompt, :agent, :tools], info[:inputs]
    assert info[:input_types][:tools] == :array,
           "tools input is not :array typed: #{info[:input_types].inspect}"
  end

  def test_cortex_continue_schema_is_exactly_conversation_prompt_agent
    assert_equal [:conversation, :prompt, :agent], Cortex.task_info(:cortex_continue)[:inputs]
  end

  def test_continue_task_schema_unchanged
    assert_equal [:agent, :chat], Cortex.task_info(:continue)[:inputs]
  end

  def test_distinct_tool_sets_give_distinct_jobs
    base = {conversation: 'probe/brftools-jobid', prompt: 'p', agent: 'Worker'}
    j1 = Cortex.job(:cortex_brief, base.merge(tools: ['Baking']))
    j2 = Cortex.job(:cortex_brief, base.merge(tools: ['ScoutCoder help_workflow']))
    j3 = Cortex.job(:cortex_brief, base)
    assert j1.path != j2.path
    assert j1.path != j3.path && j2.path != j3.path
  end

  # ------------------------------------------------------------------
  # End to end: a briefed agent carries exactly the provisioned tooling
  # ------------------------------------------------------------------

  # Mock backend: records the messages it was asked with and answers once.
  module MockBackend
    ASKED = []
    def self.ask(messages, options, &block)
      ASKED << Chat.setup(Array(messages).dup)
      [{role: 'assistant', content: 'ok'}]
    end
  end

  # `LLM.load_agent` (scout-ai agent.rb:184-192) resolves an agent name as a
  # workflow first: Scout.workflows[<name>] must exist or the load raises
  # "No agent found".  A scratch workflows dir on SCOUT_CHAT_DIR + a matching
  # PWD therefore serves as the named agent in the end-to-end test.
  def test_continue_through_brief_carries_provisioned_tools
    agent_dir = File.join(@scratch, 'agentproj')
    FileUtils.mkdir_p(File.join(agent_dir, 'workflows', 'Worker'))
    File.write(File.join(agent_dir, 'workflows', 'Worker', 'workflow.rb'),
               "module Worker\n  extend Workflow\n  self.description = 'probe worker agent'\nend\n")
    Dir.chdir(agent_dir) do
      anchor_at(agent_dir)
      LLM.register_backend(:mock_brief_tools, MockBackend)
      save_brief_with(['Cortex cortex_list', 'Cortex cortex_search'], prompt: 'first brief turn')
      # `option backend` lines are how a chat selects the backend (LLM.options);
      # persist=false keeps the probe from writing a job result.
      chat = Chat.setup([{role: 'option', content: 'backend mock_brief_tools'},
                         {role: 'option', content: 'persist false'},
                         {role: 'user', content: 'go'}])
      job = Cortex.job(:continue, agent: "Worker/#{brief_name}", chat: chat)
      job.run

      asked = MockBackend::ASKED.last
      assert_not_nil asked, 'the mock backend was never asked'
      # The brief's provisioning must arrive exactly as provisioned, in order,
      # and nothing else from the brief may leak in.  The agent framework
      # itself always adds its own `introduce Worker` (agent start_chat) and
      # the mandatory `tool Cortex` (load_agent_conversation); those are
      # framework furniture, not brief provisioning.
      tools_only = asked.select { |m| m[:role].to_s == 'tool' }.collect { |m| m[:content] }
      provisioned = tools_only - ['Cortex']
      assert_equal ['Cortex cortex_list', 'Cortex cortex_search'], provisioned,
                   "the briefed agent did not carry exactly the provisioned tools: #{tools_only.inspect}"
      assert tools_only.include?('Cortex'), "the mandatory Cortex toolset is missing: #{tools_only.inspect}"
      assert asked.none? { |m| m[:role].to_s == 'assistant' && m[:content] =~ /exception/ },
             "the agent run errored: #{asked.collect { |m| m[:content].to_s[0, 60] }.inspect}"
    end
  ensure
    LLM::BACKENDS.delete(:mock_brief_tools) if LLM::BACKENDS.key?(:mock_brief_tools)
    MockBackend::ASKED.clear
  end
end
