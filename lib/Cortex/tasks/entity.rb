require 'json'
require 'Cortex/entities'

# ==========================================================================
# Cortex-managed executable Entities: agent-facing workflow tasks
# ==========================================================================
#
# Task layer only.  Every task body is a thin call into the engine
# (Cortex.* module functions in lib/Cortex/entities.rb); no validation or
# storage logic lives here.
#
# Surface policy: this file is ADD-ONLY.  The eight tasks below are new
# exports; the existing 12 exports and the frozen receipt contract of
# cortex_continue/cortex_brief are untouched.  The old demonstrator task
# `entity_property` (whose `entity_type` input actually meant entity JSON
# OPTIONS) is deleted rather than aliased: its input contract does not map
# onto cortex_entity_property, so a "compatibility" alias would silently
# reinterpret its inputs.  Use cortex_entity_property instead.
#
# entity input convention (cortex_entity_property): `entity` is a :string.
# A JSON array string (e.g. "[\"TP53\",\"KRAS\"]") is parsed into an entity
# list, anything else is a single entity identifier.
module Cortex

  # ------------------------------------------------------------------
  # Listing: metadata only, grouped by entity type
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Filter by entity type (e.g. Gene); omit to list all types', nil
  input :prefix, :string, 'Only properties whose name starts with this prefix', nil
  input :include_inactive, :boolean, 'Also list tombstoned/removed properties', false
  input :offset, :integer, 'Skip the first N entries', 0
  input :limit, :integer, 'Return at most N entries per page', 50
  task :cortex_property_list => :text do |entity_type, prefix, include_inactive, offset, limit|
    defs = Cortex.property_definitions(entity_type, prefix, active: !include_inactive)
    total = defs.length
    page  = defs[offset.to_i, limit.to_i] || []

    sections = []
    page.group_by { |d| d[:entity_type] }.each do |type, group|
      rows = group.collect do |d|
        meta   = d[:meta]
        active = meta['active'] ? 'active' : 'inactive'
        "  #{meta['entity_type']}/#{meta['property']}<#{d[:map]}>\t#{meta['version']}\t" \
          "#{meta['digest'][0, 8]}\t#{meta['property_type']}\t#{meta['result_type']}\t" \
          "#{Array(meta['arguments']).length} args\t#{Array(meta['dependencies']).length} deps\t#{active}"
      end
      sections << [type, rows]
    end

    header = "entity properties\t#{page.length}/#{total} entries" +
             (entity_type ? " (type #{entity_type})" : '') +
             (prefix ? " (prefix #{prefix})" : '') +
             (include_inactive ? ' (including inactive)' : '')
    text = [header] + sections.collect do |type, rows|
      ["#{type}", "#type/property\tversion\tdigest\tproperty_type\tresult_type\targs\tdeps\tstatus", *rows]
    end
    next_offset = offset.to_i + page.length
    text << ["# next: #{next_offset}"] if next_offset < total
    text.collect { |l| Array === l ? l.join("\n") : l }.join("\n") + "\n"
  end

  # ------------------------------------------------------------------
  # Read: interface metadata + paginated body.  NEVER executes code.
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type of the property (e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name', nil, required: true
  input :start_line, :integer, 'First body line to return (1-based; 0 = interface only)', 0
  input :lines, :integer, 'Max body lines to return per page (0 = all remaining)', 200
  task :cortex_property_read => :text do |entity_type, property, start_line, lines|
    meta = Cortex.property_definition entity_type, property
    raise ScoutException,
          "No entity property #{entity_type}/#{property}. Use " \
          'Cortex cortex_property_list to see available definitions.' if meta.nil?

    args = Array(meta['arguments']).collect do |a|
      "  #{a['name']} : #{a['type']}#{a['required'] ? ' required' : ' optional'}" \
        "#{a.key?('default') ? " default #{a['default'].inspect}" : ''} - #{a['description']}"
    end
    deps = Array(meta['dependencies'])
    iface = [
      "# #{entity_type}/#{property} v#{meta['version']} (#{meta['property_type']} -> #{meta['result_type']})",
      "# digest #{meta['digest']}" + (meta['active'] ? ' active' : " INACTIVE (removed at v#{meta['removed_version']})"),
      meta['description'].to_s.empty? ? nil : "# #{meta['description']}",
      args.empty? ? nil : "# arguments:\n#{args * "\n"}",
      deps.empty? ? nil : "# dependencies: #{deps * ', '}",
      "  history: #{Array(meta['versions']).length} version(s); use cortex_property_history"
    ].compact

    body = meta['body'].to_s
    next iface.join("\n") + "\n" if body.empty?

    body_lines = body.lines
    total      = body_lines.length
    start      = start_line.to_i
    raise ScoutException,
          "Property body has #{total} lines; start_line #{start} is out of range" if start > total
    slice = lines.to_i > 0 ? body_lines[start, lines.to_i] : body_lines[start..-1] || []
    marker = start + slice.length >= total ? "(end)" : "(next: #{start + slice.length})"
    (iface + ["# body lines #{start + 1}-#{start + slice.length} of #{total} #{marker}"] +
     slice.map(&:chomp)).join("\n") + "\n"
  end

  # ------------------------------------------------------------------
  # History: compact version/provenance listing
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type of the property (e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name', nil, required: true
  task :cortex_property_history => :text do |entity_type, property|
    hist = Cortex.property_history entity_type, property
    rows = Array(hist[:versions]).collect do |v|
      "  v#{v['version']}\t#{v['action']}\t#{v['digest'].to_s[0, 8]}\t#{v['job']}\t" \
        "#{v['agent']}\t#{v['timestamp']}"
    end
    snaps = Array(hist[:snapshots]).collect do |s|
      "  #{s[:file]}\tv#{s[:version]}\t#{s[:digest].to_s[0, 8]}#{s[:removed] ? ' removed' : s[:active] ? ' active' : ''}"
    end
    [["history #{entity_type}/#{property}"],
     rows.empty? ? ['# no version records'] : ['# version\taction\tdigest\tjob\tagent\ttimestamp', *rows],
     snaps.empty? ? ['# no snapshots'] : ['# snapshots', *snaps]]
      .collect { |l| Array === l ? l.join("\n") : l }.join("\n") + "\n"
  end

  # ------------------------------------------------------------------
  # Validate: schema + graph + staging compile + optional smoke; no activation
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type of the property (e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name (or candidate name for a new property)', nil, required: true
  input :body, :string, 'Candidate Ruby body; omit to validate the ACTIVE definition', nil
  input :description, :string, 'Candidate description (documentation only)', nil
  input :property_type, :select, 'Property arity: single entity, entity list, or both', nil, select_options: %w(single array both)
  input :result_type, :string, 'Scout result type (string, integer, float, array, tsv, json...)', 'text'
  input :arguments, :text, 'Argument specs in JSON [{name,type,description,required,default}]', []
  input :dependencies, :array, 'Same-entity property names this property depends on', []
  input :test_entity, :string, 'Entity identifier for an optional smoke execution', nil
  input :test_arguments, :text, 'Arguments for the smoke execution (JSON object)', {}
  task :cortex_property_validate => :json do |entity_type, property, body, description,
                                              property_type, result_type, arguments,
                                              dependencies, test_entity, test_arguments|
    checks = []
    errors = []
    smoke  = nil

    arguments = JSON.parse(arguments) if String === arguments
    test_arguments = JSON.parse(test_arguments) if String === test_arguments

    active = begin
      Cortex.property_definition entity_type, property
    rescue ScoutException => e
      errors << "active-definition: #{e.message}"
      nil
    end

    target_body = body || (active && active['body'])
    if target_body.nil?
      errors << 'body: no candidate body supplied and no active definition to validate'
    end

    # --- schema checks -----------------------------------------------
    begin
      pt = Cortex.entity_property_type!(property_type || (active && active['property_type']) || 'single')
      rt = Cortex.entity_result_type!(result_type || (active && active['result_type']) || 'text')
      args = Cortex.entity_arguments!(arguments || (active && active['arguments']) || [])
      deps = Cortex.entity_dependencies!(dependencies || (active && active['dependencies']) || [])
      checks << 'schema: names, types, arguments, dependencies'
    rescue ScoutException => e
      pt = rt = args = deps = nil
      errors << "schema: #{e.message}"
    end

    # --- graph checks -------------------------------------------------
    if pt
      begin
        Cortex.entity_validate_graph!(entity_type, property, deps)
        checks << 'graph: dependencies resolve, acyclic'
      rescue ScoutException => e
        errors << "graph: #{e.message}"
      end
    end

    # --- staging compile ----------------------------------------------
    if pt && target_body
      begin
        digest = Cortex.entity_definition_digest(body: target_body, property_type: pt,
                                                 result_type: rt, arguments: args,
                                                 dependencies: deps)
        Cortex.entity_stage_compile(entity_type, property, body: target_body,
                                    property_type: pt, result_type: rt,
                                    arguments: args, dependencies: deps,
                                    version: (active && active['version'] || 1).to_i,
                                    digest: digest)
        checks << 'compile: envelope compiled in staging module'
      rescue ScoutException => e
        errors << "compile: #{e.message}"
      end
    end

    # --- optional smoke execution --------------------------------------
    if errors.empty? && test_entity
      begin
        mod    = Cortex.entity_stage_compile(entity_type, property, body: target_body,
                                             property_type: pt, result_type: rt,
                                             arguments: args, dependencies: deps,
                                             version: 1, digest: 'smoke')
        entity = mod.setup test_entity
        job    = entity.send "#{property}_job", (test_arguments || {})
        job.run
        result = job.load
        smoke  = { job: job.short_path, result: result }
        # The smoke job is a throwaway artifact of validation, not evidence;
        # drop it so var/jobs only keeps real property jobs.
        job.clean
        checks << 'smoke: executed candidate, job cleaned'
      rescue StandardError => e
        errors << "smoke: #{e.class}: #{e.message}"
      end
    end
    checks << 'smoke: skipped (no test_entity)' if smoke.nil? && errors.empty? && !test_entity

    { valid: errors.empty?, address: "#{entity_type}/#{property}",
      checks: checks, errors: errors, smoke: smoke }
  end

  # ------------------------------------------------------------------
  # Define / update / remove
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name (snake_case)', nil, required: true
  input :body, :string, 'Ruby body; the entity is the receiver, arguments are locals', nil, required: true
  input :description, :string, 'Human-readable description (documentation only)', ''
  input :property_type, :select, 'Property arity: single entity, entity list, or both', 'single', select_options: %w(single array both)
  input :result_type, :string, 'Scout result type (string, integer, float, array, tsv, json...)', 'text'
  input :arguments, :text, 'Argument specs in JSON [{name,type,description,required,default}]', []
  input :dependencies, :array, 'Same-entity property names this property depends on', []
  input :test_entity, :string, 'Entity identifier for a pre-activation smoke execution', nil
  input :test_arguments, :text, 'Arguments for the smoke execution (JSON object)', {}
  input :agent, :string, 'Agent name recorded in provenance', 'Cortex'
  task :cortex_property_define => :json do |entity_type, property, body, description,
                                            property_type, result_type, arguments,
                                            dependencies, test_entity, test_arguments, agent|

    arguments = JSON.parse(arguments) if String === arguments
    test_arguments = JSON.parse(test_arguments) if String === test_arguments

    res = Cortex.define_property(entity_type, property, body: body, description: description,
                                property_type: property_type, result_type: result_type,
                                arguments: arguments, dependencies: dependencies,
                                agent: agent, job: self.short_path,
                                test_entity: test_entity, test_arguments: test_arguments)
    res.merge defined: true
  end

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name (snake_case)', nil, required: true
  input :expected_version, :integer, 'Version being updated (optimistic concurrency)', nil, required: true
  input :body, :string, 'New Ruby body; omit to keep the current one', nil
  input :description, :string, 'New description; omit to keep the current one', nil
  input :property_type, :select, 'Property arity: single, array, or both; omit to keep the current one', nil, select_options: %w(single array both)
  input :result_type, :string, 'Scout result type; omit to keep the current one', nil
  input :arguments, :text, 'Argument specs in JSON; omit to keep the current ones', nil
  input :dependencies, :array, 'Same-entity property names; omit to keep the current ones', nil
  input :test_entity, :string, 'Entity identifier for a pre-activation smoke execution', nil
  input :test_arguments, :text, 'Arguments for the smoke execution (JSON object)', {}
  input :agent, :string, 'Agent name recorded in provenance', 'Cortex'
  task :cortex_property_update => :json do |entity_type, property, expected_version, body,
                                            description, property_type, result_type,
                                            arguments, dependencies, test_entity,
                                            test_arguments, agent|

    arguments = JSON.parse(arguments) if String === arguments
    test_arguments = JSON.parse(test_arguments) if String === test_arguments

    res = Cortex.update_property(entity_type, property, expected_version: expected_version,
                                 body: body, description: description,
                                 property_type: property_type, result_type: result_type,
                                 arguments: arguments, dependencies: dependencies,
                                 agent: agent, job: self.short_path,
                                 test_entity: test_entity, test_arguments: test_arguments)
    res.merge updated: true
  end

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name (snake_case)', nil, required: true
  input :expected_version, :integer, 'Version being removed (optimistic concurrency)', nil, required: true
  input :agent, :string, 'Agent name recorded in provenance', 'Cortex'
  task :cortex_property_remove => :json do |entity_type, property, expected_version, agent|
    res = Cortex.remove_property(entity_type, property, expected_version: expected_version,
                                 agent: agent, job: self.short_path)
    { address: res[:address], removed: true, version: res[:version],
      history_preserved: true }
  end

  # ------------------------------------------------------------------
  # Execution: run an active property for a concrete entity
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name', nil, required: true
  input :entity, :string, 'Entity identifier, or a JSON array of identifiers', nil, required: true
  input :arguments, :text, 'Property arguments (JSON object, never positional)', {}
  input :entity_options, :text, 'Entity annotation options (JSON object)', nil
  input :update, :boolean, 'Clean the property job and recompute it', false
  task :cortex_entity_property => :json do |entity_type, property, entity, arguments,
                                            entity_options, update|
    # `entity` is a string input: parse JSON array payloads into entity lists,
    # keep everything else as a single identifier.
    begin
      parsed = JSON.parse entity
      entity = parsed if Array === parsed
    rescue JSON::ParserError
      # plain identifier
    end

    arguments = JSON.parse(arguments) if String === arguments

    # Read the definition BEFORE running: the run may repoint the loaded
    # generation (update: true cleans+recomputes against the active meta), and
    # the receipt must describe the definition that produced the result.
    defn = Cortex.property_definition entity_type, property
    raise ScoutException,
          "Entity property #{entity_type}/#{property} is not active" if defn.nil? || !defn['active']

    job, result = Cortex.run_entity_property(entity_type: entity_type, property: property,
                                             entity: entity, arguments: arguments || {},
                                             entity_options: entity_options, update: update)

    { entity_type: entity_type, entity: entity, property: property,
      arguments: arguments || {},
      definition_version: defn['version'], definition_digest: defn['digest'],
      # A list receiver fans out to one job per member; report every producer
      # path (the receipt stays a single object: property_job is a String for
      # a scalar receiver and an Array of Strings for a list receiver).
      property_job: Array === job ? job.collect(&:short_path) : job.short_path,
      result: result }
  end

end
