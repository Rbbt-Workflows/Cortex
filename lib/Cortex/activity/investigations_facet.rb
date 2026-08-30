require_relative '../activity'

# Which properties have been examined for THIS exact entity, with argument
# combinations, run counts and property_job references. Digest refs only,
# never result payloads.
module Cortex
  register_activity_facet 'investigations', 'Property executions recorded for this exact entity' do |context|
    exams = context.entity_examinations
    items = exams.collect do |e|
      { 'property' => e['property'].to_s,
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
                  'note' => 'Result payloads are never included; use cortex_entity_property to recompute' } }
  end
end
