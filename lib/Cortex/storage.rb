require 'json'

# ==========================================================================
# Cortex storage: THE single path-resolution mechanism
# ==========================================================================
#
# Every cortical element -- conversations, briefs, artifacts, entities and
# lists -- is addressed as (namespace, full relative path).  Resolution is
# full-path based and delegated entirely to Scout's Path machinery:
#
#     Cortex.cortex_path(namespace, name)      # => CORTEX[namespace][name]
#     .find                                    # first match across map_order
#     .find_all                                # every match, read order
#     .follow(map)                             # concrete path in ONE map
#
# CORTEX (below) is configured by lib/Cortex/path_maps.rb with the complete
# set of path maps AND the map order, so a plain .find already traverses
# every configured location in the right order.  Nothing in this file (or
# anywhere else in Cortex) implements its own per-map search.
#
# Namespace layout under each map root:
#
#   conversations/  chat files (Scout chat format)
#   briefs/         chat files + .meta sidecars
#   artifacts/      text artifacts + .meta/.history sidecars
#   entities/       <Type>/<property>.rb + .meta/.history (engine-managed,
#                   see lib/Cortex/entities.rb)
#   lists/          <entity_type>/<list> newline-separated entity lists
#                   + .meta sidecars (see lib/Cortex/lists.rb)
#
# Names are arbitrary relative paths (any depth); absolute paths, ~, '..'
# and control characters are rejected.

