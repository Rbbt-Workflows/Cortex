require_relative '../activity'

# Defined/active properties for the entity type, plus the availability status
# of every property that has ever been investigated for entities of the type:
# investigations of removed/tombstoned definitions are marked 'removed' rather
# than silently presented as executable. The properties facet answers
# "what CAN I ask"; the status on investigations answers "is that still
# possible". Both facts coexist: the historical execution record stays
# untouched.
module Cortex
  register_activity_facet 'properties', 'Defined and active entity properties for the entity type' do |context|
    defs = context.property_definitions
    items = defs.collect do |d|
      meta = d[:meta] || {}
      { 'property' => meta['property'].to_s,
        'result_type' => meta['result_type'].to_s,
        'property_type' => meta['property_type'].to_s,
        'definition_version' => meta['version'].to_s,
        'definition_digest' => meta['digest'].to_s[0, 8],
        'active' => meta['active'] ? true : false,
        'map' => d[:map].to_s }
    end.sort_by { |i| i['property'] }

    { 'facet' => 'properties',
      'title' => "Defined properties for #{context.entity_type}",
      'items' => items,
      'meta' => { 'entity_type' => context.entity_type } }
  end
end
