require_relative '../activity'

# Investigations of THIS exact entity (design §4 data flow):
#
#   current = Step sidecars under var/jobs/<Type>/<property>/*.info
#             (source 'step_info'; arguments, definition identity, address,
#             status and timestamps straight off the sidecar)
#   history = legacy registry records read as-is
#             (source 'registry_history'; superseded, never written again)
#
# Availability status per item, cross-checked against the CURRENT definitions
# for the entity type:
#   'active'  - the definition exists, is active, and matches the recorded
#               definition version (the evidence replays from its address)
#   'older'   - the definition exists and is active, but a newer version is
#               current; the recorded digest identifies the code that
#               actually produced the recorded evidence
#   'removed' - no active definition exists anymore: the investigation is a
#               historical fact only
module Cortex
  register_activity_facet 'investigations', 'Property executions recorded for this exact entity' do |context|
    items = []

    # --- current: Step-derived evidence ---------------------------------
    context.entity_step_evidence.each do |e|
      items << { 'property' => e['property'].to_s,
                 'source' => 'step_info',
                 'status' => context.investigation_status(e['property'],
                                                          e['definition_version'].to_s,
                                                          e['definition_digest'].to_s),
                 'arguments' => e['arguments'] || {},
                 'definition_version' => e['definition_version'].to_s,
                 'definition_digest' => e['definition_digest'].to_s[0, 8],
                 'address' => e['address'].to_s,
                 'step_status' => e['status'].to_s,
                 'first_run' => e['first_run'].to_s,
                 'last_run' => e['last_run'].to_s,
                 'list' => e['list'].to_s.empty? ? nil : e['list'].to_s }
    end

    # --- history: LEGACY registry records (retired store, read-only) ---
    # The 'examinations'/'property_job' fields below are the retired
    # registry vocabulary, rendered verbatim for recall.
    context.entity_legacy_examinations.each do |e|
      items << { 'property' => e['property'].to_s,
                 'source' => 'registry_history',
                 'status' => context.investigation_status(e['property'],
                                                          e['definition_version'].to_s,
                                                          e['definition_digest'].to_s),
                 'arguments_digest' => e['arguments_digest'].to_s,
                 'arguments' => e['arguments'] || {},
                 'runs' => e['runs'].to_i,
                 'first_run' => e['first_run'].to_s,
                 'last_run' => e['last_run'].to_s,
                 'definition_version' => e['definition_version'].to_s,
                 'definition_digest' => e['definition_digest'].to_s[0, 8],
                 'property_job' => e['property_job'].to_s,
                 'list' => e['list'].to_s.empty? ? nil : e['list'].to_s }
    end

    items = items.sort_by { |i| [i['property'], i['source'], i['address'] || i['arguments_digest'].to_s] }

    { 'facet' => 'investigations',
      'title' => "Investigations of #{context.entity_type}/#{context.entity}",
      'items' => items,
      'meta' => { 'examinations' => items.length,
                  'note' => 'Current evidence = Step sidecars under var/jobs (source step_info); history = legacy registry records (source registry_history, never written again). Result payloads are never included; resolve an address with cortex_result to inspect the evidence. status: active = definition version matches the current active version; removed = definition was removed; older = a newer definition version exists' } }
  end
end
