require_relative '../conversations'
require_relative '../briefs'

# ==========================================================================
# Cortex conversation/brief tasks (+ legacy aliases at the bottom)
# ==========================================================================
#
# The dep-chat builder reads through the unified resolution mechanism
# (storage.rb): resolve_resource traverses every configured path map in
# read order, so a conversation or brief stored in a secondary map (a
# yaml-configured one, :lib, ...) seeds the new turn.  When it exists
# nowhere the chat starts empty, exactly like a brand-new conversation.

module Cortex

  # Single dep-chat builder used by cortex_continue (conversations
  # namespace) and cortex_brief (fresh brief: prompt only).
  def self.conversation_prompt_chat(conversation, prompt, namespace: :conversations)
    chat = load_conversation_or_brief(conversation, namespace)
    chat.user prompt
    chat
  end

  # Existing conversation/brief (a Chat) or an empty one.  Reads go through
  # resolve_resource (first match across read_maps); when the resource does
  # not exist yet the empty Chat is returned so the caller builds a fresh
  # history and the save path (write map) decides where it is stored.
  # Malformed chat files fail loudly instead of being silently dropped.
  def self.load_conversation_or_brief(name, namespace)
    path, = resolve_resource(namespace, name)
    return Chat.setup([]) unless path
    Chat.load path
  end

  input :agent, :string, 'Agent name; optionally Agent/brief_name to load a brief stored in the Cortex briefs namespace (e.g. Worker/math loads brief math for agent Worker)', nil
  chat_task :continue do
    agent_conversation = inputs[:agent]
    agent = load_agent_conversation agent_conversation
    agent.follow chat
    agent
  end

  # ------------------------------------------------------------------
  # Canonical conversation/brief tools (+ legacy aliases at the bottom)
  # ------------------------------------------------------------------

  input :conversation, :string, 'Conversation name in the Cortex conversations namespace', nil, required: true, nofile: true
  input :prompt, :text, 'Prompt to continue the conversation', nil, required: true
  dep :continue, chat: :placeholder do |jobname,options|
    conversation, prompt = options.values_at :conversation, :prompt
    {chat: Cortex.conversation_prompt_chat(conversation, prompt, namespace: :conversations)}
  end
  task :cortex_continue => :json do |conversation,prompt|
    continue = step(:continue)
    res = continue.load
    res = Chat.setup(res)
    save_conversation conversation, prompt, res
    {agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
  end

  input :conversation, :string, 'Brief name in the Cortex briefs namespace; it does not need to contain the agent name', nil, required: true, nofile: true
  input :prompt, :text, 'Prompt for the agent that will produce the brief', nil, required: true
  input :agent, :string, 'Agent the brief is for (e.g. Worker); recorded in the briefs .meta sidecar and used to produce the brief', nil, required: true
  dep :continue, chat: :placeholder do |jobname,options|
    conversation, prompt = options.values_at :conversation, :prompt
    {chat: Cortex.conversation_prompt_chat(conversation, prompt, namespace: :briefs)}
  end
  task :cortex_brief => :json do |conversation,prompt,agent|
    continue = step(:continue)
    res = continue.load
    res = Chat.setup(res)
    save_brief conversation, prompt, res, agent: agent.to_s, job: continue.short_path
    {agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
  end

  # ------------------------------------------------------------------
  # Compatibility aliases: continue_chat -> cortex_continue,
  # brief_agent -> cortex_brief. Same inputs, same receipts.
  # ------------------------------------------------------------------
end
