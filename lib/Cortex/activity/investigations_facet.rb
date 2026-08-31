require_relative '../activity'

# Which properties have been examined for THIS exact entity, with argument
# combinations, run counts and property_job references. Digest refs only,
# never result payloads.
#
# Availability status: each investigation is cross-checked against the
# current definitions for the entity type.
#   'active'   - the definition exists and is active
#   'removed'  - the definition was removed/tombstoned; the investigation is
#               a historical fact and is kept as such, but the property can
#               no longer be executed (re-define it first)
#   'older'    - the definition moved on since the run (a newer active
#               version exists); the recorded digest identifies the code that
#               actually produced the recorded evidence
# The status never rewrites history: it separates the historical fact (the
# property was executed) from the current capability (it can be executed
# again as-is).
module Cortex
  register_activity_facet 'investigations', 'Property executions recorded for this exact entity' do |context|
    exams = context.entity_examinations
    items = exams.collect do |e|
      { 'property' => e['property'].to_s,
        'status' => context.investigation_status(e['property'],
                                                 e['definition_version'].to_s,
                                                 e['definition_digest'].to_s),
        'arguments_digest' => e['arguments_digest'].to_s,
        'arguments' => e['arguments'] || {},
        'runs' => e['runs'].to_i,
        'last_run' => e['last_run'].to_s,
        'definition_version' => e['definition_version'].to_s,
        'definition_digest' => e['definition_digest'].to_s[0, 8],
        'result_digest' => e['result_digest'].to_s[0, 8],
        'property_job' => e['property_job'].to_s,
        'list' => e['list'].to_s.empty? ? nil : e['list'].to_s }
    end.sort_by { |i| [i['property'], i['arguments_digest']] }

    { 'facet' => 'investigations',
      'title' => "Investigations of #{context.entity_type}/#{context.entity}",
      'items' => items,
      'meta' => { 'examinations' => items.length,
                  'note' => 'Result payloads are never included; use cortex_entity_property to recompute. status: active = executable now; removed = definition was removed; older = a newer definition version exists' } }
  end
end
