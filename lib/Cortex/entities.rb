require 'scout'
module Cortex

  def self.entity_module(type)
    mod = begin
            Kernel.const_get type
          rescue
            mod = Module.new
            mod.extend Entity
            mod.extend EntityWorkflow
            mod.entity_name = type
            mod.name = type
            mod
          end

    mod
  end

  def self.update_entity_module(mod)
    mod.entity_task :test_dep do
        entity.reverse
    end

    mod.dep :test_dep
    mod.entity_task :test do
      step(:test_dep).load.upcase
    end
  end
end
