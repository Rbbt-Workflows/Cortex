# ==========================================================================
# Cortex::Properties — Step-based property execution engine (design §2.3/§2.4/§2.6)
# --------------------------------------------------------------------------
# NEW-in-Cortex run path (step 3 of the redesign implementation).  Companion
# to, not yet a replacement of, the historical Cortex.run_entity_property in
# entities.rb: the old path keeps writing the var/cortex/properties registry
# until that store is retired (step 5); this module NEVER writes it.
#
#   Cortex::Properties.run_property(entity_type:, property:, receiver:,
#                                    arguments:, update:, timeout:, ...)
#       -> one receipt Hash (scalar/vector) or an Array of receipts (fan-out)
#
#       Dispatch (design §2.3, U5 verdict):
#         :single + scalar entity -> ONE Step (one receipt)
#         :single + list receiver -> N per-member Steps (fan-out, one receipt
#                                    each), NEVER the vector form
#         :array/:both + any receiver -> ONE vector Step `Default_<md5>`
#                                    built with list: receiver
#
#       A member that fails does NOT fail the fan-out: every member still
#       produces a receipt, the failed one carrying the §2.6 error envelope.
#
#   Cortex::Properties.resolve_address(ref) -> resolution result Hash
#       { step:, address:, recovered:, recovered_from? } — the Step is a bare
#       path-Step (Step.load / Step.new); nothing ever executes.
#       Failures raise ParameterException whose message embeds the §2.6
#       envelope (candidates, ambiguity).
#
#   Cortex::Error.envelope(exception, context:) -> the §2.6 structured error
#       envelope; shared by the run path here and (step 4) every tool task.
# ==========================================================================

require 'json'

