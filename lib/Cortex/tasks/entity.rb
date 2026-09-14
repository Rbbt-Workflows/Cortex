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
# Surface policy (redesign steps 4-5): cortex_property_run (§2.3) and
# cortex_result (§2.4) are the run/resolve surface and NO code path writes
# var/cortex/properties (the old run engine and its task alias are gone;
# legacy records are read-only history).  cortex_property_validate follows
# §2.2 (throwaway scratch module; smoke always clean:true in a fresh scratch
# directory; never mutates the store).  define/update take result_kind
# (result_type still accepted, loudly).
#
# entity input convention (cortex_property_run): `entity` is a :string.
# A JSON array string (e.g. "[\"TP53\",\"KRAS\"]") is parsed into an entity
# list (fan-out for :single), anything else is a single entity identifier.
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
        "  #{meta['entity_type']}/#{meta['property']}\t#{d[:map]}\t#{meta['version']}\t" \
          "#{meta['digest'][0, 8]}\t#{meta['property_type']}\t#{meta['result_kind'] || meta['result_type']}\t" \
          "#{Array(meta['arguments']).length} args\t#{Array(meta['dependencies']).length} deps\t#{active}"
      end
      sections << [type, rows]
    end

    header = "entity properties\t#{page.length}/#{total} entries" +
             (entity_type ? " (type #{entity_type})" : '') +
             (prefix ? " (prefix #{prefix})" : '') +
             (include_inactive ? ' (including inactive)' : '')
    text = [header] + sections.collect do |type, rows|
      ["#{type}", "#type/property\tmap\tversion\tdigest\tproperty_type\tresult_kind\targs\tdeps\tstatus", *rows]
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
      "# #{entity_type}/#{property} v#{meta['version']} (#{meta['property_type']} -> #{meta['result_kind'] || meta['result_type']})",
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
  # Validate: design §2.2 — compile in a throwaway scratch module; smoke with
  # clean:true in a scratch directory (never cached, never mutating).
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type of the property (e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name (or candidate name for a new property)', nil, required: true
  input :body, :string, 'Candidate Ruby body; omit to validate the ACTIVE definition', nil
  input :description, :string, 'Candidate description (documentation only)', nil
  input :property_type, :select, 'Property arity: single entity, entity list, or both', nil, select_options: %w(single array both)
  input :result_kind, :string, 'Declared result kind (string, integer, float, array, tsv, json...)', nil
  input :result_type, :string, 'DEPRECATED alias of result_kind (accepted indefinitely, reported loudly)', nil
  input :arguments, :text, 'Argument specs in JSON [{name,type,description,required,default}]', [], nofile: true
  input :dependencies, :array, 'Same-entity property names this property depends on', []
  input :test_entity, :string, 'Entity identifier for an optional smoke execution', nil
  input :test_arguments, :text, 'Arguments for the smoke execution (JSON object)', {}, nofile: true
  task :cortex_property_validate => :json do |entity_type, property, body, description,
                                              property_type, result_kind, result_type,
                                              arguments, dependencies, test_entity, test_arguments|
    # result_type -> result_kind rename, recognized loudly (§9)
    warnings = []
    unless result_type.to_s.strip.empty?
      result_kind = result_type
      warnings << "Input 'result_type' is deprecated; use 'result_kind' " \
                  "(value #{result_type.inspect} accepted)"
    end

    checks = []
    errors = []
    smoke  = :not_requested

    arguments = parse_json arguments, :arguments
    test_arguments = parse_json test_arguments, :test_arguments

    active = begin
      Cortex.property_definition entity_type, property
    rescue ScoutException => e
      errors << "active-definition: #{e.message}"
      nil
    end

    target_body = body || (active && active['body'])
    errors << 'body: no candidate body supplied and no active definition to validate' if target_body.nil?

    # --- schema checks -----------------------------------------------
    begin
      pt = Cortex.entity_property_type!(property_type || (active && active['property_type']) || 'single')
      rt = Cortex.entity_result_type!(result_kind || (active && active['result_kind']) || (active && active['result_type']) || 'text')
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

    # --- staging compile in a THROWAWAY scratch module (§2.2) ----------
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
        checks << 'compile: envelope compiled in throwaway scratch module'
      rescue ScoutException => e
        errors << "compile: #{e.message}"
      end
    end

    # --- optional smoke: ALWAYS clean:true (never cached), §2.2 ---------
    # The smoke Step's path is derived, cleaned, then run: no code path can
    # serve a previous run's .info.  EntityPropertyTimeout is an Exception
    # (not StandardError) and is routed explicitly.
    smoke_job = nil
    if errors.empty? && test_entity
      begin
        # §2.2 + dependency support: a candidate WITH dependencies must be
        # staged together with its upstream properties, or the dep block's
        # mod.job(:dep, ...) hits a nil task (recursive_inputs on nil).  The
        # staging module is therefore built from the ACTIVE manifest of the
        # type, with the candidate property substituted; the upstream tasks
        # are the same compiled code a real run would use.
        staging_manifest = Cortex.entity_manifest(entity_type).reject do |d|
          d[:property] == property
        end
        identities = {}
        staging_manifest.each do |d|
          m = d[:meta] || {}
          identities[d[:property].to_sym] = {
            _cortex_definition: entity_type + '/' + d[:property],
            _cortex_definition_version: m['version'].to_i,
            _cortex_definition_digest: m['digest']
          }
        end
        smoke_mod = Cortex::Types.for(entity_type)
        staging_manifest.sort_by { |d| Array((d[:meta] || {})['dependencies']).length }
                        .each do |d|
          Cortex.entity_compile_property!(smoke_mod, d, identities)
        end
        candidate = {
          type: entity_type, property: property, body: target_body,
          body_path: "staged:#{entity_type}/#{property}.rb",
          meta: { 'entity_type' => entity_type, 'property' => property,
                  'property_type' => pt, 'result_type' => rt,
                  'arguments' => args, 'dependencies' => deps,
                  'version' => 1, 'digest' => 'smoke' }
        }
        identities[property.to_sym] = {
          _cortex_definition: entity_type + '/' + property,
          _cortex_definition_version: 1,
          _cortex_definition_digest: 'smoke'
        }
        Cortex.entity_compile_property!(smoke_mod, candidate, identities)
        # §2.2: the smoke runs in a THROWAWAY scratch directory, not in the
        # var/jobs evidence tree.  A unique directory per call also makes a
        # cached .info structurally impossible (fresh path -> fresh Step).
        scratch_root = Path.setup(File.join(Scout.tmp.find, 'cortex_validate_smoke',
                                            "#{Process.pid}_#{Time.now.to_f}"))
        smoke_mod.directory = scratch_root
        smoke_entity = smoke_mod.setup test_entity
        smoke_job    = smoke_entity.send "#{property}_job", (test_arguments || {})
        smoke_job.clean
        smoke_address = nil
        Cortex.entity_property_with_timeout(Cortex.entity_property_timeout(nil)) do
          smoke_job.run
          loaded = smoke_job.load
          smoke_address = smoke_job.short_path
          # Kind check (§2.6 F4-(iii)): declared kind vs loaded class.
          expected = case rt.to_s
                     when 'string', 'text'   then String
                     when 'integer', 'float' then Numeric
                     when 'array'            then Array
                     else nil
                     end
          if expected && !loaded.is_a?(expected)
            errors << "kind: declared result_kind #{rt.inspect} but the smoke " \
                      "loaded #{loaded.class} (#{loaded.inspect[0, 60]})"
          else
            checks << 'kind: smoke loaded the declared result kind'
          end
        end
        smoke = { status: :done, address: smoke_address,
                  scratch_root: scratch_root.find.to_s }
        checks << 'smoke: executed candidate in a throwaway scratch root (never cached)'
      rescue Cortex::EntityPropertyTimeout => e
        smoke = { status: :error,
                  address: (smoke_job.short_path rescue nil),
                  scratch_root: (scratch_root.find.to_s rescue nil),
                  exception_class: e.class.name,
                  exception_message: e.message,
                  verdict: Cortex::Error.verdict_of(e) }
        errors << "smoke: #{e.class}: #{e.message}"
        smoke_job.clean if smoke_job.respond_to?(:clean)
      rescue Exception => e # rubocop:disable Lint/RescueException
        envelope = Cortex::Error.envelope(e, context: { phase: 'validate_smoke',
                                                        entity_type: entity_type,
                                                        property: property,
                                                        test_entity: test_entity })
        smoke = { status: :error,
                  address: (smoke_job.short_path rescue nil),
                  scratch_root: (scratch_root.find.to_s rescue nil),
                  exception_class: envelope[:exception_class],
                  exception_message: envelope[:exception_message],
                  message_is_bare: envelope[:message_is_bare],
                  verdict: envelope[:verdict] }
        errors << 'smoke: ' + (envelope[:message_is_bare] ?
                                 "#{envelope[:exception_class]} (BARE raise - " \
                                 'add an explanatory message)' :
                                 envelope[:exception_message])
        smoke_job.clean if smoke_job.respond_to?(:clean)
      end
    end

    out = { valid: errors.empty?, address: "#{entity_type}/#{property}",
            checks: checks, errors: errors, smoke: smoke }
    out[:warnings] = warnings unless warnings.empty?
    out
  end

  # ------------------------------------------------------------------
  # Define / update / remove
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name (snake_case)', nil, required: true
  input :body, :string, 'Ruby body; the entity is the receiver, arguments are locals', nil, required: true
  input :description, :string, 'Human-readable description (documentation only)', ''
  input :property_type, :select, 'Property arity: single entity, entity list, or both', 'single', select_options: %w(single array both)
  input :result_kind, :string, 'Declared result kind (string, integer, float, array, tsv, json...)', 'text'
  input :result_type, :string, 'DEPRECATED alias of result_kind (accepted indefinitely, reported loudly)', nil
  input :arguments, :text, 'Argument specs in JSON [{name,type,description,required,default}]', [], nofile: true
  input :dependencies, :array, 'Same-entity property names this property depends on', []
  input :test_entity, :string, 'Entity identifier for a pre-activation smoke execution', nil
  input :test_arguments, :text, 'Arguments for the smoke execution (JSON object)', {}, nofile: true
  input :agent, :string, 'Agent name recorded in provenance', 'Cortex'
  task :cortex_property_define => :json do |entity_type, property, body, description,
                                            property_type, result_kind, result_type,
                                            arguments, dependencies, test_entity, test_arguments, agent|
    warnings = []
    unless result_type.to_s.strip.empty?
      result_kind = result_type
      warnings << "Input 'result_type' is deprecated; use 'result_kind' " \
                  "(value #{result_type.inspect} accepted)"
    end

    arguments = parse_json arguments, :arguments
    test_arguments = parse_json test_arguments, :test_arguments

    res = Cortex.define_property(entity_type, property, body: body, description: description,
                                property_type: property_type, result_type: result_kind,
                                arguments: arguments, dependencies: dependencies,
                                agent: agent, job: self.short_path,
                                test_entity: test_entity, test_arguments: test_arguments)
    # The store returns {address, version, digest}; the §2.1 receipt adds
    # property_type and result_kind (result_type recognized on read, §9).
    res[:property_type] = property_type if property_type
    res[:result_kind] = result_kind
    res[:definition_path] = "entities/#{entity_type}/#{property}"
    res = res.merge defined: true
    res[:warnings] = warnings unless warnings.empty?
    res
  end

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name (snake_case)', nil, required: true
  input :expected_version, :integer, 'Version being updated (optimistic concurrency)', nil, required: true
  input :body, :string, 'New Ruby body; omit to keep the current one', nil
  input :description, :string, 'New description; omit to keep the current one', nil
  input :property_type, :select, 'Property arity: single, array, or both; omit to keep the current one', nil, select_options: %w(single array both)
  input :result_kind, :string, 'Declared result kind; omit to keep the current one', nil
  input :result_type, :string, 'DEPRECATED alias of result_kind (accepted indefinitely, reported loudly)', nil
  input :arguments, :text, 'Argument specs in JSON; omit to keep the current ones', nil, nofile: true
  input :dependencies, :array, 'Same-entity property names; omit to keep the current ones', nil
  input :test_entity, :string, 'Entity identifier for a pre-activation smoke execution', nil
  input :test_arguments, :text, 'Arguments for the smoke execution (JSON object)', {}, nofile: true
  input :agent, :string, 'Agent name recorded in provenance', 'Cortex'
  task :cortex_property_update => :json do |entity_type, property, expected_version, body,
                                            description, property_type, result_kind,
                                            result_type, arguments, dependencies, test_entity,
                                            test_arguments, agent|
    warnings = []
    unless result_type.to_s.strip.empty?
      result_kind = result_type
      warnings << "Input 'result_type' is deprecated; use 'result_kind' " \
                  "(value #{result_type.inspect} accepted)"
    end

    arguments = parse_json arguments, :arguments

    test_arguments = parse_json test_arguments, :test_arguments

    res = Cortex.update_property(entity_type, property, expected_version: expected_version,
                                 body: body, description: description,
                                 property_type: property_type, result_type: result_kind,
                                 arguments: arguments, dependencies: dependencies,
                                 agent: agent, job: self.short_path,
                                 test_entity: test_entity, test_arguments: test_arguments)
    # §2.1 receipt; result_kind reflects the post-update definition (the
    # caller-supplied value when given, else the previous one).
    res[:result_kind] = result_kind ||
                        (begin
                          Cortex.property_definition(entity_type, property)['result_kind'] ||
                          Cortex.property_definition(entity_type, property)['result_type']
                        rescue StandardError
                          nil
                        end)
    res[:definition_path] = "entities/#{entity_type}/#{property}"
    res = res.merge updated: true
    res[:warnings] = warnings unless warnings.empty?
    res
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
  # Execution (design §2.3): cortex_property_run is the run surface (the
  # historical cortex_entity_property task was retired with the registry).
  # ------------------------------------------------------------------

  input :entity_type, :string, 'Entity type (Ruby constant path, e.g. Gene)', nil, required: true, jobname: true
  input :property, :string, 'Property name', nil, required: true
  input :entity, :string, 'Entity id (single receiver; never together with list). An inline JSON array is accepted and fans out', nil
  input :list, :string, 'Named list <entity_type>/<list> (never together with entity)', nil
  input :arguments, :text, 'Property arguments (JSON object, never positional)', {}, nofile: true
  input :entity_options, :text, 'Entity annotation options (JSON object)', nil, nofile: true
  input :update, :boolean, 'Clean the property job(s) and recompute', false
  input :timeout, :integer, 'Execution timeout in seconds; omit to use the configured default (config key timeout, tokens entity_property/cortex; env CORTEX_ENTITY_PROPERTY_TIMEOUT; default 3600). 0/false/none = unbounded', nil
  input :agent, :string, 'Agent name recorded in provenance', 'Cortex'
  task :cortex_property_run => :json do |entity_type, property, entity, list, arguments,
                                         entity_options, update, timeout, agent|
    raise ScoutException,
          'Provide either entity or list, not both' if !entity.to_s.strip.empty? && !list.to_s.strip.empty?
    raise ScoutException,
          'Provide an entity identifier or a named list (entity or list)' if entity.to_s.strip.empty? && list.to_s.strip.empty?

    arguments = parse_json arguments, :arguments
    entity_options = parse_json entity_options, :entity_options

    receiver = if list.to_s.strip.size > 0
                 { list: list.to_s }
               else
                 parsed = begin
                   parse_json entity, :entity
                 rescue StandardError
                   nil
                 end
                 Array === parsed ? parsed : entity.to_s
               end

    out = begin
      Cortex::Properties.run_property(entity_type: entity_type, property: property,
                                      receiver: receiver, arguments: arguments || {},
                                      update: update, timeout: timeout,
                                      entity_options: entity_options, agent: agent)
    rescue Cortex::EntityPropertyTimeout
      raise ScoutException, $!.message
    end

    # Receipts are plain Hashes; strip the transient :step key so the JSON
    # payload is exactly the §2.7 envelope (+ §2.6 error envelopes inside).
    strip = ->(r) { r.reject { |k, _| k == :step } }
    Array === out ? out.collect { |r| strip.call(r) } : strip.call(out)
  end

  # ------------------------------------------------------------------
  # Resolution (design §2.4): the Step triple as one addressable object.
  # ------------------------------------------------------------------

  input :address, :string, 'Address of a materialized result: <Type>/<property>/<label> short_path, a var/jobs-prefixed path, or a full filesystem path', nil, required: true, jobname: true
  input :projection, :select, 'What to return of the SAME resolved Step: value (bounded payload), info (full .info sidecar), or path (the PATH STRING, not the bytes)', 'value', select_options: %w(value info path)
  input :max_bytes, :integer, 'Bounding for the value projection', 5000
  task :cortex_result => :json do |address, projection, max_bytes|
    resolution = begin
      Cortex::Properties.resolve_address(address)
    rescue ParameterException => e
      # The §2.6 envelope is embedded in the message as JSON; re-raise as a
      # ScoutException so the task error text IS the envelope.
      raise ScoutException, e.message
    end
    step = resolution[:step]
    raise ScoutException, "Address #{address.inspect} did not resolve to a Step" if step.nil?

    kind = begin
      info = step.info
      (step.respond_to?(:type) && step.type ? step.type : info[:type]).to_s
    rescue StandardError
      ''
    end

    base = { address: resolution[:address], recovered: resolution[:recovered] }
    base[:recovered_from] = resolution[:recovered_from] if resolution[:recovered]

    case projection.to_s
    when 'value'
      status = begin step.status rescue nil end
      begin
        value = step.load
      rescue StandardError => e
        raise ScoutException,
              JSON.generate(Cortex::Error.envelope(e, context: { phase: 'value_load',
                                                                 address: address }))
      end
      value = begin
        JSON.parse(JSON.generate(value))
      rescue StandardError
        value.to_s
      end
      if String === value && value.bytesize > max_bytes
        value = value.byteslice(0, max_bytes) +
                "...[truncated #{value.bytesize - max_bytes} bytes]"
      end
      base.merge(status: status.to_s, result_kind: kind, value: value)
    when 'info'
      info = step.info
      json_safe = info.each_with_object({}) do |(k, v), h|
        h[k.to_s] = case v
                    when Symbol, String, Numeric, TrueClass, FalseClass, NilClass then v.to_s
                    when Array, Hash then JSON.parse(JSON.generate(v))
                    else v.to_s
                    end
      end
      base.merge(status: (begin step.status rescue nil end).to_s, info: json_safe)
    when 'path'
      path = step.path.to_s
      base.merge(path: path,
                 exists: File.exist?(path),
                 bytes: File.exist?(path) ? File.size(path) : nil,
                 result_kind: kind)
    else
      raise ScoutException, "Unknown projection #{projection.inspect}"
    end
  end

end
