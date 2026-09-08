# frozen_string_literal: true

# Unit tests for the `scout cortex` CLI helper (lib/Cortex/cli.rb):
# option table construction, short-option allocation, positional
# binding and the build_inputs path. End-to-end behaviour of the
# installed subcommands (share/scout_commands/cortex/*) is exercised
# separately by tmp/run-smoke.sh against a real `scout` binary.

require File.expand_path(__FILE__).sub(%r{/test/.*}, '/test/test_helper.rb')

require 'Cortex/cli'

class TestCortexCLI < Test::Unit::TestCase

  # -- table-driven generation ------------------------------------------

  def test_reserved_shorts_are_registered_first_and_win
    task = Cortex::CLI.load_workflow!.tasks[:cortex_property_read]
    shorts = Cortex::CLI.allocate_shorts(task)
    assert_equal 'et', shorts['entity_type']
    assert_equal 'p',  shorts['property']
  end

  def test_shorts_do_not_collide_across_the_family
    Cortex::CLI::POSITIONALS.each_key do |task_name|
      task = Cortex::CLI.load_workflow!.tasks[task_name.to_sym] || next
      shorts = Cortex::CLI.allocate_shorts(task)
      shorts['help'] = 'h'
      values = shorts.values
      assert_equal values.uniq.size, values.size,
                   "short option collision in #{task_name}: #{shorts.inspect}"
    end
  end

  def test_input_tuples_dedup_by_name
    task = Cortex::CLI.load_workflow!.tasks[:cortex_brief]
    names = Cortex::CLI.input_tuples(task).collect(&:first)
    assert_equal names.uniq.size, names.size
  end

  def test_positionals_match_declared_inputs
    Cortex::CLI::POSITIONALS.each do |task_name, positionals|
      task = Cortex::CLI.load_workflow!.tasks[task_name.to_sym]
      assert_not_nil task, "#{task_name} is not a Cortex task"
      inputs = Cortex::CLI.input_tuples(task).collect(&:first)
      positionals.each do |p|
        assert_include inputs, p,
                       "#{task_name} positional #{p} is not a declared input"
      end
    end
  end

  def test_positionals_cover_every_documented_task
    dedicated = Dir[File.join(Cortex::CLI.repo_root, 'share', 'scout_commands',
                              'cortex', '*')].collect { |f| File.basename(f) } -
                %w[task generate]
    covered = Cortex::CLI::POSITIONALS.keys.collect { |t| t.sub('cortex_', '') }
    assert_empty (dedicated - covered).sort,
                 'dedicated subcommands without a positional table entry'
  end

  def test_generated_scripts_are_up_to_date
    Cortex::CLI::POSITIONALS.keys.sort.each do |task_name|
      script = File.join(Cortex::CLI.repo_root, 'share', 'scout_commands',
                         'cortex', task_name.sub('cortex_', ''))
      assert_equal Cortex::CLI.generate_script(task_name), File.read(script),
                   "#{task_name} script is stale: run " \
                   'share/scout_commands/cortex/generate'
    end
  end

  def test_generated_scripts_give_every_option_a_short
    Cortex::CLI::POSITIONALS.keys.each do |task_name|
      script = File.join(Cortex::CLI.repo_root, 'share', 'scout_commands',
                         'cortex', task_name.sub('cortex_', ''))
      opt_lines = File.read(script).lines.select { |l| l =~ /^\s+-[a-zA-Z0-9]+--/ }
      assert_not_empty opt_lines, task_name
      opt_lines.each do |l|
        assert_match(/\A\s+-[a-zA-Z0-9]+--[a-z_]+/, l,
                     "#{task_name}: option line lacks a short form: #{l.strip}")
      end
    end
  end

  # -- template tail: options + positionals -> inputs --------------------

  # The generated template tail does the binding in Ruby inside the script;
  # build_inputs still supports the argv form for direct callers.

  def test_build_inputs_option_only_fills_required
    options = IndiferentHash.setup('name' => 'claims/C42.md', 'type' => 'artifacts')
    inputs = Cortex::CLI.build_inputs('cortex_read', options, [])
    assert_equal 'artifacts', inputs[:type]
    assert_equal 'claims/C42.md', inputs[:name]
  end

  def test_build_inputs_positionals_bind_in_order
    inputs = Cortex::CLI.build_inputs('cortex_read', {}, ['claims/C42.md', 'artifacts'])
    assert_equal 'claims/C42.md', inputs[:name]
    assert_equal 'artifacts', inputs[:type]
  end

  def test_build_inputs_rejects_extra_positionals
    assert_raise(ParameterException) do
      Cortex::CLI.build_inputs('cortex_read', { 'name' => 'a', 'type' => 'b' }, ['extra'])
    end
  end

  def test_build_inputs_keeps_required_check
    assert_raise(MissingParameterException) do
      Cortex::CLI.build_inputs('cortex_read', {}, [])
    end
  end

  def test_build_inputs_json_array_tools_intact
    options = IndiferentHash.setup(
      'conversation' => 'n', 'prompt' => 'p', 'agent' => 'Worker',
      'tools' => '["ScoutCoder help_workflow", "Baking"]'
    )
    inputs = Cortex::CLI.build_inputs('cortex_brief', options, [])
    assert_equal ['ScoutCoder help_workflow', 'Baking'], inputs[:tools]
    assert_kind_of Array, inputs[:tools]
  end

  def test_build_inputs_tools_rejects_invalid_json
    options = IndiferentHash.setup(
      'conversation' => 'n', 'prompt' => 'p',
      'tools' => 'nope{'
    )
    assert_raise(ParameterException) do
      Cortex::CLI.build_inputs('cortex_brief', options, [])
    end
  end

  def test_build_inputs_option_wins_over_positional
    options = IndiferentHash.setup('type' => 'artifacts')
    inputs = Cortex::CLI.build_inputs('cortex_read', options, ['claims/C42.md'])
    assert_equal 'artifacts', inputs[:type]
    assert_equal 'claims/C42.md', inputs[:name]
  end

  # -- misc --------------------------------------------------------------

  def test_normalize_task_name
    assert_equal 'cortex_search', Cortex::CLI.normalize_task_name('search')
    assert_equal 'cortex_search', Cortex::CLI.normalize_task_name('cortex_search')
  end

  def test_summaries_match_dedicated_subcommand_headers
    Cortex::CLI::SUMMARIES.each do |task_name, summary|
      next if task_name == 'cortex_task'
      script = File.join(Cortex::CLI.repo_root, 'share', 'scout_commands',
                         'cortex', task_name.sub('cortex_', ''))
      assert_include File.read(script), summary,
                     "#{task_name} script header diverges from SUMMARIES"
    end
  end
end
