require_relative '../activity'

# Named lists of this entity type that contain the entity.
module Cortex
  register_activity_facet 'lists', 'Named entity lists of this type containing the entity' do |context|
    items = context.list_entries.select { |l| l['contains_entity'] }.collect do |l|
      meta = context.list_meta(l['list'])
      { 'list' => l['list'],
        'list_name' => l['name'],
        'map' => l['map'],
        'entities' => l['entities_count'] || l['members'].length,
        'members_shown' => l['members'].length,
        'description' => meta['description'].to_s.empty? ? nil : meta['description'].to_s }
    end.sort_by { |i| i['list'] }

    { 'facet' => 'lists',
      'title' => "Entity lists containing #{context.entity_type}/#{context.entity}",
      'items' => items,
      'meta' => { 'entity_type' => context.entity_type } }
  end
end