module Cortex

  # Storage root. Configured lazily by Cortex.configure_cortex! (see
  # path_maps.rb): the constant stays a Path but gains a libdir annotation
  # (the project anchor) plus instance-level path_maps and map_order.  Until
  # configuration runs it behaves exactly like the historical Scout.var.cortex.
  CORTEX = Scout.var.cortex

  # The canonical namespaces, in listing order.  'entities' is engine
  # managed (lib/Cortex/entities.rb); everything else is plain storage.
  NAMESPACES = %w(conversations briefs artifacts entities lists).freeze

  # Suffix used by #list_name (singular, for error messages).
  SINGULAR = {
    'conversations' => 'conversation', 'briefs' => 'brief',
    'artifacts' => 'artifact', 'entities' => 'entity property',
    'lists' => 'entity list'
  }.freeze

  def self.validate_namespace!(namespace)
    ns = namespace.to_s
    return ns.to_sym if NAMESPACES.include?(ns)
    raise ScoutException, "Unknown Cortex namespace #{namespace.inspect}; valid namespaces: #{NAMESPACES * ', '}"
  end

  # Validate a logical resource name for any namespace. Nested relative
  # paths of any depth are legal; absolute paths, ~, '..' segments, and
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

  # ------------------------------------------------------------------
  # The mechanism: CORTEX[namespace][full_path] + Path#find / #follow
  # ------------------------------------------------------------------

  # Annotated relative Path for one resource.  Carries CORTEX's libdir,
  # path_maps and map_order, so #find / #find_all / #follow all resolve
  # through the configured maps.
  def self.cortex_path(namespace, name, maps = nil)
    configure_cortex!
    validate_namespace!(namespace)
    name = sanitize_resource_name!(name)
    path = CORTEX[namespace.to_s][name]
    path.map_order = maps.collect(&:to_sym) if maps && !maps.empty?
    path
  end

  # Concrete path of a resource in ONE map (default: the write map).
  # This is a write/target address: it does not check existence.
  def self.resource_path(namespace, name, path_map = nil)
    path_map ||= write_map
    path_map = path_map.to_sym
    raise ScoutException, "Unknown Cortex path map :#{path_map}; configured maps: #{map_names * ', '}" unless map?(path_map)
    cortex_path(namespace, name).follow(path_map).to_s
  end

  # Directory of one namespace under one path map.
  def self.namespace_dir(namespace, path_map = nil)
    resource_dir = resource_path(namespace, '.', path_map)
    File.dirname(resource_dir)
  end

  # Every (path, map) candidate in read order.  Maps whose templates resolve
  # to the same physical directory collapse to one entry (first map wins):
  # that is one resource, not an ambiguity.
  def self.resource_paths(namespace, name, maps = nil)
    maps ||= read_maps
    path = cortex_path(namespace, name, maps)
    maps.collect { |map| [path.follow(map).to_s, map] }.
      uniq { |candidate, _map| candidate }
  end

  def self.resource_exists?(namespace, name, maps = nil)
    resource_paths(namespace, name, maps).any? { |path, _map| File.exist?(path) }
  end

  # Resolve a resource across the readable path maps: FIRST MATCH WINS, in
  # map_order.  Delegates the traversal to Path#find_all so a resource that
  # exists only in a secondary map (a yaml-configured one, :lib, :user...)
  # is found, and a resource present in several maps resolves to the first
  # map in read order.
  #
  # Returns [path, map, all_paths] where all_paths lists every physical
  # location that exists (used to report cross-map ambiguity), or nil.
  def self.resolve_resource(namespace, name, maps = nil)
    path = cortex_path(namespace, name, maps)
    if maps
      found = maps.collect { |map| [path.follow(map).to_s, map] }.
        select { |candidate, _map| File.exist?(candidate) }
      return nil if found.empty?
      [found.first.first, found.first.last, found.collect(&:first)]
    else
      all = path.find_all
      return nil if all.empty?
      first = all.first
      [first.to_s, first.where, all.collect(&:to_s)]
    end
  end

  # First matching annotated Path (nil when absent); .where names its map.
  def self.locate(namespace, name, maps = nil)
    triple = resolve_resource(namespace, name, maps)
    return nil unless triple
    found = Path.setup(triple.first)
    found.instance_variable_set(:@where, triple[1])
    found
  end

  # ------------------------------------------------------------------
  # Sidecars: stores that travel with their resource on rename/move
  # ------------------------------------------------------------------

  def self.sidecar_paths(namespace, name, path_map)
    base = namespace_dir(namespace, path_map)
    case namespace.to_s
    when 'artifacts' then [File.join(base, '.meta', "#{name}.json"), File.join(base, '.history', name)]
    when 'briefs' then [File.join(base, '.meta', "#{name}.json")]
    # Entity definitions: <Type>/<property>.rb + per-property .meta/.history.
    # `name` is the compound address "Type/property".
    when 'entities'
      type, property = name.split(File::SEPARATOR, 2)
      raise ScoutException, "Invalid entities resource #{name.inspect}: expected <Type>/<property>" if property.nil? || property.empty?
      [File.join(base, '.meta', type, "#{property}.json"),
       File.join(base, '.history', type, property)]
    # Named entity lists: <entity_type>/<list> + .meta/<entity_type>/<list>.yaml
    when 'lists'
      type, list = name.split(File::SEPARATOR, 2)
      raise ScoutException, "Invalid lists resource #{name.inspect}: expected <entity_type>/<list>" if list.nil? || list.empty?
      [File.join(base, '.meta', type, "#{list}.yaml")]
    when 'conversations' then []
    else raise ScoutException, "Unknown Cortex namespace #{namespace}"
    end
  end

  def self.existing_sidecars(namespace, name, path_map)
    sidecar_paths(namespace, name, path_map).select { |p| File.exist?(p) }
  end

  # ------------------------------------------------------------------
  # Enumeration (listings, search, availability hints)
  # ------------------------------------------------------------------

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

  # Names present in more than one readable map: listing/search report the
  # map of every entry in a dedicated column, so these are simply the names
  # that occupy more than one row.
  def self.ambiguous_names(namespace, maps = nil)
    candidates = namespace_entries(namespace, maps).collect(&:first).uniq
    candidates.select do |name|
      resource_paths(namespace, name, maps).
        select { |path, _map| File.exist?(path) }.
        collect(&:first).uniq.length > 1
    end
  end

end
