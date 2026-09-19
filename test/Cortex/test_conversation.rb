# Tests for Cortex conversation/brief chat building
# (lib/Cortex/tasks/conversation.rb).
#
# Mirrors lib/Cortex/tasks/conversation.rb: replace lib/ with test/ and
# prefix with test_.
#
# Hermetic: anchors and map directories live under a tmp/ scratch tree;
# SCOUT_CHAT_DIR is saved/restored around every test.

require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')

class TestCortexConversation < Test::Unit::TestCase

  def setup
    @scratch = File.expand_path(File.join(File.dirname(__FILE__), 'scratch', "conv-#{Process.pid}-#{rand(1e6).to_i}"))
    FileUtils.rm_rf @scratch
    @proj = File.join(@scratch, 'proj')
    @other = File.join(@scratch, 'other')
    FileUtils.mkdir_p(@proj)
    FileUtils.mkdir_p(File.join(@other, 'var', 'cortex'))

    @old_anchor = ENV['SCOUT_CHAT_DIR']
    @old_pwd = Dir.pwd
    ENV.delete('SCOUT_CHAT_DIR')
    # :current is PWD-based and Scout's default write map: run from @other
    # (a scratch dir with its own var/cortex) so writes never land in the
    # live var/cortex.  PWD != anchor also keeps :current and :lib distinct
    # (:current = @other store, :lib = anchor/@proj store).
    Dir.chdir(@other)
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

  def write_chat(map, name, text)
    path = Cortex.resource_path(:conversations, name, map)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    path
  end

  # ------------------------------------------------------------------

  def test_prompt_chat_continues_existing_conversation
    anchor_at(@proj)
    write_chat(:current, 'probe/conv', "user:\n\nhello first\n")
    chat = Cortex.conversation_prompt_chat('probe/conv', 'second turn')
    contents = chat.collect { |m| m[:content].to_s.strip }.reject(&:empty?)
    assert_equal ['hello first', 'second turn'], contents
  end

  def test_prompt_chat_finds_conversation_in_secondary_map
    anchor_at(@proj)
    write_chat(:lib, 'probe/secondary', "user:\n\nstored elsewhere\n")
    chat = Cortex.conversation_prompt_chat('probe/secondary', 'next turn')
    contents = chat.collect { |m| m[:content].to_s.strip }.reject(&:empty?)
    assert contents.include?('stored elsewhere'),
           "expected the :lib copy to seed the chat, got #{contents.inspect}"
    assert_equal 'next turn', contents.last
  end

  def test_prompt_chat_first_map_wins
    anchor_at(@proj)
    write_chat(:current, 'probe/both', "user:\n\nanchor copy\n")
    write_chat(:lib, 'probe/both', "user:\n\nlib copy\n")
    chat = Cortex.conversation_prompt_chat('probe/both', 'turn')
    contents = chat.collect { |m| m[:content].to_s.strip }.reject(&:empty?)
    assert_equal ['anchor copy', 'turn'], contents
  end

  def test_prompt_chat_missing_starts_empty
    anchor_at(@proj)
    chat = Cortex.conversation_prompt_chat('probe/missing', 'fresh start')
    contents = chat.collect { |m| m[:content].to_s.strip }.reject(&:empty?)
    assert_equal ['fresh start'], contents
  end

  def test_prompt_chat_briefs_namespace
    anchor_at(@proj)
    path = Cortex.resource_path(:briefs, 'probe/brf', :current)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "user:\n\nbrief history\n")
    chat = Cortex.conversation_prompt_chat('probe/brf', 'brief turn', namespace: :briefs)
    contents = chat.collect { |m| m[:content].to_s.strip }.reject(&:empty?)
    assert_equal ['brief history', 'brief turn'], contents
  end

  # A file with no role headers is not treated as corrupt history that gets
  # dropped: Chat.parse reads it as one user message, and the new turn is
  # appended after it.  History is never silently discarded.
  def test_headerless_file_keeps_content_instead_of_dropping_history
    anchor_at(@proj)
    write_chat(:current, 'probe/bad', "this is not a chat file: no role headers {{{\n")
    chat = Cortex.conversation_prompt_chat('probe/bad', 'turn')
    contents = chat.collect { |m| m[:content].to_s.strip }.reject(&:empty?)
    assert contents.include?('this is not a chat file: no role headers {{{')
    assert_equal 'turn', contents.last
  end

  def test_continue_claim_rejects_existing_claim_with_diagnostics
    anchor_at(@proj)
    first = Cortex.acquire_continue_claim('probe/claimed', 'first prompt',
      job_path: '/missing/job', agent: 'Worker')
    error = assert_raise(ScoutException) do
      Cortex.acquire_continue_claim('probe/claimed', 'second prompt',
        job_path: '/other/job', agent: 'Other')
    end
    assert_match(/probe\/claimed/, error.message)
    assert_match(/already in flight/, error.message)
    assert_match(/first prompt/, error.message)
  ensure
    Cortex.release_continue_claim(first) if first
  end

  def test_continue_claim_path_is_digest_under_configured_write_map
    anchor_at(@proj)
    claim = Cortex.acquire_continue_claim('probe/nested name', "prompt\nwith control", agent: 'Worker')
    path = claim['_path']
    assert_match(%r{/\.claims/[0-9a-f]{64}\.json\z}, path)
    data = JSON.parse(File.read(path))
    assert_equal 'probe/nested name', data['conversation']
    assert_equal 'prompt with control', data['prompt_excerpt']
  ensure
    Cortex.release_continue_claim(claim) if claim
  end

  # File::EXCL is the synchronization point: independent actors cannot both
  # observe an absent claim and proceed.
  def test_continue_claim_contention_allows_one_actor
    anchor_at(@proj)
    gate = Queue.new
    actors = 8.times.collect do |i|
      Thread.new do
        gate.pop
        begin
          [:won, Cortex.acquire_continue_claim('probe/race', "prompt #{i}", agent: "A#{i}")]
        rescue ScoutException => e
          [:blocked, e.message]
        end
      end
    end
    actors.length.times { gate << true }
    outcomes = actors.collect(&:value)
    assert_equal 1, outcomes.count { |kind, _| kind == :won }
    assert_equal 7, outcomes.count { |kind, _| kind == :blocked }
    assert_match(/already in flight/, outcomes.find { |kind, _| kind == :blocked }[1])
    Cortex.release_continue_claim(outcomes.find { |kind, _| kind == :won }[1])
  end

  # A syntactically valid claim whose job cannot be inspected is deliberately
  # conservative: claim_status returns :unknown and acquisition is rejected.
  def test_valid_claim_with_uninspectable_job_fails_closed
    anchor_at(@proj)
    path = Cortex.continue_claim_path('probe/uninspectable')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate('conversation' => 'probe/uninspectable',
      'job_path' => '/definitely/not/a/real/step', 'owner_token' => 'x',
      'prompt_excerpt' => 'prior'))
    error = assert_raise(ScoutException) do
      Cortex.acquire_continue_claim('probe/uninspectable', 'new')
    end
    assert_match(/already in flight/, error.message)
    # Step.load accepts the unresolved path as a bare Step and reports an
    # empty status; acquisition conservatively treats that as in flight.
    assert_match(/status=""/, error.message)
  end

  def test_terminal_claim_is_removed_then_reacquired
    anchor_at(@proj)
    path = Cortex.continue_claim_path('probe/terminal')
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate('conversation' => 'probe/terminal', 'job_path' => 'finished', 'owner_token' => 'old'))
    original = Cortex.method(:claim_status)
    Cortex.define_singleton_method(:claim_status) { |_claim| [:terminal, 'done'] }
    claim = Cortex.acquire_continue_claim('probe/terminal', 'new')
    refute_equal 'old', JSON.parse(File.read(path))['owner_token']
    Cortex.release_continue_claim(claim)
  ensure
    Cortex.define_singleton_method(:claim_status, original) if original
  end

  def test_missing_and_malformed_claims_fail_closed
    anchor_at(@proj)
    missing = Cortex.continue_claim_path('probe/missing-job')
    FileUtils.mkdir_p(File.dirname(missing))
    File.write(missing, JSON.generate('conversation' => 'probe/missing-job', 'job_path' => '', 'owner_token' => 'x'))
    error = assert_raise(ScoutException) { Cortex.acquire_continue_claim('probe/missing-job', 'new') }
    assert_match(/already in flight.*absent/, error.message)

    malformed = Cortex.continue_claim_path('probe/malformed')
    File.write(malformed, '{not-json')
    error = assert_raise(ScoutException) { Cortex.acquire_continue_claim('probe/malformed', 'new') }
    assert_match(/malformed or uninspectable.*refusing recovery/, error.message)
  end

  def test_old_owner_cannot_release_replacement_claim
    anchor_at(@proj)
    original = Cortex.acquire_continue_claim('probe/ownership', 'old')
    path = original['_path']
    replacement = original.merge('owner_token' => 'replacement-token')
    File.write(path, JSON.generate(replacement.reject { |key, _| key == '_path' }))
    Cortex.release_continue_claim(original)
    assert File.exist?(path)
    assert_equal 'replacement-token', JSON.parse(File.read(path))['owner_token']
    Cortex.release_continue_claim(replacement.merge('_path' => path))
  end

  def test_claim_release_after_success_and_raised_failure
    anchor_at(@proj)
    success = Cortex.acquire_continue_claim('probe/release-success', 'ok')
    Cortex.release_continue_claim(success)
    refute File.exist?(success['_path'])
    failure = Cortex.acquire_continue_claim('probe/release-failure', 'bad')
    begin
      raise 'simulated inference failure'
    rescue RuntimeError
      Cortex.release_continue_claim(failure)
    end
    refute File.exist?(failure['_path'])
  end

  def test_concurrent_saves_retain_all_turns_and_remain_parseable
    anchor_at(@proj)
    threads = 6.times.collect do |i|
      Thread.new do
        Cortex.save_conversation('probe/save-race', "prompt #{i}", Chat.setup([{role: 'assistant', content: "reply #{i}"},
            {role: 'meta', content: "job=AgentWorkflow/continue/receipt_#{i}"}]))
      end
    end
    threads.each(&:join)
    path, = Cortex.resolve_resource(:conversations, 'probe/save-race')
    contents = Chat.load(path).collect { |m| m[:content].to_s }
    6.times do |i|
      assert contents.include?("prompt #{i}")
      assert contents.include?("reply #{i}")
      assert contents.include?("job=AgentWorkflow/continue/receipt_#{i}")
    end
  end
end
