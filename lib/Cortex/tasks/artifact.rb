
# ==========================================================================
# Cortex artifact tasks: write / edit / rename / remove / move
# ==========================================================================

module Cortex

  input :path, :string, 'Artifact path relative to var/cortex/artifacts (e.g. claims/C42.md); no absolute paths, no ..', nil, required: true
  input :content, :text, 'Full artifact content to write (mode replace) or append (mode append); never echoed back', nil, required: true
  input :mode, :select, 'replace overwrites (with history snapshot); append adds to the end, creating if absent', 'replace', select_options: %w(replace append)
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_write => :text do |path,content,mode,agent|
    name, size, version = Cortex.write_artifact(path, content, mode, job: self.short_path, agent: agent)
    "Artifact written: #{name} (#{size} bytes, v#{version})"
  end

  input :name, :string, 'Artifact path relative to var/cortex/artifacts', nil, required: true
  input :find, :text, 'Exact text to find in the artifact', nil, required: true
  input :replace, :text, 'Replacement text', nil, required: true
  input :all, :boolean, 'Replace every occurrence (required when find matches more than once)', false
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_edit => :text do |name,find,replace,all,agent|
    Cortex.edit_artifact(name, find, replace, all: all, job: self.short_path, agent: agent)
  end

  input :type, :select, "Namespace of the resource to rename", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :name, :string, 'Current logical name', nil, required: true
  input :new_name, :string, 'New logical name', nil, required: true
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_rename => :text do |type,name,new_name,agent|
    Cortex.rename_resource(type, name, new_name, job: self.short_path, agent: agent)
  end

  input :type, :select, "Namespace of the resource to remove", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :name, :string, 'Logical name to remove', nil, required: true
  task :cortex_remove => :text do |type,name|
    removed = Cortex.remove_resource(type, name, job: self.short_path)
    "Removed: #{removed.length} item#{removed.length == 1 ? '' : 's'} (#{removed.collect { |p| Log.truncate_string(p, 60) } * ', '})"
  end

  input :type, :select, "Namespace of the resource to move", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :name, :string, 'Logical name to move', nil, required: true
  # Path maps are project-configurable (cortex_path_map.yaml), so the target
  # cannot be a fixed select list: any configured writable map name is
  # accepted and unknown/read-only ones are rejected by Cortex.move_resource.
  input :to, :string, 'Target path map (configured map name, e.g. lib, chat, or a name from cortex_path_map.yaml)', nil, required: true
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_move => :text do |type,name,to,agent|
    Cortex.move_resource(type, name, to, job: self.short_path, agent: agent)
  end

end
