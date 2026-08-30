require 'json'
require 'Cortex/activity'

# ==========================================================================
# Cortex activity task: deterministic associative recall around ONE entity
# ==========================================================================
#
# Task layer only; the facet registry and dispatcher live in
# lib/Cortex/activity.rb (mirrors scout-ai's prompt strategies).

module Cortex

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :entity, :string, 'Entity identifier (e.g. FOXO1)', nil, required: true, jobname: true
  input :limit, :integer, 'Max items per section', 10
  input :facets, :string, 'Comma-separated facet list; empty = all (properties, investigations, lists, mentions)', nil
  task :cortex_activity => :json do |entity_type, entity, limit, facets|
    facets = facets.to_s.split(',').collect(&:strip).reject(&:empty?) if String === facets
    Cortex.activity_report(entity_type: entity_type, entity: entity,
                           facets: facets, limit: limit)
  end

end
