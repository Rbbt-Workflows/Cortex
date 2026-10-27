# Minimal internal references for a Cortex execution and its operations.
#
# An Execution is an in-memory invocation/association, not a replacement for a
# Scout job. Its computation reference is the native Step and its short_path;
# separate Execution instances may therefore refer to one cached computation.
# RequestContext is carried alongside that reference and never participates in
# its identity. These objects do not persist a second provenance graph.
module Cortex
  class ComputationReference
    attr_reader :step, :address, :definition_identity

    def initialize(step)
      raise ScoutException, 'ComputationReference requires a Scout Step' unless Step === step

      @step = step
      # Step#short_path is Scout's canonical Workflow/task/job-label identity.
      # Deliberately do not retain Step#path (an absolute physical location).
      @address = step.short_path.to_s.freeze
      @definition_identity = self.class.definition_identity_for(step)
      freeze
    end

    # Optional definition identity (name/version/digest) is stored in the
    # native producer Step's input metadata. Read it there rather than
    # consulting a live definition that may have changed, and never execute
    # the computation to discover it.
    def self.definition_identity_for(step)
      info = step.info
      names = Array(info[:input_names] || info['input_names']).collect(&:to_s)
      values = info[:inputs] || info['inputs'] || info[:provided_inputs] || info['provided_inputs']
      fields = %w[_cortex_definition _cortex_definition_version _cortex_definition_digest]
      extracted = {}
      fields.each do |field|
        value = if Hash === values
                  values[field] || values[field.to_sym]
                elsif names.include?(field) && values
                  values[names.index(field)]
                end
        extracted[field] = value unless value.nil?
      end
      return nil if extracted.empty?
      identity = {}
      identity['name'] = extracted['_cortex_definition'].to_s if extracted['_cortex_definition']
      identity['version'] = extracted['_cortex_definition_version'].to_i if extracted['_cortex_definition_version']
      identity['digest'] = extracted['_cortex_definition_digest'].to_s if extracted['_cortex_definition_digest']
      identity.freeze
    rescue StandardError
      nil
    end

    def identity
      { 'address' => address, 'definition' => definition_identity }
    end
  end

  class Execution
    attr_reader :computation, :request_context, :parent_execution, :operations

    def initialize(step: nil, computation: nil, request_context: nil, parent_execution: nil)
      if computation.nil?
        raise ScoutException, 'Execution requires a Scout Step or computation reference' if step.nil?
        computation = ComputationReference.new(step)
      elsif !ComputationReference === computation
        raise ScoutException, 'Execution computation must be a Cortex::ComputationReference'
      elsif !step.nil? && !step.equal?(computation.step)
        raise ScoutException, 'Execution step must match its computation reference'
      end

      unless parent_execution.nil? || Execution === parent_execution
        raise ScoutException, 'parent_execution must be a Cortex::Execution'
      end

      @computation = computation
      @request_context = RequestContext.project(
        request_context.nil? ? RequestContext.for_step(computation.step) : request_context
      ).dup.freeze
      @parent_execution = parent_execution
      # Consumer operations belong to one in-memory invocation, not a shared
      # cached computation. This array is intentionally never serialized.
      @operations = []
    end

    # A task callback runs with its exact Scout Step as self. Associate that
    # step with the Execution created by that callback rather than using
    # ambient/global state. A later execution of the same memoized Step gets
    # a fresh Execution and replaces this in-memory pointer.
    def self.begin_task(step)
      execution = new(step: step)
      step.instance_variable_set(:@cortex_current_execution, execution)
      execution
    end

    def self.for_task_step(step)
      step.instance_variable_get(:@cortex_current_execution)
    end

    # This identifies the underlying cached Scout computation, not this
    # Execution instance. Distinct invocations remain distinct Ruby objects.
    def step_identity
      computation.address
    end

    def step
      computation.step
    end

    def record_operation(operation)
      raise ScoutException, 'Operation must belong to this Cortex::Execution' unless
        Operation === operation && operation.execution.equal?(self)

      operations << operation
      operation
    end
  end

  class Operation
    attr_reader :execution, :name, :resource_reference, :computation_reference

    def initialize(execution:, name:, resource_reference: nil, computation_reference: nil)
      raise ScoutException, 'Operation requires an owning Cortex::Execution' unless Execution === execution
      unless resource_reference.nil? || ResourceReference === resource_reference
        raise ScoutException, 'Operation resource_reference must be a Cortex::ResourceReference'
      end
      unless computation_reference.nil? || ComputationReference === computation_reference
        raise ScoutException, 'Operation computation_reference must be a Cortex::ComputationReference'
      end
      name = name.to_s
      raise ScoutException, 'Operation name cannot be empty' if name.empty?

      @execution = execution
      @name = name.freeze
      @resource_reference = resource_reference
      @computation_reference = computation_reference
      freeze
    end

    def computation
      execution.computation
    end

    def to_h
      out = { 'kind' => name, 'execution' => { 'address' => computation.address } }
      out['resource'] = { 'namespace' => resource_reference.namespace,
                          'name' => resource_reference.name,
                          'version' => resource_reference.version,
                          'digest' => resource_reference.digest } if resource_reference
      out['computation'] = computation_reference.identity if computation_reference
      out
    end
  end

  # A logical Cortex address only. Resolving it remains the responsibility of
  # Cortex's existing path-map resolver; no physical path is stored here.
  # Optional version/digest fields qualify a known snapshot/definition without
  # replacing its storage metadata or requiring a resolver lookup.
  class ResourceReference
    attr_reader :namespace, :name, :version, :digest

    def initialize(namespace:, name:, version: nil, digest: nil)
      @namespace = Cortex.validate_namespace!(namespace).to_s.freeze
      @name = Cortex.sanitize_resource_name!(name).freeze
      unless version.nil? || (Integer === version && version.positive?)
        raise ScoutException, 'ResourceReference version must be a positive Integer'
      end
      unless digest.nil? || (String === digest && !digest.empty?)
        raise ScoutException, 'ResourceReference digest must be a non-empty String'
      end
      @version = version
      @digest = digest&.dup&.freeze
      freeze
    end

    def logical_address
      "#{namespace}/#{name}"
    end

    # Stable typed identity; path-map selection and physical location are
    # deliberately excluded. Nil revision fields mean no version was supplied.
    def identity
      [namespace, name, version, digest].freeze
    end
  end
end
