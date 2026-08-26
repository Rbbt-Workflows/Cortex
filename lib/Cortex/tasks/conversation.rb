
# ==========================================================================
# Cortex conversation/brief tasks (+ legacy aliases at the bottom)
# ==========================================================================

module Cortex

  # Single dep-chat builder used by cortex_continue (conversations
  # namespace) and cortex_brief (fresh brief: prompt only).
  def self.conversation_prompt_chat(conversation, prompt, namespace: :conversations)
    path = resource_path namespace, conversation, default_local_map
    chat = File.exist?(path) ? Chat.load(path) : Chat.setup([])
    chat.user prompt
    chat
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

  input :conversation, :string, 'Conversation name in the Cortex conversations namespace', nil, required: true
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

  input :conversation, :string, 'Brief name in the Cortex briefs namespace; it does not need to contain the agent name', nil, required: true
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
  task_alias :continue_chat, Cortex, :cortex_continue
  task_alias :brief_agent, Cortex, :cortex_brief

end
