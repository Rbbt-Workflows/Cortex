require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/test_helper.rb')
require File.expand_path(__FILE__).sub(%r(.*/test/), '').sub(/test_(.*)\.rb/,'\1')

class TestCortexEntities < Test::Unit::TestCase
  def test_load
    mod = Cortex.entity_module('Gene')
    Cortex.update_entity_module(mod)
    
    sss 0
    g = mod.setup('Tp53')
    assert_equal '35PT', g.test
  end
end

