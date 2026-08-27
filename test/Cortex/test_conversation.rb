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
end
