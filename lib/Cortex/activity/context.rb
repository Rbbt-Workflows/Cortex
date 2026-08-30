# Facet context: read-only view over the entity and the workspace stores.
# Facets receive this object (or its hash form) and MUST NOT mutate it.

module Cortex

  class ActivityContext

    attr_reader :entity_type, :entity, :limit, :requested_facets

    def initialize(entity_type:, entity:, limit: 10, facets: nil)
      @entity_type = Cortex.entity_type!(entity_type).to_s
      @entity      = entity.to_s
      @limit       = (limit.nil? || limit.to_i <= 0) ? 10 : limit.to_i
      @requested_facets = resolve_facets(facets)
    end

    # nil / empty => every facet in registration order; String => comma
    # list; Array/Enumerable => as given (still validated by the
    # dispatcher against the registry).
    def resolve_facets(facets)
      names = case facets
              when nil then []
              when String then facets.split(',').collect { |f| f.strip }.reject(&:empty?)
              when Array, Enumerable then facets.collect { |f| f.to_s.strip }.reject(&:empty?)
              else [facets.to_s]
              end
      names.empty? ? Cortex::ACTIVITY_FACETS.keys.dup : names
    end

    # ------------------------------------------------------------------
    # Read access to the existing stores (facets use these, never the
    # storage layer directly, so read maps stay consistent).
    # ------------------------------------------------------------------

    def property_definitions
      Cortex.property_definitions(entity_type)
    end

    def property_definition(property)
      Cortex.property_definition(entity_type, property)
    end

    # Flat examination list for every entity type/property/receiver
    # (lib/Cortex/properties.rb #all_examinations).
    def examinations
      @examinations ||= Cortex.all_examinations
    end

    # Examinations whose receiver or member is exactly this entity id,
    # i.e. both direct (entity => "TP53") and per-member list runs.
    def entity_examinations
      @entity_examinations ||=
        examinations.select do |e|
          e['entity_type'].to_s == entity_type &&
            (e['entity'].to_s == entity || (e['entity'].to_s.empty? && e['receiver'] == entity))
        end
    end

    # One row per named list of this entity type that exists on any
    # readable map (lazy; used by the lists facet).
    def list_entries
      @list_entries ||= begin
        rows = []
        Cortex.namespace_entries(:lists).sort_by { |name, _map, _path| name.to_s }.each do |name, map, path|
          type, id = name.to_s.split(File::SEPARATOR, 2)
          next unless type == entity_type && !id.to_s.empty?
          next unless File.file?(path)
          members = Open.read(path).to_s.split("\n").collect(&:strip).reject(&:empty?)
          rows << { 'name' => name, 'list' => id, 'map' => map.to_s,
                    'members' => members,
                    'contains_entity' => members.include?(entity) }
        end
        rows
      end
    end

    def list_meta(list)
      _entities, meta, _path = Cortex.read_list(entity_type, list)
      meta || {}
    rescue ScoutException
      {}
    end

    # Deterministic text matches of the entity id across conversations,
    # briefs and artifacts, reusing the existing search machinery.
    # namespace_entries order is glob-derived, so results are sorted
    # explicitly before the limit is applied.
    def mentions(limit = nil)
      limit ||= @limit
      found = []
      { 'conversations' => :search_conversations,
        'briefs' => :search_text_namespace,
        'artifacts' => :search_text_namespace }.each do |ns, search|
        rows = Cortex.send(search, entity, ns, limit)
        rows.each do |type, name, map, match|
          found << { 'type' => type.to_s, 'name' => name.to_s,
                     'map' => map.to_s, 'match' => match.to_s }
        end
      end
      found.sort_by { |m| [m['type'], m['map'], m['name'], m['match']] }
    end

  end

end

