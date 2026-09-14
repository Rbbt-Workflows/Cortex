# ==========================================================================
# Cortex::Receipt — run receipt envelope (design §2.7)
# --------------------------------------------------------------------------
# The run receipt of a property execution.  Every field is mechanically
# derived from the produced Step (`step.path`, `step.short_path`,
# `step.info`, `File.size`) or the call inputs — there is no field an agent
# can improve by transcribing it, and no field the engine cannot populate
# itself.  Resolution from receipt to evidence is `cortex_result(address,
# projection)` — never bash (design §8 F5/F6/F7).
#
# Shape (design §2.7):
#
#   { entity_type, property,
#     receiver: <entity-id> | {list: "<type>/<list>", members: N},
#     arguments,                        # verbatim echo of the argument set
#     definition: {version, digest},    # copied from the identity inputs
#     address: <short_path>,            # vector runs: one; fan-out: array
#     result_kind,
#     status,
#     value,                            # bounded copy of Step#load
#     materialized: {path, bytes},      # step.path / File.size
#     info_path }                       # step.info_file
# ==========================================================================

require 'json'

module Cortex
  module Receipt
    # Default bound (bytes) on the `value` field copy of Step#load.
    VALUE_BYTES = 2000
    VALUE_CHARS = 1200

    class << self
      # Build the §2.7 envelope for ONE produced Step (scalar or one fan-out
      # member).  `receiver:` / `arguments:` / `definition:` come from the
      # call inputs; everything else is read off the Step.
      #
      #   entity_type: String   - the entity type (call input)
      #   property:    String   - the property (call input)
      #   receiver:    value    - entity id (String) or {list:, members:}
      #   arguments:   Hash     - verbatim argument-set echo
      #   defn:        Hash     - active definition meta (version/digest)
      #   step:        Step     - the produced Step
      #   value:       value    - loaded result (bounded below)
      #   value_bound: Integer  - byte bound override for `value`
      #   load:        Boolean  - pass false to never call Step#load
      #                          (error receipts describe errored Steps)
      def build(entity_type:, property:, receiver:, arguments:, defn:, step:,
                value: nil, value_bound: VALUE_BYTES, load: true)
        defn = {} unless Hash === defn
        # `load: false` is for error receipts: an errored Step's #load
        # re-raises the recorded exception, so the envelope builder must
        # be able to describe the Step WITHOUT touching its payload.
        loaded = value
        loaded = step.load if load && !step.nil? && loaded.nil?

        result_kind = defn['result_kind'] || defn['result_type']
        status      = step_status(step)

        {
          entity_type: entity_type.to_s,
          property:    property.to_s,
          receiver:    receiver,
          arguments:   bounded_arguments(arguments),
          definition:  { version: defn['version'].to_i,
                         digest:  defn['digest'] },
          address:     short_path_of(step),
          result_kind: result_kind,
          status:      status,
          value:       bounded_value(loaded, value_bound),
          materialized: materialized_of(step),
          info_path:   step.respond_to?(:info_file) ? step.info_file : nil
        }
      end

      private

      def step_status(step)
        return nil if step.nil?
        step.status
      rescue StandardError
        nil
      end

      def short_path_of(step)
        return nil if step.nil?
        step.short_path.to_s
      rescue StandardError
        nil
      end

      def materialized_of(step)
        return nil if step.nil?
        path = step.path.to_s
        { path: path,
          bytes: File.exist?(path) ? File.size(path) : nil }
      rescue StandardError
        begin
          { path: step.path.to_s, bytes: nil }
        rescue StandardError
          { path: nil, bytes: nil }
        end
      end

      def bounded_arguments(arguments)
        return {} unless Hash === arguments
        arguments
      end

      # Keep the receipt copy of the loaded value readable but bounded; the
      # materialized file remains the authoritative payload.
      def bounded_value(value, bound)
        text = case value
               when nil        then nil
               when String     then value
               when Array, Hash then JSON.fast_generate(value)
               else value.to_s
               end
        return nil if text.nil?
        if text.bytesize > bound
          text.byteslice(0, bound) +
            "...[truncated #{text.bytesize - bound} bytes]"
        else
          text
        end
      end
    end
  end
end
