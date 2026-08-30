
# ==========================================================================
# Cortex entity-list tasks: write / read named entity lists
# ==========================================================================
#
# Task layer only; storage lives in lib/Cortex/lists.rb and path resolution
# in lib/Cortex/storage.rb (the unified mechanism).

module Cortex

  input :entity_type, :string, 'Entity type of the list members (e.g. TF, Gene, Composite)', nil, required: true
  input :list, :string, 'List name (the file under var/cortex/lists/<entity_type>/; e.g. C01, cell-cycle)', nil, required: true
  input :entities, :text, 'Entities, one per line (newline separated)', nil, required: true
  input :description, :string, 'Optional description recorded in the .meta sidecar', nil
  input :entity_options, :text, 'Optional entity annotation options (JSON object, e.g. organism) recorded in the .meta sidecar and applied when the list is used as a property receiver', nil
  task :cortex_write_list => :text do |entity_type,list,entities,description,entity_options|
    entity_options = JSON.parse(entity_options) if String === entity_options && !entity_options.to_s.empty?
    name, count, _path = Cortex.write_list(entity_type, list, entities,
                                           description: description,
                                           entity_options: entity_options,
                                           created_by: 'Cortex',
                                           job: self.short_path)
    "Entity list written: #{name} (#{count} entities)"
  end

  input :entity_type, :string, 'Entity type of the list (e.g. TF)', nil, required: true, jobname: true
  input :list, :string, 'List name under var/cortex/lists/<entity_type>/', nil, required: true
  input :include_meta, :boolean, 'Also report the .meta sidecar (description, entity_options, provenance)', false
  task :cortex_read_list => :text do |entity_type,list,include_meta|
    entities, meta, _path, map, all_paths = Cortex.read_list(entity_type, list)
    out = []
    if all_paths.length > 1
      out << "[note] #{entity_type}/#{list} exists in more than one path map; using :#{map} (#{all_paths * ' | '})"
    end
    out << "Entity list #{entity_type}/#{list}: #{entities.length} entities"
    if include_meta
      require 'yaml'
      out << YAML.dump(meta).sub(/\A---\n/, '').chomp
    end
    out << entities * "\n"
    out * "\n"
  end

end
