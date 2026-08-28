# ==========================================================================
# Cortex property-execution registry
# --------------------------------------------------------------------------
# ONE JSON record per (entity_type, property, receiver) under the
# `properties` namespace:
#
#   var/cortex/properties/<Type>/<property>/<receiver>.json
#
# where <receiver> is either the entity identifier (Tp53) or
# `list:<Type>_<list>` for a named-list execution.  The record holds an
# `examinations` array keyed by a digest of the property arguments, so the
# user-visible contract "FOXO1 / activity_in_experiment examined several
# times for different treatments" becomes: one record, one examination per
# argument set, each with its own property_job (the evidence-producing
# Step) and its own run count.
#
# Terminology (fixed by the user): `entities/` holds property CODE
# (definitions); `properties/` holds property EXECUTIONS.  The property
# Step remains the source of truth for results -- records store a result
# fingerprint only, never result copies.
#
# The registry is engine-managed: records are written by
# Cortex.record_property_execution (called from the cortex_entity_property
# task) and are read through the ordinary listing/read/search surface.
# No .history versioning for v1: upsert semantics on the examination
# entry (runs / last_run), decided in research/notes-execution-registry.md.
# ==========================================================================

require 'json'
require 'digest/sha2'

module Cortex

  PROPERTIES_NAMESPACE = :properties

  # ------------------------------------------------------------------
  # Validations (self-contained: do not depend on entities.rb load order)
  # ------------------------------------------------------------------

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

  # ------------------------------------------------------------------
  # Paths
  # ------------------------------------------------------------------

  # Registry root.  Falls back to the storage mechanism when available and
  # otherwise anchors at var/cortex/properties under the project root.
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

  def self.execution_arguments_digest(arguments)

  # One deterministic record name per (receiver, arguments) so re-running a
  # different treatment creates a distinct, browsable record.
  def self.execution_record_name(entity_type, property, receiver, arguments = {})
    execution_receiver!(execution_record_path(
      entity_type, property, receiver).sub(%r{^#{Regexp.escape(properties_dir)}\/?}, '').sub(/\.json$/, ''))
  end

  # Render an execution record (or a compact index of all of them) for
  # cortex_read.
  def self.read_execution_record(name, map = nil)
    path = File.join(properties_dir(map), name.to_s + '.json')
    raise ScoutException, "No such properties record #{name}" unless File.file?(path)
    JSON.pretty_generate(JSON.parse(File.read(path)))
  rescue JSON::ParserError
    raise ScoutException, "Malformed properties record #{name}"
  end

  def self.list_properties_rows(map = nil)
    require 'json'
    execution_record_names(map).collect do |name|
      path = File.join(properties_dir(map), name + '.json')
      rec = JSON.parse(File.read(path)) rescue {}
      [name, map.to_s,
       Array(rec['examinations']).length.to_s,
       rec['runs'].to_s,
       rec['last_run'].to_s]
    end
  end
    Digest::SHA256.hexdigest((arguments || {}).to_json)[0, 12]
  end

  def self.load_execution_record(entity_type, property, receiver, map = nil)
    path = execution_record_path(entity_type, property, receiver, map)
    return nil unless File.exist?(path)
    IndiferentHash.setup(JSON.parse(File.read(path)))
  rescue JSON::ParserError
    nil
  end

  # ------------------------------------------------------------------
  # Recording
  # ------------------------------------------------------------------

  def self.record_property_execution(entity_type:, property:, receiver:,
                                     arguments: {}, defn: {},
                                     entity: nil, list_name: nil,
                                     producer: nil, property_job: nil,
                                     definition_version: nil,
                                     definition_digest: nil,
                                     result_digest: nil, update: false,
                                     job: nil, agent: nil)
    property_job = property_job || producer
    property_job = property_job.short_path if property_job.respond_to?(:short_path)
    raise ScoutException, "property_job required to record an execution" if property_job.nil? || property_job.to_s.empty?

    entity_type = entity_type!(entity_type)
    property    = entity_property_name!(property)
    defn        = IndiferentHash.setup(defn || {})
    definition_version ||= defn['version']
    definition_digest  ||= defn['digest']

    receiver      = execution_receiver!(receiver)
    list_name     = list_name.to_s if list_name
    list_name     = receiver.sub(/\Alist:[^_]+_/, '') if list_name.to_s.empty? && receiver.to_s.start_with?('list:')
    entity        = entity.to_s unless entity.nil?

    arg_digest = execution_arguments_digest(arguments)
    path       = execution_record_path(entity_type, property, receiver)
    rec        = load_execution_record(entity_type, property, receiver) ||
                 IndiferentHash.setup({
                   'entity_type' => entity_type,
                   'property'    => property,
                   'receiver'    => receiver,
                   'entity'      => entity || (receiver.start_with?('list:') ? nil : receiver),
                   'list'        => (list_name && !list_name.empty?) ? list_name : nil,
                   'created'     => Time.now.utc.iso8601,
                   'examinations' => []
                 })

    exam = (rec['examinations'] || []).find { |e| e['arguments_digest'] == arg_digest }
    if exam
      exam['runs'] = exam['runs'].to_i + 1
      exam['last_run'] = Time.now.utc.iso8601
      exam['forced_update'] = true if update
      exam['property_job'] = property_job.to_s
      exam['definition_version'] = definition_version if definition_version
      exam['definition_digest'] = definition_digest if definition_digest
      exam['result_digest'] = result_digest if result_digest
      exam['last_producer_job'] = job.to_s if job
      exam['last_agent'] = agent.to_s if agent
    else
      rec['examinations'] << IndiferentHash.setup({
        'arguments' => IndiferentHash.setup(arguments || {}),
        'arguments_digest' => arg_digest,
        'runs' => 1,
        'first_run' => Time.now.utc.iso8601,
        'last_run' => Time.now.utc.iso8601,
        'forced_update' => !!update,
        'property_job' => property_job.to_s,
        'definition_version' => definition_version,
        'definition_digest' => definition_digest,
        'result_digest' => result_digest,
        'first_producer_job' => job.to_s,
        'last_producer_job' => job.to_s,
        'first_agent' => agent.to_s,
        'last_agent' => agent.to_s
      }.compact)
    end

    rec['last_run'] = Time.now.utc.iso8601

    Open.mkdir(File.dirname(path))
    Open.write(path, JSON.pretty_generate(rec))
    rec
  end

  def self.result_digest_for(producer, _entity = nil)
    return nil unless producer.respond_to?(:path)
    content = begin
      producer.done? ? producer.load.to_s : producer.path.to_s
    rescue
      producer.path.to_s
    end
    Digest::SHA256.hexdigest(content.to_s)[0, 12]
  rescue
    nil
  end

  # All records (for listing): relative names <Type>/<property>/<receiver>.
  def self.execution_record_names(map = nil)
    dir = Path.setup(properties_dir(map))
    return [] unless dir.directory?
    dir.glob('**/*.json').collect do |file|
      file.sub(/^#{Regexp.escape(dir.to_s)}\/?/, '').sub(/\.json$/, '')
    end.sort
  end

  # Flat list of examinations, each annotated with its record context.
  def self.all_examinations(map = nil)
    execution_record_names(map).collect do |name|
      type, property, receiver = name.split(File::SEPARATOR, 3)
      rec = load_execution_record(type, property, receiver)
      next nil if rec.nil?
      (rec['examinations'] || []).collect do |e|
        {
          'entity_type' => type, 'property' => property, 'receiver' => receiver,
          'entity' => receiver.start_with?('list:') ? nil : receiver,
          'list' => receiver.start_with?('list:') ? receiver.sub('list:', '').split('_', 2)[1] : nil
        }.merge(e).merge('list' => e['list'] || (receiver.start_with?('list:') ? receiver.sub('list:', '').split('_', 2)[1] : nil))
      end
    end.compact.flatten
  end

end
