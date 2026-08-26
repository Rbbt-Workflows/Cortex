require_relative 'storage'

# ==========================================================================
# Cortex conversations: namespace-specific accessors + persistence
# ==========================================================================
#
# Conversations are chat files under the conversations/ namespace of each
# path map. All path resolution goes through Cortex.cortex_path /
# resolve_resource (storage.rb): CORTEX[ns][name].find traverses every
# configured map, so a conversation stored in a secondary map is visible.

module Cortex

  def self.conversation_path(conversation)
    resource_path :conversations, conversation, write_map
  end

  def self.load_conversation(conversation)
    path, = resolve_resource(:conversations, conversation)
    path ? Chat.load(path) : Chat.setup([])
  end

  def self.save_conversation(conversation, prompt, new)
    path = conversation_path conversation
    Open.mkdir File.dirname(path)
    chat = load_conversation conversation
    chat.user prompt
    chat.follow new
    chat.save path
  end

end