module Cortex
  # Design §2.6 structured error envelope.  One implementation, used by every
  # failure path (run members here, tool tasks in step 4).
  module Error
    VERDICT_ARGUMENT   = 'argument_error'
    VERDICT_DEFINITION = 'definition_error'
    VERDICT_EXECUTION  = 'execution_error'

    class << self
      # Returns a plain Hash with symbol keys:
      #
      #   { exception_class, exception_message, message_is_bare,
      #     backtrace_head[], verdict, context, warning? }
      #
      # exception_message is VERBATIM.  message_is_bare is true exactly when
      # the message equals the class name (Ruby's `raise SomeError` default
      # with no argument — the F3 signature).
      def envelope(exception, context: {})
        klass   = exception_class_of(exception)
        message = exception.respond_to?(:message) ? exception.message : exception.to_s
        backtrace = exception.respond_to?(:backtrace) ? Array(exception.backtrace) : []

        bare = message.to_s.empty? || message.to_s == klass
        envelope = {
          exception_class: klass,
          exception_message: message.to_s,
          message_is_bare: bare,
          backtrace_head: backtrace.first(5).collect(&:to_s),
          verdict: verdict_of(exception),
          context: context
        }
        if bare && !envelope[:backtrace_head].empty?
          envelope[:warning] =
            'The definition raised a bare exception (message == class name). ' \
            "Raise with an explanatory message, e.g. `raise ScoutException, '...'`. " \
            "Raise site: #{envelope[:backtrace_head].first}"
        end
        envelope
      end

      # argument_error  - ParameterException at input binding
      # definition_error- ScoutException-family raised from a body
      # execution_error - anything else
      # (Cortex::EntityPropertyTimeout derives from Exception, never
      #  ScoutException, so a timeout is always execution_error.)
      def verdict_of(exception)
        klass = exception_class_of(exception)
        case
        when parameter_exception?(klass) then VERDICT_ARGUMENT
        when scout_exception?(klass)     then VERDICT_DEFINITION
        else VERDICT_EXECUTION
        end
      end

      private

      def exception_class_of(exception)
        return exception.to_s if String === exception
        exception.class.name.to_s
      end

      def const_safely(name)
        return name if Module === name
        Object.const_get(name)
      rescue NameError
        nil
      end

      def parameter_exception?(klass)
        return true if klass == 'ParameterException'
        k = const_safely(klass)
        return false unless k
        k <= ParameterException rescue false
      end

      def scout_exception?(klass)
        k = const_safely(klass)
        return false unless k
        k <= ScoutException rescue false
      end
    end
  end

  # Step-based execution engine (see file header).
  module Properties
    class << self
      # ------------------------------------------------------------------
      # run_property — design §2.3 dispatch, §2.7 receipts
      # ------------------------------------------------------------------
      #
      # receiver: String entity id | Array member ids | {list: 'Type/name'}
      # options:  update (clean + recompute), timeout, entity_options,
      #           agent/job (provenance)
      def run_property(entity_type:, property:, receiver:, arguments: {},
                       update: false, timeout: nil, entity_options: nil,
                       agent: 'Cortex', job: nil)
        type      = Cortex.entity_type!(entity_type.to_s)
        property  = Cortex.entity_property_name!(property.to_s)
        arguments = (arguments || {}).to_h

        mod = Cortex.load_entity_type(type)
        raise ScoutException,
              "Unknown entity type #{type}: no Cortex definitions and no " \
              'adoptable EntityWorkflow constant with that name' if mod.nil?

        # ---------------------------------------------------------------
        # REGIME CLASSIFICATION (design §11): BEFORE any Step is built.
        #   Active definition (own or adopted) -> task path (regime B/C);
        #   no active definition on an adoptable module -> plain-method
        #   path (regime A).  A task that fails to build or execute is an
        #   ERROR (§2.6 envelope), never a silent fallback.
        # ---------------------------------------------------------------
        defn = Cortex.property_definition(type, property)
        defn = nil if Hash === defn && !defn['active']
        regime = defn.nil? ? :plain : :task

        # Named-list receivers resolve to their member ids up front; the
        # named list only annotates receipts and drives the staleness rule.
        named_list = nil
        if Hash === receiver && (receiver[:list] || receiver['list'])
          list_ref   = (receiver[:list] || receiver['list']).to_s
          named_list = list_ref.include?('/') ? list_ref.split('/', 2).last : list_ref
          members, = Cortex.read_list(type, named_list)
          raise ScoutException,
            "Named list #{type}/#{named_list} does not exist. Create it " \
            'with cortex_write_list first' if members.nil?
          receiver = members
        end

        scalar_receiver = !(Array === receiver)

        return run_plain_method(type: type, property: property, mod: mod,
                                receiver: receiver, arguments: arguments,
                                named_list: named_list,
                                entity_options: entity_options) if regime == :plain

        # --- Regime B/C: task path ---------------------------------------
        # Input validation BEFORE any Step is built; failure carries the
        # §2.6 envelope with verdict argument_error and propagates uncaught.
        begin
          Cortex.entity_validate_arguments!(defn, arguments,
                                            Cortex.entity_argument_closure(type, property))
        rescue StandardError => e
          error = Cortex::Error.envelope(e, context: { phase: 'input_validation',
                                                       entity_type: type,
                                                       property: property })
          raise ParameterException, JSON.generate(error)
        end

        vector = %w[both array].include?(defn['property_type'].to_s)

        jobs = build_jobs(mod, type, property, receiver, arguments,
                          vector: vector, entity_options: entity_options)

        # update / staleness bookkeeping (NOT counted against the timeout):
        #   update:true force-cleans everything; a named-list run whose list
        #   file is newer than a DONE Step is stale and recomputes.
        stale_list = stale_list_path(type, named_list, update)
        jobs.each do |j|
          j.clean if update || (stale_list && j.done? &&
                                Path.newer?(j.path, stale_list))
        end

        receipts = execute_jobs(jobs, arguments: arguments,
                                scalar_receiver: scalar_receiver,
                                vector: vector, named_list: named_list,
                                timeout: timeout)

        # Fan-out failure counts (§2.6): annotate errored member receipts.
        if receipts.length > 1
          total  = receipts.length
          failed = receipts.count { |r| r[:error] }
          receipts.each do |r|
            r[:failed_members] = failed if r[:error]
            r[:total_members]  = total
          end
        end

        # §2.7: vector runs return ONE receipt; :single fan-out returns an
        # array of per-member receipts; a scalar :single receiver returns
        # its single receipt unwrapped.
        return receipts.first if vector || (scalar_receiver && receipts.length == 1)
        receipts
      end

      # Regime A (design §11): no active Cortex definition, adoptable module.
      # The property runs as a plain method on the annotated entity; nothing
      # is materialized, so the receipt carries the raw value and NULL
      # address/materialized/info_path, with the RECEIVER POPULATED (the
      # §2.7 shape; the pre-step-3 demo returned receiver: null).
      #   - arguments {}          -> zero arguments (the working demo shape)
      #   - arguments non-empty   -> Method#parameters introspection:
      #       keyword params (:key/:keyreq) -> keyword dispatch
      #       positional param (:req/:opt)   -> the Hash as ONE positional
      #       neither                         -> argument_error envelope (§2.6)
      #   - named-list receiver   -> per-member execution, one receipt each
      #   - any failure RAISES (never swallowed): a ParameterException keeps
      #     its §2.6 envelope; the ScoutException-family maps to
      #     definition_error; anything else to execution_error.
      def run_plain_method(type:, property:, mod:, receiver:, arguments:,
                           named_list: nil, entity_options: nil)

        options = parse_entity_options(entity_options)
        members = Array === receiver ? receiver : [receiver]
        # Native classes (no Entity/EntityWorkflow mixin, e.g. a plain
        # `find`-style class) have no Annotation `setup`; fall back to
        # the class-level lookup convention when present.
        annotate = mod.respond_to?(:setup) ?
          ->(m) { mod === m ? m : mod.setup(m) } :
          ->(m) { mod.respond_to?(:find) ? mod.find(m) : m }
        receipts = members.collect do |member|
          annotated = annotate.call(member)
          value =
            if arguments.nil? || arguments.empty?
              annotated.send(property)
            else
              dispatch = plain_method_dispatch(mod, type, property, arguments)
              if dispatch[:kwargs]
                kwargs = {}
                arguments.each { |k, v| kwargs[k.to_sym] = v }
                annotated.send(property, **kwargs)
              else
                annotated.send(property, arguments)
              end
            end

          Cortex::Receipt.build(
            entity_type: type,
            property: property,
            receiver: member,
            arguments: arguments,
            defn: nil,
            step: nil,
            value: value
          )
        rescue NoMethodError
          raise ScoutException,
                "No active definition for #{type}/#{property} and the adopted " \
                "module has no instance method `#{property}'. Define it with " \
                "cortex_property_define first. Exception message: #{$!.message}"
        end
        receipts.each { |r| r[:entity_list] = "#{type}/#{named_list}" if named_list }
        Array === receiver ? receipts : receipts.first
      end


      # §11.3 argument rule for the plain-method path.  Two introspection
      # sources, in order:
      #
      #   1. mod.properties[property] -- for EntityWorkflow `property` blocks,
      #      scout-gear records the AUTHOR block's parameters there
      #      (lib/scout/entity/property.rb:66 `properties[name] =
      #      block.parameters`).  The generated wrapper method itself always
      #      takes (*args, **kwargs) (property.rb:98), so Method#parameters
      #      would always report rest+keyrest and dispatch could never see
      #      the author's real signature.
      #   2. Method#parameters -- for plain instance methods (e.g. the
      #      Finances Security demo surface, `def is_fee?`).
      #
      # Dispatch: keyword params -> [arguments] as kwargs; positional params
      # -> the Hash as ONE positional argument; neither -> argument_error
      # envelope (§2.6).  Returns the argument array to splat into #send;
      # kwargs cannot be splatted through a plain Array, so keyword dispatch
      # is signalled by the leading element being the Hash itself.
      def plain_method_dispatch(mod, type, property, arguments)
        params = nil
        if mod.respond_to?(:properties) && Hash === mod.properties
          params = mod.properties[property.to_sym] rescue nil
        end
        params = annotated_method_parameters(mod, property) if params.nil?

        kinds = Array(params).collect { |kind, _| kind }
        if kinds.any? { |k| %i[key keyreq keyrest].include?(k) }
          { kwargs: true }
        elsif kinds.any? { |k| %i[req opt rest].include?(k) }
          { kwargs: false }
        else
          raise_plain_argument_error(type, property, arguments)
        end
      end

      def annotated_method_parameters(mod, property)
        member = mod.setup('probe', {})
        method = (member.method(property) rescue nil)
        return [] if method.nil?
        method.parameters
      end

      def raise_plain_argument_error(type, property, arguments)
        error = { exception_class: 'ParameterException',
                  exception_message: "Method #{type}##{property} accepts no " \
                    "arguments but #{Array(arguments.keys) * ', '} given",
                  message_is_bare: false, backtrace_head: [],
                  verdict: Cortex::Error::VERDICT_ARGUMENT,
                  context: { phase: 'input_validation', entity_type: type,
                             property: property } }
        raise ParameterException, JSON.generate(error)
      end

      # Public helper for callers that need the Step(s) WITHOUT running:
      #   vector?(type, property) -> true when the property runs ONE vector
      #   Default_<md5> Step for any receiver (arity :array/:both).
      def vector?(type, property)
        defn = Cortex.property_definition(type, property) || {}
        %w[both array].include?(defn['property_type'].to_s)
      end

      # Public build (never executes): same dispatch as run_property but only
      # constructs the Step(s); used by tests and index builders.
      def build_steps(type, property, receiver, arguments = {}, entity_options: nil)
        mod = Cortex.load_entity_type(type)
        build_jobs(mod, type, property, receiver, arguments,
                   vector: vector?(type, property), entity_options: entity_options)
      end

      # ------------------------------------------------------------------
      # resolve_address — design §2.4 resolution rule
      # ------------------------------------------------------------------
      #
      # 1) exact literal path; 2) Step.load (var/jobs prefix + relocation);
      # 3) ONE loud last-16-hex recovery pass inside var/jobs/<Type>/<property>/;
      # 4) structured ParameterException listing directory candidates.
      # Never executes: only bare path-Steps are constructed.
      def resolve_address(ref, _options = {})
        ref = ref.to_s
        raise ParameterException, 'Empty address' if ref.empty?

        # 1) exact literal path
        return result_for(Step.new(Path.setup(ref).find), recovered: false) if File.exist?(ref)

        # 2) Step.load: var/jobs-prefixed short_path / relocation
        begin
          candidate = Step.load(ref)
          return result_for(candidate, recovered: false) if candidate && File.exist?(candidate.path.to_s)
        rescue StandardError
          nil
        end

        # 3) one recovery pass, reported loudly
        recovery = recover_by_suffix(ref)
        return recovery if recovery

        # 4) nothing resolved: structured error with candidates
        type, property, = split_address(ref)
        dir = located_directory(property_directory(type, property))
        candidates = directory_candidates(dir)
        err = {
          exception_class: 'ParameterException',
          exception_message: "Cannot resolve address #{ref.inspect}: no such " \
          'materialized result, and no unique last-16-hex ' \
          "match. Candidates in #{dir}: " \
          "#{candidates.empty? ? '(directory empty or missing)' : candidates * ', '}",
          message_is_bare: false,
          backtrace_head: [],
          verdict: Cortex::Error::VERDICT_ARGUMENT,
          context: { phase: 'resolve_address', address: ref, candidates: candidates }
        }
        raise ParameterException, JSON.generate(err)
      end

      private

      # --- dispatch ----------------------------------------------------

      # Build the Step(s) per §2.3.  Always mod.job: only the module's
      # step_module carries the entity/entity_list helpers bodies need.
      def build_jobs(mod, type, property, receiver, arguments, vector:,
                     entity_options: nil)

        options = parse_entity_options(entity_options)
        args    = arguments.merge(Cortex.entity_identity_inputs(type, property))
          .merge(options)

        if vector
          # ONE vector Step keyed "Default"; a scalar receiver is promoted to
          # a one-element annotated list (the body reads `entity_list`).
          list = Array === receiver ? receiver : mod.setup([receiver.to_s], options)
          [mod.job(property.to_sym, 'Default', args.merge(list: list))]
        else
          annotated = Array === receiver ? mod.setup(receiver, options)
          : mod.setup(receiver.to_s, options)
          Array(annotated).collect { |e| mod.job(property.to_sym, e, args) }
        end
      end

      def parse_entity_options(entity_options)
        return {} unless entity_options
        Cortex.parse_entity_options(entity_options)
      end

      def stale_list_path(type, named_list, update)
        return nil if update || named_list.to_s.empty?
        _e, _m, path = Cortex.read_list(type, named_list)
        File.exist?(path) ? path : nil
      end

      # Execute every job inside ONE timeout budget (matching the historical
      # path: the bound covers Step#run and the per-member loop).  A member
      # failure never aborts the fan-out; EntityPropertyTimeout always
      # propagates (the whole run is out of budget).
      def execute_jobs(jobs, arguments:, scalar_receiver:, vector:,
                       named_list:, timeout:)
        receipts = []
        Cortex.entity_property_with_timeout(Cortex.entity_property_timeout(timeout)) do
          jobs.each do |job|
            begin
              job.run unless job.done?
              value = job.load
              receipts << build_receipt(job, arguments, scalar_receiver,
                                        vector, named_list, value)
            rescue Cortex::EntityPropertyTimeout
              raise
            rescue Exception => e # rubocop:disable Lint/RescueException
              member = job_member(job)
              receipts << error_receipt(job, arguments, scalar_receiver,
                                        vector, named_list, e, member)
            end
          end
        end
        receipts
      end

      # The member id a Step ran for: the entity input value recorded in the
      # Step's own .info (position of the entity_name input), falling back to
      # the label prefix.
      def job_member(job)
        info = job.info
        names = Array(info[:input_names] || [])
        values = Array(info[:inputs] || [])
        entity_idx = names.index { |n| n.to_s == entity_input_name(job) }
        return values[entity_idx] if entity_idx && values[entity_idx]
        File.basename(job.path.to_s).split('_').first
      end

      def entity_input_name(job)
        (job.respond_to?(:task) && job.task &&
         job.task.workflow.respond_to?(:entity_name) &&
         job.task.workflow.entity_name.to_s) ||
        job.info[:workflow].to_s.gsub('::', '_').downcase
      end

      # Receipt receiver label per §2.7:
      #   scalar receiver -> the entity id (even when the Step is a vector
      #                       Default_<md5> for a :both property)
      #   fan-out member  -> the member id (+ entity_list when named)
      #   vector list run -> {list: "Type/name", members: N}
      def receipt_receiver(job, scalar_receiver, vector, named_list)
        if vector
          members = vector_members(job)
          return members.first if scalar_receiver && members.length == 1
          out = { members: members.length }
          out[:list] = named_list if named_list
          out
        else
          job_member(job) if job
        end
      end

      # Member ids of a vector run, from the :list input recorded in .info.
      def vector_members(job)
        info = job.info
        names = Array(info[:input_names] || [])
        values = Array(info[:inputs] || [])
        idx = names.index { |n| n.to_s == 'list' }
        return [] unless idx
        v = values[idx]
        v.respond_to?(:length) ? v : []
      end

      def build_receipt(job, arguments, scalar_receiver, vector, named_list, value)
        Cortex::Receipt.build(
          entity_type: workflow_name(job),
          property: job.task_name.to_s,
          receiver: receipt_receiver(job, scalar_receiver, vector, named_list),
          arguments: arguments,
          defn: definition_meta_for(job),
          step: job,
          value: value
        ).tap { |r| r[:entity_list] = "#{workflow_name(job)}/#{named_list}" if named_list }
      end

      def error_receipt(job, arguments, scalar_receiver, vector, named_list,
                        exception, member)
        envelope = Cortex::Error.envelope(exception,
                                          context: { phase: 'execution',
                                                     entity_type: workflow_name(job),
                                                     property: job.task_name.to_s,
                                                     member: member })
        Cortex::Receipt.build(
          entity_type: workflow_name(job),
          property: job.task_name.to_s,
          receiver: member || receipt_receiver(job, scalar_receiver, vector, named_list),
          arguments: arguments,
          defn: definition_meta_for(job),
          step: job,
          value: nil, load: false
        ).merge(status: job.status, error: envelope)
      end

      def definition_meta_for(job)
        Cortex.property_definition(workflow_name(job), job.task_name.to_s) || {}
      end

      def workflow_name(job)
        job.info[:workflow] || job.path.to_s.split('/')[-3]
      end

      # --- resolution --------------------------------------------------

      def result_for(step, recovered:, recovered_from: nil)
        out = { step: step, address: step.short_path.to_s, recovered: recovered }
        out[:recovered_from] = recovered_from if recovered
        out
      end

      # One recovery pass: match the last-16-hex suffix of the label inside
      # var/jobs/<Type>/<property>/.  Reports loudly; ambiguity is an error.
      def recover_by_suffix(ref)
        label = File.basename(ref).sub(/\.info\z/, '')
          .sub(/\.(tsv|json|yaml|marshal)\z/, '')
        m = label.match(/([0-9a-f]{16,32})\z/)
        return nil unless m
        # Recovery window is the FULL hex tail (up to 32), not the last 16:
        # the md5 sits at the very end of the label, so a full-hash reference
        # (the common mangled-prefix case: prefix scrambled, hash intact)
        # must match too.  The design's "last-16-hex" window is the MINIMUM
        # recognized; any 16..32-hex tail matches as a suffix.
        hex = m[1]
        candidates = (16..hex.length)
          .collect { |n| hex[-n, n] }
          .select { |t| t =~ /\A[0-9a-f]+\z/ }

        type, property, = split_address(ref)
        return nil if type.nil? || property.nil?

        dir = located_directory(property_directory(type, property))
        return nil unless dir

        # The suffix match is a plain suffix match: the last 16 hex of an
        # address usually fall INSIDE the 32-hex md5 with no '_' before them,
        # so the pattern is '*<suffix>' (any chars, then the suffix), not
        # '*_<suffix>'.
        files = Dir.glob(File.join(dir, '*')).reject { |p| p.end_with?('.info') }
        matches = files.select do |p|
          label = File.basename(p)
            .sub(/\.(tsv|json|yaml|marshal)\z/, '')
          candidates.any? { |t| label.end_with?(t) }
        end.uniq
        return nil if matches.empty?

        matched_suffix = candidates.find do |t|
          File.basename(matches.first)
            .sub(/\.(tsv|json|yaml|marshal)\z/, '')
            .end_with?(t)
        end || hex[-16, 16]

        if matches.length > 1
          err = {
            exception_class: 'ParameterException',
            exception_message: "Ambiguous hex-tail recovery for #{ref.inspect}: " \
            "#{matches.length} candidates match #{matched_suffix.inspect} in " \
            "#{dir}: #{matches.collect { |x| File.basename(x) } * ', '}",
            message_is_bare: false,
            backtrace_head: [],
            verdict: Cortex::Error::VERDICT_ARGUMENT,
            context: { phase: 'resolve_address', address: ref, suffix: matched_suffix,
                       candidates: matches.collect { |x| File.basename(x) } }
          }
          raise ParameterException, JSON.generate(err)
        end

        result_for(Step.new(Path.setup(matches.first).find),
                   recovered: true, recovered_from: matched_suffix)
      end

      def split_address(ref)
        parts = ref.to_s.sub(/\.info\z/, '').split('/')
        type, property, label = parts.length == 3 ? parts : [nil, nil, nil]
        [type, property, label]
      end

      def property_directory(type, property)
        return nil if type.nil? || property.nil?
        # Workflow.directory is the SAME anchor the entity-type modules use
        # (definition.rb:15-20: Scout's default jobs root, resolved through
        # the active path maps), so recovery and candidate listing always look
        # in the tree the runs actually landed in.
        Workflow.directory[type.to_s][property.to_s]
      end

      # Resolve a Path/String directory reference to its LOCATED String form
      # (or nil when it does not exist): 'var/jobs/<T>/<p>' is a relative Path
      # that only resolves through the active path maps.
      def located_directory(dir)
        return nil if dir.nil?
        located = dir.respond_to?(:find) ? dir.find.to_s : dir.to_s
        File.directory?(located) ? located : nil
      end

      def directory_candidates(dir)
        return [] unless dir
        Dir.glob(File.join(dir, '*')).reject { |p| p.end_with?('.info') }
          .collect { |p| File.basename(p) }.sort
      end
    end
  end
end
