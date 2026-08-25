require 'Cortex/entities'

module Cortex

  input :entity, :string, 'Entity identity', nil, required: true
  input :entity_type, :json, 'Entity options', nil, required: true
  input :property, :string, 'Entity property', nil, required: true
  input :entity_options, :json, 'Entity options', nil
  input :property_arguments, :json, 'Entity options', nil
  input :update_property, :boolean, 'Update property job', false
  task :entity_property => :json do |entity,entity_type,property,entity_options,arguments,update_property|
    entity_type = Cortex.entity_module(entity_type)
    Cortex.update_entity_module(entity_type)
    entity = entity_type.setup(entity.dup, entity_options || {})
    if update_property
      entity.job(property, *arguments).clean.run
    else
      entity.send(property, *arguments)
    end
  end
end
