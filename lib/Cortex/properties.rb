# ==========================================================================
# Cortex property-execution registry — RETIRED as a WRITE target (design §4)
# --------------------------------------------------------------------------
# History store, read-only.  The records under
# var/cortex/properties/<Type>/<property>/<receiver>.json (examinations
# arrays, receivers including list:<Type>_<list>) stay on disk untouched and
# are read as HISTORY by:
#
#   * cortex_list type=properties    (rows tagged source registry_history)
#   * cortex_read type=properties    (legacy record rendering)
#   * cortex_search type=properties  (content match over legacy records)
#   * cortex_activity investigations (entries tagged source registry_history)
#
# Current evidence is the var/jobs Step tree (lib/Cortex/evidence.rb):
# nothing writes this namespace again.  All WRITE functions of the old
# registry (record_property_execution, execution_record_name, ...) were
# removed with the old run path in entities.rb.
# ==========================================================================

require 'json'

module Cortex

  PROPERTIES_NAMESPACE = :properties

  def self.entity_type!(type)
    type = type.to_s
    raise ScoutException, "Invalid entity type #{type.inspect}" unless type =~ /\A[A-Z][A-Za-z0-9_:]*\z/
    type
  end

  def self.entity_property_name!(name)
    name = name.to_s
    raise ScoutException, "Invalid property name #{name.inspect}" unless name =~ /\A[a-z][a-z0-9_]*\z/
    name
  end

  def self.properties_dir(map = nil)
    if respond_to?(:namespace_dir)
      namespace_dir(PROPERTIES_NAMESPACE, map || (respond_to?(:configured_write_map) ? configured_write_map : nil)).to_s
    else
      base = if defined?(CORTEX) && CORTEX
               CORTEX
             else
               Path.setup(File.join(Dir.pwd, 'var', 'cortex'))
             end
      base[PROPERTIES_NAMESPACE.to_s].to_s
    end
  end

  def self.execution_receiver!(receiver)
    receiver = receiver.to_s
    raise ScoutException, "Empty execution receiver" if receiver.empty?
    receiver.gsub(%r{[^\w:.\-]}, '_')
  end

  def self.execution_record_path(entity_type, property, receiver, map = nil)
    File.join(properties_dir(map), entity_type!(entity_type), property.to_s,
              execution_receiver!(receiver) + '.json')
  end

  # Read a legacy record as-is (HISTORY).
  def self.load_execution_record(entity_type, property, receiver, map = nil)
    path = execution_record_path(entity_type, property, receiver, map)
    return nil unless File.exist?(path)
    IndiferentHash.setup(JSON.parse(File.read(path)))
  rescue JSON::ParserError
    nil
  end

  def self.read_execution_record(name, map = nil)
    path = File.join(properties_dir(map), name.to_s + '.json')
    raise ScoutException, "No such properties record #{name}" unless File.file?(path)
    JSON.pretty_generate(JSON.parse(File.read(path)))
  rescue JSON::ParserError
    raise ScoutException, "Malformed properties record #{name}"
  end

  # All legacy records (for listing history rows).
  def self.execution_record_names(map = nil)
    dir = Path.setup(properties_dir(map))
    return [] unless dir.directory?
    dir.glob('**/*.json').collect do |file|
      file.sub(/^#{Regexp.escape(dir.to_s)}\/?/, '').sub(/\.json$/, '')
    end.sort
  end

  # Flat list of LEGACY examinations (the retired registry vocabulary,
  # rendered verbatim for recall), each tagged source registry_history.
  def self.all_examinations
    execution_record_names.flat_map do |name|
      type, property, receiver = name.split(File::SEPARATOR, 3)
      rec = load_execution_record(type, property, receiver)
      next [] if rec.nil?
      (rec['examinations'] || []).collect do |e|
        {
          'entity_type' => type, 'property' => property, 'receiver' => receiver,
          'entity' => receiver.start_with?('list:') ? nil : receiver,
          'list' => receiver.start_with?('list:') ? receiver.sub('list:', '').split('_', 2)[1] : nil,
          'source' => 'registry_history'
        }.merge(e)
      end
    end.compact
  end

end
