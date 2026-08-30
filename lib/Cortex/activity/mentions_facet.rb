require_relative '../activity'

# Conversations, briefs and artifacts mentioning the entity id.
module Cortex
  register_activity_facet 'mentions', 'Conversations, briefs and artifacts mentioning the entity' do |context|
    items = context.mentions.map do |m|
      { 'type' => m['type'], 'name' => m['name'], 'map' => m['map'],
        'match' => m['match'] }
    end

    { 'facet' => 'mentions',
      'title' => "Workspace mentions of #{context.entity}",
      'items' => items,
      'meta' => { 'namespaces' => %w(conversations briefs artifacts) } }
  end
end
