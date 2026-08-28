require 'scout-ai'

# lib/ files under this repo are not on $LOAD_PATH by default; the engine
# (and the task files it backs) live in lib/Cortex/.
lib = File.join(File.dirname(File.expand_path(__FILE__)), 'lib')
$LOAD_PATH.unshift lib unless $LOAD_PATH.include?(lib)

require 'Cortex/path_maps'
require 'Cortex/storage'
require 'Cortex/conversations'
require 'Cortex/briefs'
require 'Cortex/artifacts'
require 'Cortex/lists'
require 'Cortex/properties'
require 'Cortex/listing'

# ==========================================================================
# Cortex: agent memory across conversations, briefs, artifacts, entities
# ==========================================================================
#
# workflow.rb is the module skeleton + requires only. Implementation lives
# in lib/Cortex:
#
#   path_maps.rb     anchor discovery (SCOUT_CHAT_DIR / PWD fallback),
#                    per-project cortex_path_map.yaml maps, map order
#   storage.rb       THE unified path-resolution mechanism
#                    (CORTEX[namespace][full_path].find across all maps)
#   conversations.rb conversations namespace accessors + persistence
#   briefs.rb        briefs namespace (chat + .meta sidecar)
#   artifacts.rb     artifacts write/edit + rename/remove/move
#   lists.rb         named entity lists (<entity_type>/<list> + .meta)
#   listing.rb       listing, search, bounded read
#   entities.rb      entity property engine (+ tasks/entity.rb)
#
# Tasks are declared in lib/Cortex/tasks: conversation.rb (continue, brief),
# listing.rb (list/search/read), artifact.rb (write/edit/rename/remove/move),
# list.rb (entity lists), entity.rb (property lifecycle).

module Cortex
  extend Workflow
  self.include_workflow AgentWorkflow

  # ------------------------------------------------------------------
  # Workflow helpers: thin delegation to the lib modules
  # ------------------------------------------------------------------

  helper :conversation_path do |conversation| Cortex.conversation_path(conversation) end
  helper :brief_path do |brief| Cortex.brief_path(brief) end
  helper :artifact_path do |artifact| Cortex.artifact_path(artifact) end
  helper :namespace_names do |namespace| Cortex.namespace_names(namespace) end
  helper :load_conversation do |conversation| Cortex.load_conversation(conversation) end
  helper :load_brief do |brief| Cortex.load_brief(brief) end
  helper :resolve_brief do |agent, brief| Cortex.resolve_brief(agent, brief) end
  helper :save_conversation do |conversation,prompt,new| Cortex.save_conversation(conversation, prompt, new) end
  helper :save_brief do |brief,prompt,new,**kw| Cortex.save_brief(brief, prompt, new, **kw) end
  helper :validate_type! do |type| Cortex.validate_type!(type) end
  helper :namespace_listing do |type,prefix=nil| Cortex.namespace_listing(type, prefix) end
  helper :listing_text do |type,prefix=nil,offset=0,limit=nil| Cortex.listing_text(type, prefix, offset, limit) end
  helper :search_conversations do |query,type=nil,limit=20| Cortex.search_conversations(query, type, limit) end
  helper :search_artifacts do |query,limit=20| Cortex.search_artifacts(query, limit) end
  helper :conversation_index do |chat| Cortex.conversation_index(chat) end
  helper :conversation_slice do |chat,a,b| Cortex.conversation_slice(chat, a, b) end
  helper :parse_range do |range| Cortex.parse_range(range) end
  helper :cap_string do |text,cap=Cortex::READ_CAP| Cortex.cap_string(text, cap) end
  helper :write_artifact do |path,content,mode=:replace,**kw| Cortex.write_artifact(path, content, mode, **kw) end
  helper :list_name do |entity_type,list| Cortex.list_name(entity_type, list) end
  helper :write_list do |entity_type,list,entities,**kw| Cortex.write_list(entity_type, list, entities, **kw) end
  helper :read_list do |entity_type,list| Cortex.read_list(entity_type, list) end

  helper :load_agent_conversation do |agent_conversation=nil|
    agent = if agent_conversation.nil?
              self.agent nil
            else
              name, _sep, conversation = agent_conversation.partition('/')
              brief = resolve_brief name, conversation if conversation && !conversation.empty?
              chat = self.chat
              agent = self.agent name, chat: nil
              agent.start_chat.follow brief if brief
              agent
            end
    agent.start_chat.tool 'Cortex'
    agent
  end

  require 'Cortex/tasks/conversation'
  require 'Cortex/tasks/listing'
  require 'Cortex/tasks/artifact'
  require 'Cortex/tasks/list'

  export :cortex_continue, :cortex_brief
  export_exec :cortex_list, :cortex_search, :cortex_read, :cortex_write,
         :cortex_edit, :cortex_rename, :cortex_remove, :cortex_move,
         :cortex_write_list, :cortex_read_list,
         :cortex_property_list, :cortex_property_read, :cortex_property_history,
         :cortex_property_validate, :cortex_property_define, :cortex_property_update,
         :cortex_property_remove, :cortex_entity_property
end

# Entity engine (storage + lifecycle + compiler) followed by the thin task
# layer over it.  Both live outside workflow.rb so the engine stays pure
# module functions with no workflow declarations.
require 'Cortex/entities'
require 'Cortex/tasks/entity'
