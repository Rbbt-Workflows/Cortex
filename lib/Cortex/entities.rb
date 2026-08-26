require 'scout'
require 'scout/workflow/entity'
require 'json'
require 'digest/sha2'

# ==========================================================================
# Cortex-managed executable Entities: engine
# ==========================================================================
#
# Entity properties become first-class versioned Cortex resources.  The Ruby
# bodies live under var/cortex/entities/<Type>/<property>.rb, their metadata
# (schema v1) under var/cortex/entities/.meta/<Type>/<property>.json, and
# history snapshots under var/cortex/entities/.history/<Type>/<property>/.
#
# Everything in this file is a pure module function on Cortex; no Workflow
# task is declared here.  This file must not require workflow.rb.
#
# Probe-driven decisions baked into the code (see research/notes-preflight.md
# and research/probe-property-task-findings.md):
#
#  * Fresh anonymous module generations.  Persist.memory memoizes Task
#    objects per (module, task) pair, so redefining a same-named task in a
#    live module keeps running the OLD body.  We therefore never redefine in
#    place: each manifest digest compiles into a brand new anonymous module
#    and the registry re-points.
#
#  * Explicit dep blocks.  A bare `dep :name` does not forward identity
#    inputs and does not produce a usable Step dependency.  We always install
#    `mod.dep(:name) { |jobname, options| mod.job(:name, options[mod.entity_name], options) }`.
#
#  * Forwarding wrappers.  EntityWorkflow#property_task defines the public
#    property as `def name(*args); job = <name>_job; ...` -- args are dropped
#    (scout-gear 10.12.2).  We redefine it ourselves after property_task.
#
module Cortex
  ENTITIES_NAMESPACE       = :entities
  ENTITY_META_SCHEMA       = 1
  ENTITY_TYPE_RE           = /\A[A-Z][A-Za-z0-9]*(::[A-Z][A-Za-z0-9]*)*\z/
  ENTITY_NAME_RE           = /\A[a-z][a-z0-9_]*\z/
  ENTITY_RESERVED_PROPERTY = %w(job entity entity_list inputs step dependencies
                                task_alias property setup properties
                                all_properties id format).freeze
  ENTITY_RESERVED_ARGUMENT = %w(entity list jobname task _cortex_definition
                                _cortex_definition_version _cortex_definition_digest).freeze
  ENTITY_PROPERTY_TYPES    = %w(single array both).freeze
  ENTITY_HISTORY_DIGITS    = 6

  class << self
    # ------------------------------------------------------------------
    # Name validation (stricter than sanitize_resource_name!)
    # ------------------------------------------------------------------

    # Entity types are Ruby constant paths so the compiled module name is a
    # valid constant name and job paths stay clean.
    def entity_type!(type)
      type = type.to_s
      raise ScoutException,
            "Invalid entity type #{type.inspect}: expected Ruby constant " \
            "segments like 'Gene' or 'Project::Treatment' " \
            "(#{ENTITY_TYPE_RE.inspect})" unless type =~ ENTITY_TYPE_RE
      type
    end

    def entity_property_name!(name)
      name = name.to_s
      raise ScoutException,
            "Invalid property name #{name.inspect}: expected snake_case " \
            "identifier matching #{ENTITY_NAME_RE.inspect}" unless name =~ ENTITY_NAME_RE

      raise ScoutException,
            "Reserved property name #{name.inspect}: collides with an " \
            "EntityWorkflow/Task method. Existing entity methods would break; " \
            "rename the property" if ENTITY_RESERVED_PROPERTY.include?(name) ||
                                     name =~ /\A_cortex_/ ||
                                     name.end_with?('_job')

      raise ScoutException,
            "Reserved argument name #{name.inspect}: reserved for the " \
            "EntityWorkflow envelope" if ENTITY_RESERVED_ARGUMENT.include?(name)
      name
    end

    def entity_argument_name!(name)
      name = name.to_s
      raise ScoutException,
            "Invalid argument name #{name.inspect}: expected snake_case " \
            "identifier matching #{ENTITY_NAME_RE.inspect}" unless name =~ ENTITY_NAME_RE
      raise ScoutException,
            "Reserved argument name #{name.inspect}: reserved for the " \
            "EntityWorkflow envelope" if ENTITY_RESERVED_ARGUMENT.include?(name)
      raise ScoutException,
            "Argument name #{name.inspect} is reserved for the hidden " \
            "definition-identity inputs" if name =~ /\A_cortex_/
      name
    end

    def entity_dependency_name!(name)
      name = name.to_s
      raise ScoutException,
            "Invalid dependency name #{name.inspect}: expected snake_case " \
            "identifier matching #{ENTITY_NAME_RE.inspect}" unless name =~ ENTITY_NAME_RE
      name
    end


    # ------------------------------------------------------------------
    # Path maps.  These mirror workflow.rb exactly; when workflow.rb is
    # loaded afterwards its definitions take precedence (same semantics).
    # They are duplicated here so the file is usable standalone (no workflow
    # task declarations, no require of workflow.rb).
    # ------------------------------------------------------------------

    # Delegated to Cortex.path_maps so the entity engine follows the same
    # anchor/yaml configuration as the rest of the workflow (historical
    # duplicates kept Config-cached defaults that ignored a later anchor
    # change and never consulted the yaml maps).
    def write_map
      Cortex.configured_write_map
    end

    def read_maps
      Cortex.configured_read_maps
    end

    def map_tag(map, maps = nil)
      maps ||= read_maps
      maps.length > 1 ? %q{:} + map.to_s : %q{}
    end
    # ------------------------------------------------------------------
    # Storage paths (relative to each path map root)
    # ------------------------------------------------------------------

    # Frozen absolute var root.  `Scout.var` is the RELATIVE path "var" and
    # task bodies run with CWD = the installed workflow directory
    # (~/.rbbt/workflows/Cortex, a hardlink of this repo's workflow.rb), so a
    # relative root would put entity storage in a different physical place for
    # engine calls made from the repo CWD than for task bodies -- definitions
    # would be written in one place and read from another.  Anchoring to the
    # repository that ships this engine makes both contexts share storage.
    def entity_root
      @entity_root ||= begin
        repo = File.expand_path('../..', __dir__)
        raw  = Scout.var.to_s
        raw  = File.expand_path(raw, repo) unless raw.start_with?('/')
        Path.setup raw
      end
    end

    def entities_dir(map = nil)
      # Entity definitions are always concrete files (the compiler reads them
      # with File.read for backtrace-correct module_eval), never step archives
      # or symlinks, so use the plain (non-follow) map root. Falls back to a
      # direct path under Scout.var when workflow.rb is not loaded (pure-lib
      # usage and smoke tests).
      # `Scout.var` is the RELATIVE path "var".  Task bodies executed through
      # the Step machinery run with CWD = the *installed* workflow directory
      # (~/.rbbt/workflows/Cortex, a hardlink of this repo's workflow.rb), so a
      # relative var would resolve entity storage to a different physical root
      # than engine-level calls made from the repo CWD -- definitions would be
      # written in one place and read from another.  Freeze the var root once,
      # anchored to the repository that ships this engine, so both contexts see
      # the same storage.
      dir = entity_root.cortex[ENTITIES_NAMESPACE.to_s].find(map || :current)
      Path === dir ? dir.to_s : dir
    end

    def entity_body_path(type, property, map = nil)
      File.join(entities_dir(map), type, "#{property}.rb")
    end

    def entity_meta_path(type, property, map = nil)
      File.join(entities_dir(map), '.meta', type, "#{property}.json")
    end

    def entity_history_dir(type, property, map = nil)
      File.join(entities_dir(map), '.history', type, property)
    end

    # ------------------------------------------------------------------
    # Definition digest and canonical metadata
    # ------------------------------------------------------------------

    # Description is intentionally excluded: documentation edits must not
    # invalidate job caches.
    def entity_definition_digest(body:, property_type:, result_type:, arguments:, dependencies:)
      payload = {
        body:          body,
        property_type: property_type,
        result_type:   result_type,
        arguments:     arguments,
        dependencies:  dependencies
      }
      Digest::SHA256.hexdigest JSON.fast_generate(payload)
    end

    def entity_property_type!(property_type)
      case property_type.to_s
      when 'single', 'single2array' then 'single'
      when 'array', 'array2single'  then 'array'
      when 'both'                   then 'both'
      else
        raise ScoutException,
              "Unknown property_type #{property_type.inspect}: expected one " \
              "of #{ENTITY_PROPERTY_TYPES * ', '} (single2array/array2single " \
              "are accepted as aliases)"
      end
    end

    def entity_result_type!(result_type)
      result_type = result_type.to_s
      raise ScoutException,
            "Invalid result_type #{result_type.inspect}: expected a Scout " \
            "input type name (e.g. :string, :integer, :array, :json, :tsv)" if result_type.empty?
      result_type
    end

    # Normalize a Scout input type reference to a symbol (the form
    # Workflow#input / property_task expect).
    def entity_type_sym(type)
      type.to_s.to_sym
    end

    # Normalize an argument spec into the canonical hash form.
    def entity_argument!(arg)
      case arg
      when Hash
        arg = IndiferentHash.setup(arg.dup) if defined?(IndiferentHash)
        name = entity_argument_name!((arg[:name] || arg['name']).to_s)
        type = (arg[:type] || arg['type'] || 'string').to_s
        desc = (arg[:description] || arg['description'] || "Argument #{name}").to_s
        required = !!arg[:required]
        default = arg.key?(:default) ? arg[:default] : arg['default']
        { name: name, type: type, description: desc, required: required }
          .tap { |h| h[:default] = default unless default.nil? }
      when Symbol, String
        name = entity_argument_name! arg
        { name: name, type: 'string', description: "Argument #{name}", required: false }
      else
        raise ScoutException,
              "Invalid argument spec #{arg.inspect}: expected {name:,type:," \
              "description:,required:,default:} or a bare Symbol/String name"
      end
    end

    def entity_arguments!(arguments)
      raise ScoutException, 'arguments must be an Array' unless Array === arguments
      list = arguments.collect { |a| entity_argument! a }
      seen = {}
      list.each do |a|
        raise ScoutException,
              "Duplicate argument name #{a[:name].inspect}: each argument " \
              "must be declared once" if seen[a[:name]]
        seen[a[:name]] = true
      end
      list
    end

    def entity_dependencies!(dependencies)
      raise ScoutException, 'dependencies must be an Array' unless Array === dependencies
      dependencies.collect { |d| entity_dependency_name! d }
    end

    # ------------------------------------------------------------------
    # Metadata (schema v1)
    # ------------------------------------------------------------------

    def entity_meta_write!(type, property, meta)
      path = entity_meta_path(type, property, write_map)
      dir  = File.dirname path
      FileUtils.mkdir_p dir unless File.directory? dir
      # force: true is REQUIRED: Open.sensible_write silently drops the write
      # when the target already exists, and every lifecycle action after the
      # initial `define` overwrites an existing meta file.
      Open.sensible_write(path, JSON.pretty_generate(meta), force: true)
      path
    end

    def entity_meta_read(path)
      JSON.parse(Open.read(path))
    rescue StandardError
      raise ScoutException, "Corrupt entity metadata #{path}: not valid JSON"
    end

    def entity_validate_meta!(meta, type = nil, property = nil)
      raise ScoutException, 'Entity metadata must be a Hash' unless Hash === meta
      schema = meta['schema'].to_i
      raise ScoutException,
            "Unsupported entity metadata schema #{meta['schema'].inspect} " \
            "(this build understands schema 1): #{meta['entity_type'] rescue '?'}/#{meta['property'] rescue '?'}" if schema != ENTITY_META_SCHEMA

      type = (type || meta['entity_type']).to_s
      property = (property || meta['property']).to_s
      entity_type! type
      entity_property_name! property

      raise ScoutException,
            "Entity metadata #{type}/#{property} is corrupted: entity_type " \
            "mismatch (#{meta['entity_type'].inspect})" if meta['entity_type'] != type
      raise ScoutException,
            "Entity metadata #{type}/#{property} is corrupted: property " \
            "mismatch (#{meta['property'].inspect})" if meta['property'] != property

      %w(property_type result_type version active versions).each do |key|
        raise ScoutException,
              "Entity metadata #{type}/#{property} is corrupted: missing " \
              "field #{key.inspect}" if meta[key].nil?
      end

      entity_property_type! meta['property_type']
      entity_result_type!  meta['result_type']
      meta
    end

    # ------------------------------------------------------------------
    # Cross-map resolution.  Unlike content reads (first match wins),
    # executable definitions with two physical sources are a HARD ERROR: the
    # same code would compute differently depending on the map order, and
    # both bodies would be cached under overlapping job paths.
    # ------------------------------------------------------------------

    def entity_sources(type, property)
      read_maps
        .map { |map| entity_meta_path(type, property, map) }
        .select { |p| File.exist? p }
        .map { |p| [p, entity_meta_read(p)] }
        # The same physical file can be reached through more than one map tag
        # (e.g. when :current and :lib resolve to the same directory); those
        # are NOT ambiguity -- only distinct physical copies are.
        .uniq { |path, _meta| File.realpath(path) rescue path }
    end

    def entity_resolve!(type, property)
      sources = entity_sources type, property
      if sources.length > 1
        list = sources.collect { |p, _| p }
        raise ScoutException,
              "Ambiguous entity property #{type}/#{property}: found in " \
              "#{sources.length} path maps (#{list * ', '}). Two copies of " \
              "executable code with the same address are not allowed. Remove " \
              "one (Cortex.update_property / Cortex.remove_property, then " \
              "redefine in the intended map)."
      end
      sources.first
    end

    # ------------------------------------------------------------------
    # Reading definitions
    # ------------------------------------------------------------------

    def property_definition(entity_type, property)
      entity_type! entity_type.to_s
      entity_property_name! property.to_s
      source = entity_resolve! entity_type, property
      return nil unless source

      path, meta = source
      entity_validate_meta! meta, entity_type, property
      # Locate the map the meta came from so the body path is derived from
      # the same map root (meta lives under <root>/entities/.meta/<T>/<p>.json).
      map = read_maps.find { |m| path == entity_meta_path(entity_type, property, m) }
      body_path = entity_body_path entity_type, property, map
      body = File.read(body_path) if File.exist? body_path

      meta.merge('body' => body, 'body_path' => body_path, 'meta_path' => path)
    end

    def property_definitions(type = nil, prefix = nil, active: true)
      type = type.to_s unless type.nil?
      prefix = prefix.to_s unless prefix.nil?
      out = []
      seen = {}
      entity_meta_files.each do |meta_path, map|
        meta = entity_meta_read meta_path
        next unless meta['entity_type'] == type unless type.nil?
        next unless prefix.nil? || "#{meta['entity_type']}/#{meta['property']}".start_with?(prefix)
        next if active && !meta['active']
        # The same physical file can be reached through several path maps when
        # several maps resolve to the same directory (the default :lib and
        # :current both point at <repo>/var when the workflow is a checkout,
        # not an installed copy).  Deduplicate by path so each definition is
        # reported exactly once; genuine cross-map duplicates are still a hard
        # error, but only where it matters -- resolution (entity_resolve!).
        next if seen[meta_path]
        seen[meta_path] = true
        out << { entity_type: meta['entity_type'], type: meta['entity_type'],
                 property: meta['property'],
                 meta: meta, meta_path: meta_path,
                 body_path: meta_path.sub(%r{/\.meta/}, '/').sub(%r{\.json\z}, '.rb'),
                 map: map_tag(map) }
      end
      out.sort_by { |d| [d[:entity_type], d[:property]] }
    end

    # All (meta_path, map) pairs across readable maps; .meta/<Type>/<prop>.json.
    # Distinct maps that resolve to the SAME directory yield the same physical
    # files repeatedly; deduplicate by real path and report the FIRST map that
    # provides it (map order = read order).
    def entity_meta_files
      read_maps.flat_map do |map|
        dir = File.join(entities_dir(map), '.meta')
        next [] unless File.directory? dir
        Dir.glob(File.join(dir, '**', '*.json')).sort.collect { |p| [p, map] }
      end
            .group_by { |path, _map| File.exist?(path) ? File.realpath(path) : path }
            .values
            .collect(&:first)
    end

    # ------------------------------------------------------------------
    # Manifests: active definitions of one entity type (per type, per read map)
    # ------------------------------------------------------------------

    # => [{type:, property:, meta:, body:, body_path:, map:}]
    def entity_manifest(type)
      entity_type! type
      out = []
      seen = {}
      entity_meta_files.each do |meta_path, map|
        meta = entity_meta_read meta_path
        next unless meta['entity_type'] == type
        next unless meta['active']
        # Executable definitions must be unambiguous across maps: resolving
        # here (rather than just trusting the first hit) turns a duplicated
        # <Type>/<prop>.rb into a hard error instead of silently picking a
        # copy of the code to run.
        canonical, _canonical_meta = entity_resolve! type, meta['property']
        next if seen[meta['property']]
        next unless canonical == meta_path
        seen[meta['property']] = true

        entity_validate_meta! meta, type, meta['property']
        body_path = entity_body_path type, meta['property'], map
        body = File.read(body_path) if File.exist? body_path
        raise ScoutException,
              "Entity property #{type}/#{meta['property']} is active but its " \
              "body file is missing: #{body_path}" if body.nil?
        out << { type: type, property: meta['property'], meta: meta, body: body,
                 body_path: body_path, map: map }
      end
      out.sort_by { |d| d[:property] }
    end

    # ------------------------------------------------------------------
    # Compiler
    # ------------------------------------------------------------------

    def entity_new_module(type)
      mod = Module.new
      mod.extend EntityWorkflow
      mod.name = entity_type! type
      mod.entity_name = Misc.snake_case(type).downcase
      mod
    end

    # Compile a single property into +mod+.  The body is evaluated against
    # the definition file so syntax errors and backtraces cite it.
    def entity_compile_property!(mod, defn, identities = {})
      type     = defn[:type]
      property = defn[:property]
      meta     = defn[:meta]
      body     = defn[:body]
      path     = defn[:body_path]

      # --- declared arguments (must precede the hidden inputs) --------
      normalize_argument_hashes(meta['arguments']).each do |arg|
        options = {}
        options[:required] = true if arg['required'] && arg['default'].nil?
        # `required: true` without a default is the common case; pass a
        # default only when one was declared so Scout keeps the input
        # genuinely optional/required as specified.
        mod.input arg['name'].to_sym, entity_type_sym(arg['type'] || 'string'),
                  arg['description'].to_s, arg['default'], options
      end

      # --- hidden identity inputs -------------------------------------
      # These participate in cache identity: a new definition version or
      # digest yields different job paths even when all visible inputs are
      # unchanged.  Declared AFTER the author arguments: Step bodies receive
      # task inputs positionally in declaration order, so the author's Proc
      # parameters must bind the first N inputs or they would receive the
      # _cortex_definition string instead of their own values.
      # NO defaults here: a default equal to the active value never reaches
      # non_default_inputs, so the job hash (which does cover the whole input
      # array) would not be computed and a definition change would reuse the
      # old clean path.  Default-less + always provided = every job path is
      # keyed by its definition identity.
      mod.input :_cortex_definition, :string,
                'Active definition identity (engine-managed; keys job cache identity)'
      mod.input :_cortex_definition_version, :integer,
                'Active definition version (engine-managed; keys job cache identity)'
      mod.input :_cortex_definition_digest, :string,
                'Active definition digest (engine-managed; keys job cache identity)'

      # --- same-entity dependencies ----------------------------------
      # A bare `dep :name` creates no usable Step dependency and drops
      # identity inputs; forward everything explicitly.  Must be declared
      # BEFORE the property_task that consumes it.
      Array(meta['dependencies']).each do |dep|
        mod.dep(dep.to_sym) do |jobname, options|
          # `tasks` is a plain Hash keyed by Symbol, so the dep name must be
          # a Symbol here or Workflow#job raises TaskNotFound.
          # Forward only the arguments the dependency understands: a dep job
          # rejects unknown inputs, and the caller may carry arguments that
          # belong to this property (or to a sibling dependency) instead.
          dep_args = options.slice(*entity_declared_arguments(mod, dep.to_sym))
          # Overwrite the parent's identity inputs with the DEPENDENCY's own:
          # `options` carries this property's identity (forwarded by its
          # wrapper), and the dep job must be keyed by ITS active definition.
          dep_args = dep_args.merge(identities[dep.to_sym] || {})
          # Strip the caller's identity inputs and re-pin the dependency's:
          # `options` carries the CALLER's definition identity (merged by its
          # wrapper), and the dep job must be keyed by the dependency's own
          # active definition so updating the dependency invalidates it.
          clean = options.reject { |k, _| k.to_s.start_with?('_cortex_') }
          mod.job(dep.to_sym,
                  options[mod.entity_name] || options[:jobname] || jobname,
                  clean.merge(dep_args))
        end
      end

      # --- property task ---------------------------------------------
      # The author body's bare locals (argument names, `entity`) resolve
      arg_names = normalize_argument_hashes(meta['arguments']).collect { |a| a['name'] }
      # because the eval'd Proc declares the argument list as positional
      # parameters, and `entity` is a method on the Step's exec context.
      # property_task then wraps this proc so :single/:array/:both behave
      # exactly like hand-written Entity properties.
      body_proc = entity_body_proc(body, arg_names, path)
      mod.property_task({ property.to_sym => entity_type_sym(meta['result_type']) },
                        meta['property_type'].to_sym, &body_proc)

      # --- forwarding wrapper ----------------------------------------
      # property_task's public property drops *args (scout-gear 10.12.2);
      # install our own wrapper after it.
      # Identity of THIS definition: the wrapper passes it as explicit kwargs
      # so the job hash is pinned to it (see install_property_wrapper).
      identity = { _cortex_definition: "#{type}/#{property}",
                   _cortex_definition_version: meta['version'].to_i,
                   _cortex_definition_digest: meta['digest'] }
      install_property_wrapper(mod, property, meta['property_type'], identity)

      mod
    end

    # Argument names declared by a property that was just compiled into `mod`.
    # Used by the dep forwarder to send only the arguments the dependency
    # understands (a dep job rejects unknown required/optional inputs).
    def entity_declared_arguments(mod, property)
      task = mod.tasks[property.to_sym]
      return [] unless task
      Array(task.inputs)
        .collect { |i| i.is_a?(Array) ? i.first.to_s : i.to_s }
        .reject { |n| n.start_with?(%q{_cortex_}) }
    rescue StandardError
      []
    end

    # Redefine the public property method so it forwards *args/**kwargs to
    # <property>_job (fixing the upstream argument-dropping bug) and loads
    # the finished Step.
    # Scout Step#exec runs the task block with `instance_exec(*inputs)`, i.e.
    # the declared inputs arrive as POSITIONAL block parameters.  Author
    # bodies are written in the natural Entity style (`treatment` as a bare
    # local).  We therefore eval the author body into a Proc whose parameter
    # list is exactly the declared argument names (in declaration order),
    # evaluated at the definition file so syntax errors point at the .rb.
    def entity_body_proc(body, argument_names, path)
      params = (argument_names.collect { |n| n.to_s } +
                %w(_cortex_definition _cortex_definition_version _cortex_definition_digest entity)).join(', ')
      # The three hidden identity inputs are declared as ordinary inputs on
      # the task (with the ACTIVE definition's values as defaults), so they
      # reach the job normally and participate in cache identity.  The body
      # therefore also declares them as trailing parameters; it simply
      # ignores them.
      # DEFECT-2: a bare Proc's `return` raises LocalJumpError once the
      # defining method has returned (Step#exec calls the body later, from
      # inside the job).  Wrap the author body in an inner lambda: `return`
      # then returns from the lambda, which is the natural author intent.
      # The outer Proc keeps splat arity so partial-input call paths behave
      # exactly as before, and the lambda unpacks positionally, preserving
      # the DEFECT-1 named-binding contract declared above.
      source = "Proc.new do |*__cortex_inputs__|\n" \
               "  __cortex_body__ = lambda do |*__cortex_args__|\n" \
               "    #{params} = __cortex_args__\n" \
               "#{body}\n" \
               "  end\n" \
               "  __cortex_body__.call(*__cortex_inputs__)\n" \
               "end"
      begin
        eval(source, binding, path, 1)
      rescue SyntaxError => e
        raise ScoutException,
              "Syntax error in entity property body #{path}: #{e.message}. " \
              'Fix the body and update the property again.'
      end
    end

    def install_property_wrapper(mod, property, property_type, identity = {})
      job_method = "#{property}_job".to_sym
      property   = property.to_sym
      # :array (and :both) properties get an upstream "_ary_<prop>" method that
      # runs the LIST job (property_task registers it for non-:single types).
      # Prefer it over the plain <prop>_job call: for a scalar receiver the
      # upstream machinery re-invokes it through make_array, which is what the
      # annotator needs to select the member for this entity.  A scalar
      # receiver calling <prop>_job directly yields a Step whose result is the
      # vectorized list, and Entity#[] then fails with NoMethodError (critic
      # finding); list receivers work either way, so use the ary form for both.
      ary_method = property_type == 'single' ? nil : Entity::Property.array_method(property)
      scalar     = property_type == 'array'

      mod.module_eval do
        define_method(property) do |*args, **kwargs, &blk|
          # Provide the identity inputs EXPLICITLY.  A task default that is
          # never provided does not reach non_default_inputs, so it cannot key
          # the job hash and a definition change would silently reuse the old
          # job.  Explicit kwargs pin the job to the definition this module
          # generation was compiled from (given values win over the active
          # defaults in case a caller overrides).
          kwargs = kwargs.merge(identity) { |_k, given, _active| given }
          if ary_method
            # The upstream `_ary_<prop>` method is defined by Entity#property
            # with the BODY block and runs the underlying task.  A scalar
            # receiver is not "contained", so calling `_ary_<prop>` on `self`
            # (or on make_array, which the annotator re-enters through
            # Entity#[]) crashes on member selection (res[self] on a Step).
            # Instead: run the vector job once on a one-element container and
            # select the member ourselves -- mirroring upstream semantics
            # without relying on its broken scalar path.
            container = Array === self ? self : make_array
            job = container.send(job_method, *args, **kwargs)
            job.run unless job.done?
            res = job.load
            res = res[0] if Array === res && !(Array === self)
          else
            job = send(job_method, *args, **kwargs)
            job.run unless job.done?
            res = job.load
          end
          # :array properties on a SCALAR receiver follow upstream Entity
          # 'array_method' semantics: the receiver is promoted to a
          # one-element array (make_array) and the member for this entity is
          # selected from the vectorized result.  NOTE the guard must be
          # `scalar && !(Array === self)`: `!Array === self` binds as
          # `(!Array) === self` and is ALWAYS false, which silently skipped
          # this branch (critic finding).  make_array re-runs the job method
          # on the container; the earlier scalar run above is reused from
          # cache, so this is not a second computation.
          res
        end
      end
    end

    # Topologically sort properties by their same-entity dependencies.
    def entity_topo_sort(definitions)
      definitions = definitions.collect do |d|
        d = { type: d[:type] || d['type'], property: d[:property] || d['property'],
              meta: d[:meta] || d['meta'] } unless d.key?(:property)
        d
      end
      by_name = {}
      definitions.each { |d| by_name[d[:property]] = d }
      definitions.each do |d|
        meta = d[:meta] || {}
        deps = meta['dependencies'] || meta[:dependencies]
        Array(deps).each do |dep|
          raise ScoutException,
                "Entity property #{d[:type]}/#{d[:property]} depends on " \
                "#{dep.inspect}, which is not an active property of the same " \
                "type. Active: #{by_name.keys.sort * ', '}. Define " \
                "#{type_label(d[:type])}/#{dep} first or drop the dependency." unless by_name.key? dep
        end
      end

      state = {}
      order = []
      visit = lambda do |name|
        case state[name]
        when :visiting
          raise ScoutException, "Dependency cycle in entity type #{d_for(by_name, name)[:type]}: #{(order + [name]).uniq * ' -> '}"
        when :done then next
        end
        state[name] = :visiting
        m = by_name[name][:meta] || {}
        Array(m['dependencies'] || m[:dependencies]).each { |dep| visit.call dep }
        state[name] = :done
        order << name
      end
      by_name.keys.each { |name| visit.call name }
      order.collect { |name| by_name[name] }
    end

    def d_for(by_name, name)
      d = by_name[name]
      return { type: '?', property: name } unless d
      { type: d[:type] || (d[:meta] || {})['entity_type'], property: d[:property] }
    end

    def type_label(type)
      type
    end

    # Digest of the full manifest (property -> definition digest) so a new
    # generation is compiled only when something actually changed.
    def entity_manifest_digest(definitions)
      Digest::SHA256.hexdigest JSON.fast_generate(
        definitions.collect { |d| [d[:property], d[:meta]['digest']] }.sort
      )
    end

    # ------------------------------------------------------------------
    # Module registry / generation management
    # ------------------------------------------------------------------

    # => { 'Gene' => { digest: => module } }
    def managed_entity_registry
      @managed_entity_registry ||= {}
    end

    # Process-level ownership record: which (type, property) pairs this
    # process compiled.  Used by the collision check so a name that already
    # exists on the module is only accepted when we installed it.
    def managed_entity_ownership
      @managed_entity_ownership ||= []
    end

    def cortex_owned?(type, property)
      managed_entity_ownership.include? [type, property]
    end

    def entity_modules(type)
      managed_entity_registry[entity_type! type] ||= {}
    end

    # Resolve an entity type to a module:
    #   a) an existing constant that is an Entity module -> reuse (after a
    #      compatibility check), extending with EntityWorkflow when needed;
    #   b) an existing constant that is NOT an Entity module -> hard error;
    #   c) no constant -> a managed anonymous module.
    def resolve_entity_module(type)
      entity_type! type
      candidate = nil

      # Kernel-level constant wins: a plain module/class named +type+ is NOT
      # an Entity module and must never be shadowed or extended (it would
      # gain Entity methods and leak unrelated constant semantics into job
      # paths).  This is the design's rule (b) and the reason unrelated
      # constants with entity-ish names are rejected.
      candidate = Kernel.const_get type if RUBY_VERSION >= '3.0' &&
                                          type.split('::').all? { |seg| /^[A-Z]/ =~ seg } &&
                                          (Kernel.const_defined? type rescue false)
      candidate ||= Cortex.const_get type if Cortex.const_defined? type

      return entity_new_module type if candidate.nil?

      raise ScoutException,
            "Constant #{type} already exists and is not an Entity module " \
            "(#{candidate.class}); managed entity types cannot shadow or " \
            "extend it. Pick another type name." unless entity_module?(candidate)

      # Reuse is only sound when the engine can recompile that module.  Scout
      # memoizes Task objects per module+name (Persist.memory), so a property
      # re-declared on an EXISTING module keeps running the first body forever
      # (probe: second body returned the first result at the same path).
      # Fresh anonymous generations are the only reliable envelope; tell the
      # caller instead of silently serving stale code.
      root_const = (Kernel.const_get(type) rescue nil)
      if entity_modules(type)['managed'].nil? && candidate.equal?(root_const)
        raise ScoutException,
              "Entity module #{type} already exists as a pre-existing " \
              'constant. Cortex cannot adopt foreign Entity modules (their ' \
              'task bodies are memoized and cannot be recompiled reliably). ' \
              'Rename the Cortex entity type or remove the constant.'
      end

      candidate.extend EntityWorkflow unless entity_module?(candidate, :workflow)
      candidate
    end

    # +kind+ :entity (extends Entity) or :workflow (extends EntityWorkflow)
    def entity_module?(mod, kind = :entity)
      return false unless Module === mod
      case kind
      when :entity   then mod.singleton_class.include?(Entity) || mod.is_a?(Entity)
      when :workflow then mod.singleton_class.include?(EntityWorkflow)
      end
    end

    def managed_entity_module(type)
      entity_modules(type)['managed']
    end

    # ------------------------------------------------------------------
    # Loading a type (compiler entry point)
    # ------------------------------------------------------------------

    def load_entity_type(type)
      entity_type! type
      definitions = entity_manifest type
      digest      = entity_manifest_digest definitions

      if definitions.empty?
        managed_entity_registry.delete type
        return nil
      end

      registry = entity_modules type
      existing = registry[digest]
      return existing if existing

      # Fresh generation: redefining same-named tasks in a live module is
      # unreliable (Persist.memory memoizes Task objects), so each manifest
      # digest gets its own anonymous module and the registry re-points.
      mod = entity_new_module type
      ordered = entity_topo_sort(definitions)
      # A property's identity inputs (definition/version/digest) must be
      # known BEFORE its dependents compile: the dep block pins the
      # dependency's identity into the dependent's job hash so updating the
      # dependency invalidates every dependent.
      identities = {}
      ordered.each do |defn|
        meta = defn[:meta] || {}
        identities[defn[:property].to_sym] = {
          _cortex_definition: type + '/' + defn[:property],
          _cortex_definition_version: meta['version'].to_i,
          _cortex_definition_digest: meta['digest']
        }
      end
      ordered.each do |defn|
        entity_collision_check! mod, type, defn[:property]
        entity_compile_property! mod, defn, identities
        managed_entity_ownership << [type, defn[:property]]
        managed_entity_ownership.uniq!
      end
      registry[digest] = mod
      registry['managed'] = mod
      mod
    end

    def entity_collision_check!(mod, type, property)
      return if cortex_owned?(type, property)

      existing_tasks = (mod.tasks.keys rescue []).collect(&:to_s)
      existing_props = (mod.properties.keys rescue []).collect(&:to_s)
      # An instance method installed by anything else (a foreign define_method)
      # also occupies the name: our forwarding wrapper would silently replace
      # it, so treat it as a collision.
      foreign = mod.instance_methods(false).collect(&:to_s)
      taken = (existing_tasks + existing_props +
               [property, "#{property}_job"]).uniq
      raise ScoutException,
            "Property name collision on entity type #{type}: #{property} " \
            "already exists (#{(existing_tasks + existing_props).uniq.sort * ', '}). " \
            "Rename the property or remove the conflicting definition." if (existing_tasks + existing_props + foreign).include? property

      raise ScoutException,
            "Property name collision on entity type #{type}: #{property} " \
            "already exists on the module as an instance method. " \
            'Rename the property.' if foreign.include? property

      raise ScoutException,
            "Property name collision on entity type #{type}: #{property} " \
            "already exists on the module as #{property}_job" if taken.include? "#{property}_job" && !existing_props.empty?
    end

    # ------------------------------------------------------------------
    # Staging (define/update pre-flight)
    # ------------------------------------------------------------------

    # Compile a candidate into a throwaway module with the exact same
    # envelope the real compiler uses, so syntax/compile errors surface
    # before anything is written to disk.
    def entity_stage_compile(type, property, body:, property_type:, result_type:,
                             arguments:, dependencies:, version:, digest:)
      mod = entity_new_module type
      defn = {
        type: type, property: property, body: body, body_path: "staged:#{type}/#{property}.rb",
        meta: {
          'entity_type' => type, 'property' => property,
          'property_type' => property_type, 'result_type' => result_type,
          'arguments' => arguments, 'dependencies' => dependencies,
          'version' => version, 'digest' => digest
        }
      }
      entity_compile_property! mod, defn
      mod
    end

    def entity_provenance(action, agent:, job:)
      { version: nil, digest: nil, action: action, job: job,
        agent: agent, timestamp: Time.now.utc.iso8601 }
    rescue StandardError
      { version: nil, digest: nil, action: action, job: job,
        agent: agent, timestamp: Time.now.to_s }
  end

    # ------------------------------------------------------------------
    # Lifecycle: define
    # ------------------------------------------------------------------

    def define_property(entity_type, property, body:, description:, property_type:,
                        result_type:, arguments:, dependencies:, agent:, job:,
                        test_entity: nil, test_arguments: nil)
      type     = entity_type! entity_type.to_s
      property = entity_property_name! property.to_s

      existing = property_definition type, property
      if existing && existing['active']
        raise ScoutException,
              "Entity property #{type}/#{property} already exists at version " \
              "#{existing['version']} (digest #{existing['digest'][0, 8]}). Use " \
              "Cortex.update_property to change it, or " \
              "Cortex.remove_property to delete it first."
      end

      property_type = entity_property_type! property_type
      result_type   = entity_result_type! result_type
      arguments     = entity_arguments!(arguments)
      dependencies  = entity_dependencies!(dependencies)
      digest        = entity_definition_digest(body: body, property_type: property_type,
                                               result_type: result_type, arguments: arguments,
                                               dependencies: dependencies)

      # If the address exists but is inactive (tombstone), its history must
      # stay intact; the new definition restarts at version 1 per design v1.
      versions = existing && !existing['active'] ? existing['versions'] : []
      versions = [] unless Array === versions

      # Type resolution up front: a pre-existing non-Entity constant with this
      # name (or a foreign Entity module we cannot recompile) must fail at
      # definition time, not silently at load time.
      resolve_entity_module type

      # Graph check first (missing dependency / cycle), then the staging
      # compile; both BEFORE anything is written.
      entity_validate_graph! type, property, dependencies

      entity_stage_compile type, property, body: body, property_type: property_type,
                                          result_type: result_type, arguments: arguments,
                                          dependencies: dependencies, version: 1, digest: digest

      entity_smoke_test! type, property, body: body, property_type: property_type,
                                          result_type: result_type, arguments: arguments,
                                          dependencies: dependencies,
                                          test_entity: test_entity, test_arguments: test_arguments

      # Order matters: body first, meta last.  If the meta write fails the
      # body is orphaned but NOT active (no meta => not resolvable), and the
      # next define_property can safely overwrite it.
      body_path = entity_body_path type, property, write_map
      FileUtils.mkdir_p File.dirname body_path
      Open.sensible_write body_path, body, force: true

      prov = entity_provenance 'define', agent: agent, job: job
      prov.merge! version: 1, digest: digest
      meta = {
        schema: ENTITY_META_SCHEMA, entity_type: type, property: property,
        description: description, property_type: property_type,
        result_type: result_type, arguments: arguments,
        dependencies: dependencies, version: 1, digest: digest,
        active: true, versions: versions + [prov]
      }
      entity_meta_write! type, property, meta

      # The active generation is stale by construction; drop the cache so the
      # next load_entity_type compiles a fresh module.
      entity_modules(type).delete 'managed'
      { address: "#{type}/#{property}", version: 1, digest: digest }
    end

    # Validate the dependency graph as it WOULD be after the candidate becomes
    # active: dependencies must resolve to active same-type properties and the
    # graph must stay acyclic.  Runs before anything is written so a bad
    # definition never lands on disk.
    def entity_validate_graph!(type, property, dependencies)
      deps   = Array(dependencies)
      others = property_definitions(type).reject { |d| d[:property] == property }
      defs   = others + [{ type: type, property: property,
                           meta: { 'dependencies' => deps } }]
      entity_topo_sort defs
      true
    end

    def entity_smoke_test!(type, property, body:, property_type:, result_type:,
                           arguments:, dependencies:, test_entity:, test_arguments:)
      return if test_entity.nil?
      test_arguments ||= {}
      mod = entity_stage_compile type, property, body: body,
                                                property_type: property_type,
                                                result_type: result_type,
                                                arguments: arguments,
                                                dependencies: dependencies,
                                                version: 1, digest: 'smoke'
      entity = mod.setup test_entity
      job    = entity.send "#{property}_job", test_arguments
      job.run
      job.load
    rescue StandardError => e
      backtrace = ENV["CORTEX_VERBOSE_BACKTRACE"].to_s.downcase == "true" ?
                    "\n" + Array(e.backtrace).first(8).join("\n") : ""
      raise ScoutException,
            "Smoke test failed for #{type}/#{property} with entity " \
            "#{test_entity.inspect} (#{e.class}: #{e.message}). The " \
            "definition was not written.#{backtrace}"
   end


    # ------------------------------------------------------------------
    # Lifecycle: update
    # ------------------------------------------------------------------

    def update_property(entity_type, property, expected_version:, body: nil,
                        description: nil, property_type: nil, result_type: nil,
                        arguments: nil, dependencies: nil, agent:, job:,
                        test_entity: nil, test_arguments: nil)
      type     = entity_type! entity_type.to_s
      property = entity_property_name! property.to_s
      current  = property_definition type, property

      raise ScoutException,
            "Entity property #{type}/#{property} does not exist. Use " \
            "Cortex.define_property to create it." if current.nil?
      raise ScoutException,
            "Entity property #{type}/#{property} is inactive (removed at " \
            "version #{current['removed_version'] || 'n/a'}). Redefine it " \
            "with Cortex.define_property." unless current['active']

      unless current['version'].to_i == expected_version.to_i
        raise ScoutException,
              "Version mismatch for #{type}/#{property}: expected " \
              "#{current['version']} but the call supplied " \
              "#{expected_version}. Reload the definition " \
              "(Cortex.property_definition) and retry with the current " \
              "version."
      end

      new_body         = body.nil? ? current['body'] : body
      new_description  = description.nil? ? current['description'] : description
      new_property_type = property_type.nil? ? current['property_type'] : entity_property_type!(property_type)
      new_result_type  = result_type.nil? ? current['result_type'] : entity_result_type!(result_type)
      new_arguments    = arguments.nil? ? current['arguments'] : entity_arguments!(arguments)
      new_dependencies = dependencies.nil? ? current['dependencies'] : entity_dependencies!(dependencies)

      # The metadata stores normalized (symbol-keyed) argument hashes; digest
      # and persistence need stable JSON-shaped strings.
      new_arguments = normalize_argument_hashes new_arguments
      new_digest    = entity_definition_digest(body: new_body,
                                               property_type: new_property_type,
                                               result_type: new_result_type,
                                               arguments: new_arguments,
                                               dependencies: new_dependencies)
      new_version   = current['version'].to_i + 1

      entity_stage_compile type, property, body: new_body,
                                           property_type: new_property_type,
                                           result_type: new_result_type,
                                           arguments: new_arguments,
                                           dependencies: new_dependencies,
                                           version: new_version, digest: new_digest
      entity_validate_graph! type, property, new_dependencies

      entity_smoke_test! type, property, body: new_body,
                                          property_type: new_property_type,
                                          result_type: new_result_type,
                                          arguments: new_arguments,
                                          dependencies: new_dependencies,
                                          test_entity: test_entity,
                                          test_arguments: test_arguments

      # Snapshot the outgoing active definition before replacing it.
      entity_history_snapshot! type, property, current

      body_path = entity_body_path type, property, write_map
      FileUtils.mkdir_p File.dirname body_path
      Open.sensible_write body_path, new_body, force: true

      prov = entity_provenance 'update', agent: agent, job: job
      prov.merge! version: new_version, digest: new_digest
      meta = current.reject { |k, _| %w(body body_path meta_path).include? k }
                    .merge(
                      schema: ENTITY_META_SCHEMA, entity_type: type,
                      property: property, description: new_description,
                      property_type: new_property_type,
                      result_type: new_result_type, arguments: new_arguments,
                      dependencies: new_dependencies, version: new_version,
                      digest: new_digest, active: true,
                      versions: current['versions'] + [prov]
                    )
      entity_meta_write! type, property, meta

      entity_modules(type).delete 'managed'
      { address: "#{type}/#{property}", version: new_version, digest: new_digest }
    end

    # Metadata stores normalized argument hashes; convert symbols to the
    # JSON string-keyed form used by digests and on-disk JSON.
    def normalize_argument_hashes(arguments)
      Array(arguments).collect do |arg|
        out = {}
        %w(name type description required).each do |k|
          v = arg[k] || arg[k.to_sym]
          out[k] = v unless v.nil?
        end
        out['default'] = arg['default'] || arg[:default] unless (arg['default'] || arg[:default]).nil?
        out
      end
    end

    # ------------------------------------------------------------------
    # Lifecycle: remove
    # ------------------------------------------------------------------

    def remove_property(entity_type, property, expected_version:, agent:, job:)
      type     = entity_type! entity_type.to_s
      property = entity_property_name! property.to_s
      current  = property_definition type, property

      raise ScoutException,
            "Entity property #{type}/#{property} does not exist. Available: " \
            "#{property_definitions(type).collect { |d| d[:property] } * ', '}" if current.nil?
      unless current['version'].to_i == expected_version.to_i
        raise ScoutException,
              "Version mismatch for #{type}/#{property}: expected " \
              "#{current['version']} but the call supplied #{expected_version}. " \
              "Reload the definition (Cortex.property_definition) and retry."
      end

      entity_history_snapshot! type, property, current

      prov = entity_provenance 'remove', agent: agent, job: job
      prov.merge! version: current['version'].to_i + 1, digest: current['digest']
      meta = current.reject { |k, _| %w(body body_path meta_path).include? k }
                    .merge(
                      schema: ENTITY_META_SCHEMA, entity_type: type,
                      property: property, active: false, removed: true,
                      removed_version: current['version'].to_i + 1,
                      versions: current['versions'] + [prov]
                    )
      entity_meta_write! type, property, meta

      # Delete the active body: an inactive property must not be resolvable.
      body_path = entity_body_path type, property, write_map
      FileUtils.rm_f body_path

      entity_modules(type).delete 'managed'
      { address: "#{type}/#{property}", removed_version: current['version'].to_i + 1,
        version: current['version'].to_i + 1 }
    end

    # ------------------------------------------------------------------
    # History
    # ------------------------------------------------------------------

    def entity_history_snapshot!(type, property, defn)
      dir = entity_history_dir type, property, write_map
      FileUtils.mkdir_p dir
      # Sequence numbers must never be reused: count existing snapshots of any
      # extension, not just .rb, so a meta-only snapshot still advances the
      # counter.
      num = format("%0#{ENTITY_HISTORY_DIGITS}d",
                   Dir.glob(File.join(dir, '*.*')).length + 1)
      body_path = defn['body_path'] || entity_body_path(type, property, write_map)
      body      = defn['body'] || (File.exist?(body_path) ? File.read(body_path) : nil)
      meta      = defn.reject { |k, _| %w(body body_path meta_path).include? k }
      Open.sensible_write File.join(dir, "#{num}.rb"), body if body
      Open.sensible_write File.join(dir, "#{num}.json"), JSON.pretty_generate(meta)
      [File.join(dir, "#{num}.rb"), File.join(dir, "#{num}.json")]
    end

    def property_history(entity_type, property)
      type     = entity_type! entity_type.to_s
      property = entity_property_name! property.to_s
      dir      = entity_history_dir type, property, write_map
      # .history lives in each readable map; report the write_map's own plus
      # any readable ones (per-type grouping, like entity_meta_files).
      files = read_maps.flat_map do |map|
        d = entity_history_dir type, property, map
        Dir.glob(File.join(d, '*.json')).sort
      end.uniq

      versions = property_definition(type, property)['versions'] rescue []
      { entity_type: type, property: property,
        versions: versions,
        snapshots: files.collect do |f|
          m = entity_meta_read f
          { file: File.basename(f), version: m['version'], digest: m['digest'],
            active: m['active'], removed: !!m['removed'] }
        end }
    end

    # ------------------------------------------------------------------
    # Execution
    # ------------------------------------------------------------------

    # Argument names a caller may pass for `type/property`: its own declared
    # arguments PLUS those of every (transitive) dependency.  Dependencies are
    # materialised as recursive inputs, so e.g. a dependency-free
    # `activity_call` may legitimately carry `treatment`, which only its
    # dependency `raw_activity` understands; Workflow forwards it.  Only the
    # property's OWN required arguments are mandatory -- a dependency's
    # required arguments may be satisfied by defaults or by a caller further
    # up the chain.
    def entity_argument_closure(type, property, seen = nil)
      seen ||= {}
      meta = property_definition type, property
      return [] if meta.nil? || seen[property]
      seen[property] = true
      own = normalize_argument_hashes(meta['arguments']).collect { |a| a['name'] }
      deps = Array(meta['dependencies']).collect do |d|
        entity_argument_closure type, d, seen
      end.flatten
      (own + deps).uniq
    end

    # Argument names that are required (no default) anywhere in the property's
    # dependency closure, excluding the property's own arguments (already
    # checked in entity_validate_arguments!).  These must be supplied by the
    # caller of the RECEIVER because the dep block forwards them down and
    # nothing else can provide them.
    def entity_closure_required(type, property, seen = nil)
      seen ||= {}
      meta = property_definition type, property
      return [] if meta.nil? || seen[property]
      seen[property] = true
      from_deps = Array(meta['dependencies']).collect do |dep|
        dmeta = property_definition type, dep
        next [] if dmeta.nil?
        required = normalize_argument_hashes(dmeta['arguments'])
                   .select { |a| a['required'] && a['default'].nil? }
                   .collect { |a| a['name'] }
        required + entity_closure_required(type, dep, seen)
      end.flatten.compact.uniq
      from_deps - normalize_argument_hashes(meta['arguments'])
                             .collect { |a| a['name'] }
    end

    def entity_validate_arguments!(meta, arguments, known = nil)
      declared = normalize_argument_hashes(meta['arguments'])
      known  ||= declared.collect { |a| a['name'] }
      extra    = arguments.keys.collect(&:to_s) - known
      unless extra.empty?
        raise ScoutException,
              "Unknown argument(s) for #{meta['entity_type']}/#{meta['property']}: " \
              "#{extra.sort * ', '}. Declared (including dependencies): " \
              "#{known.sort * ', '}"
      end

      missing = declared.select do |a|
                   name = a['name']
                   a['required'] && !arguments.key?(name) && !arguments.key?(name.to_sym) && a['default'].nil?
                 end.collect { |a| a['name'] }
      unless missing.empty?
        raise ScoutException,
              "Missing required argument(s) for #{meta['entity_type']}/" \
              "#{meta['property']}: #{missing.sort * ', '}. Declared: " \
              "#{known.sort * ', '}"
      end

      # A dependency's required-without-default argument must be supplied by
      # the receiver's caller; surface it here rather than as a bare
      # ParameterException from the Step machinery.
      if meta['entity_type'] && meta['property']
        Array(entity_closure_required(meta['entity_type'], meta['property']))
          .each do |name|
          next if arguments.key?(name) || arguments.key?(name.to_sym)
          raise ScoutException,
                "Missing required argument(s) for #{meta['entity_type']}/" \
                "#{meta['property']}: #{name} (required by a dependency " \
                "property). Arguments accepted here: #{known.sort * ', '}"
        end
      end
      arguments
    end

    def entity_property_job(entity_type:, property:, entity:, arguments: {}, entity_options: nil)
      type     = entity_type! entity_type.to_s
      property = entity_property_name! property.to_s
      mod      = load_entity_type type
      raise ScoutException,
            "No active entity properties for type #{type}: define one with " \
            "Cortex.define_property first" if mod.nil?

      defn = property_definition type, property
      raise ScoutException,
            "Entity property #{type}/#{property} is not active. Active: " \
            "#{property_definitions(type).collect { |d| d[:property] } * ', '}. " \
            "See Cortex.property_history for prior versions." if defn.nil? || !defn['active']

      entity_validate_arguments! defn, arguments, entity_argument_closure(type, property)

      # Build Steps through mod.job (never Task#job): only the module's
      # step_module carries the `entity`/`entity_list` helpers the body needs,
      # and only Workflow#job extends a Step with it.
      entity_vector_job mod, property, entity, arguments
    end

    # Identity inputs of the ACTIVE definition, passed explicitly on every job
    # we build.  Scout hashes only non-default inputs, so explicit values are
    # what pins a job path to its definition version/digest.
    def entity_identity_inputs(type, property)
      defn = property_definition(type, property) || {}
      { _cortex_definition: "#{type}/#{property}",
        _cortex_definition_version: defn['version'].to_i,
        _cortex_definition_digest: defn['digest'] }
    end

    # Build the property Step(s) for a receiver.
    #
    # Always constructs Steps through `mod.job` (Workflow#job) so each Step is
    # extended with the module's step_module: the body's `entity` /
    # `entity_list` helpers live in that mixin, and a Step built straight from
    # Task#job executes the body WITHOUT them (NameError on `entity_list`,
    # critic finding).
    #
    # Dispatch (critic-verified semantics):
    #   :single, :array -> one Step per receiver member; the body always sees
    #                      a single `entity`.  A list receiver maps to an Array
    #                      of Steps and an Array of results.
    #   :both           -> scalar receiver: one Step keyed by the entity
    #                      (entity branch); list receiver: ONE vector Step
    #                      keyed by the reserved "Default" jobname with the
    #                      receiver in the :list input (entity_list branch).
    def entity_vector_job(mod, property, entity, arguments = {})
      type = mod.name
      defn = property_definition(type, property) || {}
      args = arguments.merge(entity_identity_inputs(type, property))

      if defn['property_type'].to_s == 'both' && Array === entity
        mod.job(property.to_sym, 'Default', args.merge(list: entity))
      else
        jobs = Array(entity).collect { |e| mod.job(property.to_sym, e, args) }
        Array === entity ? jobs : jobs.first
      end
    end

    def run_entity_property(entity_type:, property:, entity:, arguments: {},
                            entity_options: nil, update: false)
      job = entity_property_job(entity_type: entity_type, property: property,
                                entity: entity, arguments: arguments,
                                entity_options: entity_options)
      jobs = Array === job ? job : [job]
      jobs.each { |j| j.clean if update }
      jobs.each { |j| j.run unless j.done? }
      # Unwrap single receivers: a scalar receiver's receipt carries the value
      # itself, not a one-element list.
      result = jobs.collect(&:load)
      result = result.first unless Array === job
      [job, result]
    end

  end

end
