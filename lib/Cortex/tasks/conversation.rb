require_relative '../conversations'
require 'json'
require_relative '../briefs'

# ==========================================================================
# Cortex conversation/brief tasks
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
    load_agent_conversation inputs[:agent], chat
  end

  # ------------------------------------------------------------------
  # Canonical conversation/brief tools
  # ------------------------------------------------------------------

  input :conversation, :string, 'Conversation name in the Cortex conversations namespace', nil, required: true, nofile: true, jobname: true
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

  input :conversation, :string, 'Brief name in the Cortex briefs namespace; it does not need to contain the agent name', nil, required: true, nofile: true, jobname: true
  input :prompt, :text, 'Prompt for the agent that will produce the brief', nil, required: true
  input :agent, :string, 'Agent the brief is for (e.g. Worker); recorded in the briefs .meta sidecar and used to produce the brief', nil, required: true
  input :tools, :array, 'Tool specs persisted in the brief body as tool:/introduce: chat messages; a briefed agent (cortex_continue --agent Agent/<brief>) receives exactly these tools. Grammar "Workflow [task [input|name=value ...]]": whole workflow "Baking" adds introduce: Baking plus tool: Baking (one tool per task, full inputs); "Workflow task [inputs...]" adds one tool: line, verbatim. name=value pre-fills the input and hides it from the model; bare names restrict the accepted inputs; noinputs/none as the sole input token exposes the task with no inputs. Specs are validated for syntax only and resolved at continue time (a workflow may be absent now and installed later). Give tools to REPLACE the brief tooling (tools: [] strips it all); omit tools to KEEP the existing tooling. JSON array of strings, never comma-split', nil
  dep :continue, chat: :placeholder do |jobname,options|
    conversation, prompt, tools = options.values_at :conversation, :prompt, :tools
    tools = JSON.parse(tools) if String === tools
    {chat: Cortex.brief_prompt_chat(conversation, prompt, tools)}
  end
  task :cortex_brief => :json do |conversation,prompt,agent,tools|
    continue = step(:continue)
    res = continue.load
    res = Chat.setup(res)
    # :array inputs arrive as a JSON string through some surfaces; accept
    # both, exactly like entity tasks treat their :text arguments input.
    tools = JSON.parse(tools) if String === tools
    save_brief conversation, prompt, res, agent: agent.to_s, job: continue.short_path, tools: tools
    {agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
  end

end
