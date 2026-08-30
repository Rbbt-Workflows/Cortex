# ==========================================================================
# Cortex activity report: deterministic associative recall around ONE entity
# --------------------------------------------------------------------------
# Mirrors the scout-ai prompt-strategy shape (Chat::REGISTERED_STRATEGIES +
# Chat.prepare_prompt in scout-ai/lib/scout/llm/chat/prompt.rb): a
# module-level ordered registry, self-registering facet files (one per
# facet, required from here in a FIXED order so registry order is
# deterministic), and a dispatcher that takes a facet list (nil => all in
# registration order, String comma list, unknown name => ScoutException
# naming the available facets).
#
# Contract (facet):
#
#   Cortex::ACTIVITY_FACETS[name] = { description: String, block: Proc }
#
#   block.call(context) => { facet: name, title: String, items: Array,
#                            meta: Hash }
#
# `items` are JSON-ready primitives (strings, numbers, hashes of those).
# Facets MUST sort their items explicitly (never rely on glob/hash order)
# and MUST NOT embed result payloads, wall-clock time, or anything
# non-deterministic: identical inputs + identical workspace => identical
# report. The limit is applied by the dispatcher, after the facet sorts.
#
# Adding a facet: write lib/Cortex/activity/<name>_facet.rb, call
# `Cortex.register_activity_facet(<name>, description:, &block)` at load
# time, and add the require line to the FIXED require list at the top of
# this file. Nothing else changes.
module Cortex

  ACTIVITY_FACETS = {}
  DEFAULT_ACTIVITY_LIMIT = 10

  # Registration is append-only in load order, so ACTIVITY_FACETS is an
  # ordered Hash and section order is fixed without an explicit list.
  def self.register_activity_facet(name, description = nil, &block)
    name = name.to_s
    raise ScoutException,
          "Activity facet #{name.inspect} registered without a block" unless block
    raise ScoutException,
          "Activity facet #{name.inspect} already registered" if ACTIVITY_FACETS.key?(name)
    ACTIVITY_FACETS[name] = { 'description' => description.to_s,
                              'block' => block }
    name
  end


require_relative 'activity/context'
require_relative 'activity/properties_facet'
require_relative 'activity/investigations_facet'
require_relative 'activity/lists_facet'
require_relative 'activity/mentions_facet'

  # ------------------------------------------------------------------
  # Dispatcher
  # ------------------------------------------------------------------

  # context object or hash: entity_type:, entity:, limit:
  def self.activity_context(entity_type:, entity:, limit: nil, facets: nil)
    ActivityContext.new(entity_type: entity_type, entity: entity,
                        limit: limit || DEFAULT_ACTIVITY_LIMIT,
                        facets: facets)
  end

  def self.activity_report(entity_type:, entity:, facets: nil, limit: nil)
    context = activity_context(entity_type: entity_type, entity: entity,
                               limit: limit, facets: facets)
    limit = context.limit

    names = context.requested_facets
    sections = names.collect do |name|
      descriptor = ACTIVITY_FACETS[name]
      raise ScoutException,
            "Unknown activity facet #{name.inspect}. " \
            "Available facets: #{ACTIVITY_FACETS.keys * ', '}" unless descriptor
      section = descriptor['block'].call(context)
      # Normalize the section shape and apply the per-section limit AFTER
      # the facet has sorted its items (dispatcher-level determinism).
      section = { 'facet' => name.to_s, 'title' => name.to_s, 'items' => [],
                  'meta' => {} } if section.nil?
      section = IndiferentHash.setup(section)
      section['facet'] = name.to_s if section['facet'].to_s.empty?
      section['items'] = [] unless Array === section['items']
      section['meta']  = {} unless Hash === section['meta']
      total = section['items'].length
      section['items'] = section['items'].first(limit) if limit && limit > 0
      section['meta']['total'] = total
      section['meta']['shown'] = section['items'].length
      section
    end

    { 'entity' => "#{entity_type}/#{entity}",
      'facets' => sections,
      'facet_names' => names }
  end

end
