require 'scout-ai'

# Runtime-only bridge from Scout-AI request context to Cortex child agents.
#
# Scout-AI deliberately keeps request_context out of workflow inputs.  The
# bridge therefore carries the already projected Hash on a per-call copy of
# the Step after LLM.call_workflow has constructed it.  It is never an input,
# never part of a job digest, and is not written by Cortex's conversation or
# brief persistence code.
module Cortex
  module RequestContext
    class IsolationError < StandardError; end

    CONFIG_KEYS = %i[endpoint backend model configuration config].freeze

    module_function

    def project(context)
      return {} unless context
      if defined?(LLM::RequestContext)
        value = LLM::RequestContext.project(context)
        Hash === value ? value : {}
      else
        {}
      end
    end

    def immutable(value)
      case value
      when Hash
        value.each { |key, child| immutable(key); immutable(child) }
      when Array
        value.each { |child| immutable(child) }
      end
      value.freeze
    end
    private_class_method :immutable

    # Copy ordinary mutable containers while resolving Step references through
    # the private tree. Paths and other execution objects retain their
    # identity, which is part of Scout's cache semantics.
    def rewire(value, copies, memo = {})
      return copies[value] if Step === value && copies.key?(value)
      return value if Step === value || (defined?(Path) && Path === value)

      case value
      when Hash
        return memo[value] if memo.key?(value)
        copy = value.dup
        memo[value] = copy
        copy.clear
        value.each { |key, child| copy[rewire(key, copies, memo)] = rewire(child, copies, memo) }
        copy
      when NamedArray
        return memo[value] if memo.key?(value)
        copy = value.dup
        memo[value] = copy
        value.each_with_index { |child, index| Array.instance_method(:[]=).bind_call(copy, index, rewire(child, copies, memo)) }
        copy
      when Array
        return memo[value] if memo.key?(value)
        copy = value.dup
        memo[value] = copy
        value.each_with_index { |child, index| copy[index] = rewire(child, copies, memo) }
        copy
      when String
        value.dup
      else
        if defined?(Set) && Set === value
          return memo[value] if memo.key?(value)
          copy = value.dup
          memo[value] = copy
          copy.clear
          value.each { |child| copy.add(rewire(child, copies, memo)) }
          copy
        else
          value
        end
      end
    end
    private_class_method :rewire

    # Task jobs are cached by Scout Gear and a cache hit can return the same
    # Step instance for two calls. Never put caller-specific state on that
    # instance. Instead duplicate the complete in-memory dependency tree and
    # attach the state only to the duplicates. The duplicates retain the
    # original paths (and therefore the original cache identity), while their
    # persisted results and inputs remain untouched.
    def isolated_tree(step, context)
      # rec_dependencies follows declared dependencies only. Step inputs are
      # also execution dependencies and must be included in the private tree.
      originals = []
      pending = [step]
      seen = {}.compare_by_identity
      until pending.empty?
        original = pending.shift
        next if seen[original]
        seen[original] = true
        originals << original
        pending.concat(Array(original.dependencies))
        pending.concat(Array(original.inputs).flatten.select { |input| Step === input })
      end

      copies = {}.compare_by_identity
      originals.each { |original| copies[original] = original.dup }

      originals.each do |original|
        copy = copies.fetch(original)
        # Step#dup does not retain extensions installed by Workflow#job. Those
        # extensions provide task helpers (including recursive inputs), so
        # preserve them on the private copy without changing the cached Step.
        extensions = original.singleton_class.ancestors.drop(1).take_while do |ancestor|
          ancestor != Step && ancestor != Object
        end
        extensions.reverse_each { |extension| copy.extend(extension) }

        # Step#dup is shallow in Scout Gear. These are the mutable fields
        # consumed by execution; task/workflow/path identity is retained.
        copy.inputs = rewire(original.inputs, copies)
        copy.dependencies = rewire(original.dependencies, copies)
        copy.non_default_inputs = rewire(original.non_default_inputs, copies)
        copy.provided_inputs = rewire(original.provided_inputs, copies)
        copy.compute = rewire(original.compute, copies)
        if original.instance_variable_defined?(:@info)
          copy.instance_variable_set(:@info, rewire(original.instance_variable_get(:@info), copies))
        end
        copy.instance_variable_set(:@mutex, Mutex.new)
        copy.instance_variable_set(:@rec_dependencies, {})
        copy.instance_variable_set(:@all_dependencies, nil)
        copy.instance_variable_set(:@result, nil)
        copy.instance_variable_set(:@exec_result, nil)
        copy.exec_context = copy if copy.respond_to?(:exec_context=)
        copy.instance_variable_set(:@cortex_request_context, context)
      end

      copies.fetch(step)
    end

    # Task#job constructs the complete dependency tree synchronously, before
    # LLM.call_workflow returns. Instance variables on the private copies are
    # intentionally used rather than Step#info: they are process-local runtime
    # metadata and cannot affect persistence or identity.
    def attach(step, context)
      return step unless Step === step
      context = project(context)
      return step if context.empty?
      immutable(context)
      isolated_tree(step, context)
    rescue StandardError => error
      # Returning the cached Step would violate the isolation contract.
      raise IsolationError, "Unable to isolate Step for request context: #{error.message}"
    end

    # Read the runtime bridge first.  The second branch consumes the public
    # Scout-AI projection in Step#info for jobs which were produced before the
    # bridge was installed, or when a caller supplied a Step directly.
    def for_step(step)
      return {} unless Step === step

      value = step.instance_variable_get(:@cortex_request_context)
      value = step.info[:request_context] if value.nil?
      value = step.info['request_context'] if value.nil?
      project(value)
    rescue
      {}
    end

    def explicit_options(messages)
      return {} unless messages
      copy = Array(messages).collect do |message|
        Hash === message ? message.dup : message
      end
      options = LLM.options(Chat.setup(copy))
      options = options.dup if Hash === options
      options || {}
    rescue
      {}
    end

    def child_configuration(agent, chat)
      explicit = {}
      other = agent.respond_to?(:other_options) ? agent.other_options : nil
      explicit.merge!(other) if Hash === other
      explicit.merge!(explicit_options(agent.start_chat)) if agent.respond_to?(:start_chat)
      explicit.merge!(explicit_options(chat)) if chat
      project(explicit.select { |key, _value| CONFIG_KEYS.include?(key.to_sym) })
    end

    def effective_for(step, agent, chat)
      inherited = for_step(step)
      explicit = child_configuration(agent, chat)
      # Per-field merge gives explicit child/agent configuration precedence
      # while retaining inherited fields which the child did not specify.
      inherited.merge(explicit)
    end

    # LLM.call_workflow is the narrow Scout-AI dispatch seam: it receives the
    # request context but intentionally does not make it a workflow input.
    # Install this once, after scout-ai has defined the singleton method.
    module DispatchAdapter
      def call_workflow(workflow, task_name, parameters = {}, request_context: nil, **keyword_parameters)
        # Forward the consumed keyword explicitly; implicit super forwarding
        # is not reliable across the Ruby versions supported by Scout-AI.
        job = super(workflow, task_name, parameters,
                    request_context: request_context, **keyword_parameters)
        job = Cortex::RequestContext.attach(job, request_context) if request_context && Step === job
        job
      end
    end

    unless LLM.singleton_class.ancestors.include?(DispatchAdapter)
      LLM.singleton_class.prepend(DispatchAdapter)
    end
  end
end
