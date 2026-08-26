require 'json'

# ==========================================================================
# Cortex storage: namespaces, path maps, resource names
# ==========================================================================
#
# Every Cortex resource is (namespace, logical name, path map). Writes go to
# Cortex.write_map; reads/searches resolve across Cortex.read_maps in order.
# The path maps themselves (including any per-project maps declared in a
# cortex_path_map.yaml) are configured in lib/Cortex/path_maps.rb; this file
# only consumes them through CORTEX.find(map).
#
# Namespace layout under each map root:
#
#   conversations/  chat files (Scout chat format)
#   briefs/         chat files + .meta sidecars
#   artifacts/      text artifacts + .meta/.history sidecars
#   entities/       <Type>/<property>.rb + .meta/.history (engine-managed,
#                   see lib/Cortex/entities.rb)

module Cortex

  # Storage root. Configured lazily by Cortex.configure_cortex! (see
  # path_maps.rb) the first time any map is resolved: the constant stays a
  # Path, but gains a libdir annotation (the SCOUT_CHAT_DIR anchor) and an
  # instance-level path_maps table (including any yaml-configured maps).
  # Until configuration runs it behaves exactly like the historical
  # Scout.var.cortex.
  CORTEX = Scout.var.cortex

  # Validate a logical resource name for any namespace. Nested relative
  # paths are legal everywhere; absolute paths, ~, '..' segments, and
  # control characters are not.
  def self.sanitize_resource_name!(name)
    name = name.to_s.strip
    raise ScoutException, 'Cortex resource name cannot be empty' if name.empty?
    if name.start_with?('/', '~') || name.split(File::SEPARATOR).include?('..') || name.include?("\n") || name.include?("\t")
      shown = Log.truncate_string(name.inspect)
      raise ScoutException, "Invalid Cortex resource name #{shown}: use simple relative paths (no leading '/', no '..' segment, no '~' prefix, no newline or tab)"
    end
    name
  end

  # Directory of one namespace under one path map.
  def self.namespace_dir(namespace, path_map = nil)
    path_map ||= write_map
    path_map = path_map.to_sym
    raise ScoutException, "Unknown Cortex path map :#{path_map}; configured maps: #{map_names * ', '}" unless map?(path_map)
    CORTEX[namespace.to_s].find path_map
  end

  def self.resource_path(namespace, name, path_map = nil)
    name = sanitize_resource_name! name
    File.join(namespace_dir(namespace, path_map), name)
  end

  def self.resource_paths(namespace, name, maps = nil)
    maps ||= read_maps
    maps.collect { |map| [resource_path(namespace, name, map), map] }.
      # Two maps may resolve to the same physical directory (e.g. :lib and
      # :current in a checkout without a separate lib tree): that is one
      # resource, not an ambiguity. Dedupe by physical path, first map wins.
      uniq { |path, _map| path }
  end

  def self.resource_exists?(namespace, name, maps = nil)
    resource_paths(namespace, name, maps).any? { |path, _map| File.exist?(path) }
  end

  # Resolve a resource across the readable path maps, first hit wins.
  # Returns [path, map, all_paths] where all_paths lists every physical
  # location that exists (used to report cross-map ambiguity).
  def self.resolve_resource(namespace, name, maps = nil)
    found = resource_paths(namespace, name, maps).select { |path, _map| File.exist?(path) }
    return nil if found.empty?
    [found.first.first, found.first.last, found.collect(&:first)]
  end

  # Sidecar stores that travel with their resource on rename/move.
  def self.sidecar_paths(namespace, name, path_map)
    base = namespace_dir(namespace, path_map)
    case namespace.to_sym
    when :artifacts then [File.join(base, '.meta', "#{name}.json"), File.join(base, '.history', name)]
    when :briefs then [File.join(base, '.meta', "#{name}.json")]
    # Entity definitions: <Type>/<property>.rb + per-property .meta/.history.
    # `name` is the compound address "Type/property".
    when :entities
      type, property = name.split(File::SEPARATOR, 2)
      raise ScoutException, "Invalid entities resource #{name.inspect}: expected <Type>/<property>" if property.nil? || property.empty?
      [File.join(base, '.meta', type, "#{property}.json"),
       File.join(base, '.history', type, property)]
    when :conversations then []
    else raise ScoutException, "Unknown Cortex namespace #{namespace}"
    end
  end

  def self.existing_sidecars(namespace, name, path_map)
    sidecar_paths(namespace, name, path_map).select { |p| File.exist?(p) }
  end

  # Recursive enumeration of logical names in a namespace under one map.
  # Dot-directories (.meta, .history) are excluded at every level.
  def self.namespace_names(namespace, path_map = nil)
    dir = namespace_dir(namespace, path_map)
    return [] unless File.directory?(dir)
    Dir.glob(File.join(dir.to_s, '**', '*')).
      select { |f| File.file?(f) }.
      reject { |f| f.split(File::SEPARATOR).any? { |p| p.start_with?('.') } }.
      collect { |f| f[dir.to_s.length + 1..-1] }.
      sort
  end

  # All (name, map, path) entries across the readable maps.
  def self.namespace_entries(namespace, maps = nil)
    maps ||= read_maps
    out = []
    maps.each do |map|
      namespace_names(namespace, map).each do |name|
        path = resource_path(namespace, name, map)
        out << [name, map, path] unless out.any? { |n, _m, p| n == name && p == path }
      end
    end
    out
  end

  # Names present in more than one readable map: listing/search tag these
  # with their map so the ambiguity stays visible.
  def self.ambiguous_names(namespace, maps = nil)
    candidates = namespace_entries(namespace, maps).collect(&:first).uniq
    candidates.select do |name|
      resource_paths(namespace, name, maps).
        select { |path, _map| File.exist?(path) }.
        collect(&:first).uniq.length > 1
    end
  end

end
