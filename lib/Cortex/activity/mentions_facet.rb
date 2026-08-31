require_relative '../activity'

# Conversations, briefs and artifacts mentioning the entity id.
#
# RAW lexical matches only: this facet answers "where does this token
# occur", not "where is this entity scientifically discussed". Hits include
# incidental occurrences (tool-call transcripts, table rows); the count is
# never evidence of presence, absence, importance or relevance. Read the
# matching resource; use cortex_read for content. De-noising is deliberately
# out of scope here (a future semantic/alias-aware index can do better).
module Cortex
  register_activity_facet 'mentions', 'Conversations, briefs and artifacts mentioning the entity (discovery hints only)' do |context|
    items = context.mentions.map do |m|
      { 'type' => m['type'], 'name' => m['name'], 'map' => m['map'],
        'match' => m['match'] }
    end

    { 'facet' => 'mentions',
      'title' => "Workspace mentions of #{context.entity}",
      'items' => items,
      'meta' => { 'namespaces' => %w(conversations briefs artifacts),
                  'note' => 'Discovery hints only: raw lexical matches, no relevance ranking; never infer presence/absence or importance from counts' } }
  end
end
