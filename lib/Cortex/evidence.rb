require_relative 'activity'

# ==========================================================================
# Step-derived evidence: the CURRENT source of property-execution facts
# (design §4). Every materialized result under var/jobs/<Type>/<property>/
# carries a .info sidecar whose :inputs include the definition identity and
# the argument set; the label is the address suffix. NOTHING here writes
# var/cortex/properties — that store is retired (legacy records are read by
# lib/Cortex/properties.rb as history).
# ==========================================================================
module Cortex

  # One Step evidence entry per *.info sidecar, grouped per (entity_type,
  # property, member). Returns an Array of Hashes:
  #
  #   { entity_type, property, receiver, list, source: 'step_info',
  #     arguments: {...}, definition_version, definition_digest,
  #     address, status, first_run, last_run, info_path }
  #
  # Deterministic: sorted by (property, receiver, address).
  def self.step_evidence(entity_type = nil, property = nil)
    rows = []
    root = Workflow.directory.find.to_s
    Dir.glob(File.join(root, '*', '*', '*.info')).sort.each do |info_path|
      wf, task, _label = info_path.sub(root + File::SEPARATOR, '').split(File::SEPARATOR)
      next unless entity_type.nil? || wf == entity_type.to_s
      next unless property.nil? || task == property.to_s
      begin
        info = Step.load_info(info_path)
      rescue StandardError
        next
      end
      next if info.nil? || info.empty?

      names  = Array(info[:input_names] || [])
      values = Array(info[:inputs] || [])
      h = {}
      names.each_with_index { |n, i| h[n.to_s] = values[i] unless n.nil? }
      next unless h['_cortex_definition'] # only Cortex property Steps

      def_addr = h['_cortex_definition'].to_s
      d_type, d_prop, = def_addr.split('/', 2)
      next unless d_type == wf && d_prop == task

      # The jobname entity input is named after the entity type
      # (snake_case, e.g. probe_act) and the conventional 'organism'
      # annotation; both are receiver facts, not arguments.
      # snake_case of e.g. 'ProbeAct' is 'probe_act', not 'probeact'
      entity_key = wf.downcase
      snake = wf.gsub('::', '_').split(/(?=[A-Z])/).map(&:downcase).join('_')
      member = h.select { |k, _| k !~ /\A_cortex_/ && k != 'organism' &&
                                   k != entity_key && k != snake && k != 'list' }
                .each_with_object({}) { |(k, v), acc| acc[k] = v }
      receiver = (h[entity_key] || h[snake] || h['entity'] ||
                  File.basename(info_path, '.info').split('_').first).to_s
      list = h['list']

      rows << {
        'entity_type' => wf,
        'property' => task,
        'receiver' => receiver,
        'list' => list.respond_to?(:length) && !list.is_a?(String) ? nil : list.to_s,
        'source' => 'step_info',
        'arguments' => member,
        'definition_version' => h['_cortex_definition_version'].to_s,
        'definition_digest' => h['_cortex_definition_digest'].to_s,
        'address' => [wf, task, File.basename(info_path, '.info')] * '/',
        'status' => info[:status].to_s,
        'first_run' => info[:issued].to_s,
        'last_run' => info[:end].to_s,
        'info_path' => info_path
      }
    end
    rows.sort_by { |r| [r['property'], r['receiver'], r['address']] }
  end

  # Step evidence whose receiver is exactly +entity+ (direct runs; list runs
  # appear per member because fan-out Steps carry the member id).
  def self.step_evidence_for(entity_type, entity)
    step_evidence(entity_type).select { |e| e['receiver'] == entity.to_s }
  end

end
