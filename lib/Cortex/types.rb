# ==========================================================================
# Cortex::Types — entity-type module factory + declaration engine
# --------------------------------------------------------------------------
# Design §5 (design/property-subsystem-redesign.md):
#
#   Cortex::Types.for(type) -> Module
#       returns (creating) an anonymous module with
#       `extend Workflow; extend EntityWorkflow; self.name = type`
#       (EntityWorkflow.extended already extends Workflow+Entity and
#       installs the `entity`/`entity_list` helpers — entity.rb:14-45).
#
#   Cortex::Types.register(mod, defn) / Cortex::Types.definition_inputs(defn)
#       declares, in order: author arguments (from the definition spec),
#       then the three defaultless identity inputs (AFTER author arguments
#       because bodies bind inputs positionally — mechanism U4(a) preserved
#       from the pre-redesign entities.rb:492-510), then dep blocks for each
#       dependency, then property_task.
#
# The per-property declaration sequence lived in the pre-redesign
# Cortex#entity_compile_property! (entities.rb); it moved here verbatim
# (identity inputs, the critic-verified dependency-forwarding block,
# property_task, and the scout-gear 10.12.2 argument/identity wrapper).
# Store operations and orchestration stay in Cortex / Cortex::Properties
# (entities.rb).
# ==========================================================================

require 'scout'
require 'scout/workflow/entity'

module Cortex
  module Types
    # The three definition-identity inputs.  Declared defaultless and
    # provided explicitly on every job, so `non_default_provided_inputs` is
    # never empty and every Cortex property address carries its hash
    # (design §3 rule 3; mechanism U4(a)).
    IDENTITY_INPUTS = [
      [:_cortex_definition, :string,
       'Active definition identity (engine-managed; keys job cache identity)'],
      [:_cortex_definition_version, :integer,
       'Active definition version (engine-managed; keys job cache identity)'],
      [:_cortex_definition_digest, :string,
       'Active definition digest (engine-managed; keys job cache identity)']
    ].freeze

    class << self
      # ------------------------------------------------------------------
      # Module factory
      # ------------------------------------------------------------------

      # Anonymous module named exactly +type+ (design §5: naming the module
      # exactly `<Type>` is what makes `workflow.to_s` = `<Type>`, the
      # three-segment short_path, and `var/jobs/<Type>/` alignment hold).
      #
      # Deliberately NOT memoized on the type name: Scout memoizes Task
      # objects per module+name (Persist.memory), so redeclaring a
      # same-named property on a reused module keeps running the first body
      # forever.  Each compile pass needs a FRESH generation; generation
      # caching (keyed on the manifest digest) lives in the load path
      # (Cortex.load_entity_type / managed_entity_registry).
      def for(type)
        Cortex.entity_new_module(type)
      end

      # ------------------------------------------------------------------
      # Declaration data
      # ------------------------------------------------------------------

      # Ordered input declarations for one property definition, as data:
      # author arguments (declaration options included) FIRST, then the
      # three defaultless identity inputs.  Order is load-bearing: Step
      # bodies receive task inputs positionally in declaration order, so
      # the author's Proc parameters must bind the first N inputs or they
      # would receive the `_cortex_definition` string instead of their own
      # values.
      #
      # Entries are hashes:
      #   author  -> {name:, type:, description:, default:, options:}
      #   identity-> {name:, type:, description:}   (no default, no options:
      #              a default equal to the active value never reaches
      #              non_default_inputs and the job hash would not move on
      #              a definition change — see IDENTITY_INPUTS)
      def definition_inputs(defn)
        meta = defn[:meta] || {}
        author = Cortex.normalize_argument_hashes(meta['arguments']).collect do |arg|
          options = {}
          options[:required] = true if arg['required'] && arg['default'].nil?
          { name: arg['name'].to_sym,
            type: Cortex.entity_type_sym(arg['type'] || 'string'),
            description: arg['description'].to_s,
            default: arg['default'],
            options: options }
        end

        author + IDENTITY_INPUTS.collect do |(name, type, description)|
          { name: name, type: type, description: description }
        end
      end

      # ------------------------------------------------------------------
      # Declaration engine (one property onto +mod+)
      # ------------------------------------------------------------------

      # Compile a single property into +mod+.  The body is evaluated against
      # the definition file so syntax errors and backtraces cite it.
      # Declaration order: author arguments, identity inputs, dep blocks,
      # property_task, wrapper (design §5 Cortex::Properties.install steps
      # 1-4; historically entity_compile_property!).
      def register(mod, defn, identities = {})
        type     = defn[:type]
        property = defn[:property]
        meta     = defn[:meta]
        body     = defn[:body]
        path     = defn[:body_path]

        # --- declared arguments + hidden identity inputs ---------------
        # Identity inputs participate in cache identity: a new definition
        # version or digest yields different job paths even when all visible
        # inputs are unchanged.  Default-less + always provided = every job
        # path is keyed by its definition identity (U4(a), §3 rule 3).
        declare_inputs(mod, definition_inputs(defn))

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
            dep_args = options.slice(*Cortex.entity_declared_arguments(mod, dep.to_sym))
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
        # because the eval'd Proc declares the argument list as positional
        # parameters, and `entity` is a method on the Step's exec context.
        # property_task then wraps this proc so :single/:array/:both behave
        # exactly like hand-written Entity properties.
        arg_names = Cortex.normalize_argument_hashes(meta['arguments']).collect { |a| a['name'] }
        body_proc = Cortex.entity_body_proc(body, arg_names, path)
        # meta['result_type'] is the on-disk field (legacy name; the
        # surfaced vocabulary is result_kind, applied on read by
        # property_definition — see the vocabulary note in entities.rb).
        mod.property_task({ property.to_sym => Cortex.entity_type_sym(meta['result_type']) },
                          meta['property_type'].to_sym, &body_proc)

        # --- forwarding wrapper ----------------------------------------
        # property_task's public property drops *args (scout-gear 10.12.2);
        # install our own wrapper after it.
        # Identity of THIS definition: the wrapper passes it as explicit kwargs
        # so the job hash is pinned to it (see install_property_wrapper).
        identity = { _cortex_definition: "#{type}/#{property}",
                     _cortex_definition_version: meta['version'].to_i,
                     _cortex_definition_digest: meta['digest'] }
        Cortex.install_property_wrapper(mod, property, meta['property_type'], identity)

        mod
      end

      private

      # Apply the ordered declarations of definition_inputs to +mod+.
      # Author entries always carry an options Hash (possibly empty) exactly
      # as the historical inline declaration did; identity entries are
      # declared with the three-argument form so no default can ever be
      # attached to them.
      def declare_inputs(mod, declarations)
        declarations.each do |d|
          if d.key?(:options)
            mod.input d[:name], d[:type], d[:description], d[:default], d[:options]
          elsif d.key?(:default)
            mod.input d[:name], d[:type], d[:description], d[:default]
          else
            mod.input d[:name], d[:type], d[:description]
          end
        end
      end
    end
  end
end
