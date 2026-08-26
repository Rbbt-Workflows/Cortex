require_relative 'storage'

# ==========================================================================
# Cortex conversations: namespace-specific accessors + persistence
# ==========================================================================
#
# Conversations are chat files under the conversations/ namespace of each
# path map. The default write/read map for these accessors is :chat when an
# anchor is configured (the invoking project), :current otherwise — both
# resolve to the anchor project, and both equal :lib when Cortex runs from
# its own checkout, so existing data never migrates.

module Cortex

  def self.conversation_path(conversation)
    resource_path :conversations, conversation, default_local_map
  end

  def self.load_conversation(conversation)
    path = conversation_path conversation
    File.exist?(path) ? Chat.load(path) : Chat.setup([])
  end

  def self.save_conversation(conversation, prompt, new)
    path = conversation_path conversation
    Open.mkdir File.dirname(path)
    chat = load_conversation conversation
    chat.user prompt
    chat.follow new
    chat.save path
  end

  # Map used by the namespace-specific accessors below. :chat (the anchor
  # project) when anchored, :current otherwise; identical resolution either
  # way, the name just stays explicit in listings.
  def self.default_local_map
    chat_anchor ? :chat : :current
  end

end
