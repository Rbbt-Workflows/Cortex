require_relative 'storage'

# ==========================================================================
# Cortex lists: named entity lists (<entity_type>/<list> + .meta sidecar)
# ==========================================================================
#
# A named entity list is a newline-separated list of entity identifiers:
#
#     var/cortex/lists/
#       TF/
#         cell-cycle.md
#         interferon.md
#       Composite/
#         C01
#         C02
#
# The file content is one entity per line (blank lines are ignored on read):
#
#     TP53
#     MYC
#     MYCN
#     IRF3
#     IRF7
#
# A YAML sidecar .meta/<entity_type>/<list>.yaml records the list's
# entity_options and other metadata (description, created_by, created_at...).
# All path resolution goes through the unified mechanism (storage.rb):
# CORTEX[:lists]['TF/C01'].find traverses every configured path map.

module Cortex

  LISTS_NAMESPACE = :lists

  # Entity type names follow the same rule as managed entity types: a Ruby
  # constant path segment (Gene, Project::Treatment) so lists can be attached
  # to managed entity types without surprises.
  def self.list_type!(entity_type)
    entity_type = entity_type.to_s
    raise ScoutException,
          "Invalid entity list type #{entity_type.inspect}: expected a constant-like " \
          'name such as TF or Composite (letters/digits, :: segments)' unless entity_type =~ /\A[A-Z][A-Za-z0-9]*(::[A-Z][A-Za-z0-9]*)*\z/
    entity_type
  end

  # The logical resource name of a list: <entity_type>/<list>.  Both segments
  # may nest further (entity_type must stay a single constant-like segment,
  # the list itself may contain subdirectories: TF/sets/cell-cycle.md).
  def self.list_name(entity_type, list)
    list_type! entity_type
    list = sanitize_resource_name! list
    File.join(entity_type, list)
  end

  def self.list_content_path(entity_type, list, map = nil)
    resource_path LISTS_NAMESPACE, list_name(entity_type, list), (map || write_map)
  end

  def self.list_meta_path(entity_type, list, map = nil)
    sidecar_paths(LISTS_NAMESPACE, list_name(entity_type, list), (map || write_map)).first
  end

  # Write a list: newline-separated entities plus the .meta sidecar with the
  # entity_options and provenance metadata.  Returns [name, count, path].
  def self.write_list(entity_type, list, entities, description: nil,
                      entity_options: nil, created_by: nil, job: nil, map: nil)
    name = list_name entity_type, list
    entities = entities.to_s.split("\n").collect(&:strip).reject(&:empty?) unless Array === entities
    raise ScoutException, 'An entity list cannot be empty' if entities.empty?

    map ||= write_map
    target = list_content_path entity_type, list, map
    Open.mkdir File.dirname(target)
    Open.write target, entities.uniq * "\n" + "\n"

    meta_path = list_meta_path entity_type, list, map
    Open.mkdir File.dirname(meta_path)
    require 'yaml'
    meta = {}
    meta['entity_type'] = entity_type.to_s
    meta['description'] = description.to_s unless description.to_s.empty?
    meta['entity_options'] = entity_options if entity_options && !entity_options.empty?
    meta['created_by'] = created_by.to_s unless created_by.to_s.empty?
    meta['created_at'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    meta['job'] = job.to_s unless job.to_s.empty?
    meta['count'] = entities.uniq.length
    Open.write meta_path, YAML.dump(meta)

    [name, entities.uniq.length, target]
  end

  # Read a list: returns [entities, meta, path, map, all_paths].  Tolerant
  # sidecar parsing: a missing or corrupt sidecar yields {}.
  def self.read_list(entity_type, list)
    name = list_name entity_type, list
    path, map, all_paths = resolve_resource(LISTS_NAMESPACE, name)
    unless path
      others = namespace_names(LISTS_NAMESPACE)
      close = others.select { |n| n.start_with?("#{entity_type}/") }
      msg = ["No entity list #{name.inspect} under var/cortex/lists"]
      msg << "Available #{entity_type} lists: #{close.collect { |n| n.split('/', 2).last } * ', '}" if close.any?
      raise ScoutException, msg * ' '
    end

    entities = Open.read(path).to_s.split("\n").collect(&:strip).reject(&:empty?)

    meta_path = sidecar_paths(LISTS_NAMESPACE, name, map).first
    meta = {}
    if meta_path && File.exist?(meta_path)
      require 'yaml'
      begin
        meta = YAML.safe_load(Open.read(meta_path)) || {}
      rescue
        meta = {}
      end
    end

    [entities, meta, path, map, all_paths]
  end

# Entity options recorded in the list's .meta sidecar, if any.  Used when a
# named list feeds a property execution so the receiver is annotated with
# the options the list was defined with.  Returns an empty hash when the
# sidecar or the key is absent; the caller merges (explicit input wins).
def self.list_entity_options(entity_type, list)
  _entities, meta, _path, _map, _maps = read_list(entity_type, list)
  opts = meta.is_a?(Hash) ? meta['entity_options'] : nil
  return {} if opts.nil?
  opts = JSON.parse(opts) if String === opts
  IndiferentHash.setup(opts || {})
end

  # Entities only.
  def self.load_list(entity_type, list)
    read_list(entity_type, list).first
  end

end
