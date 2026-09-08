# frozen_string_literal: true

# Support for the `scout cortex` subcommand suite (the scripts in
# share/scout_commands/cortex/).
#
# Every script follows the standard scout command template
# (config/templates/scout_command):
#
#   #!/usr/bin/env ruby
#   require 'scout'
#
#   $0 = "scout #{$previous_commands.any? ? ... : ''}#{File.basename(__FILE__)}" if $previous_commands
#   cmd = $0
#
#   options = SOPT.setup <<~EOF
#
#     <summary>
#
#     $ #{cmd} [<options>] <positional> ...
#
#     -h--help Print this help
#     -s--short* <input description>   (one line per task input)
#     ...
#     EOF
#   if options[:help]
#     if defined? scout_usage
#       scout_usage
#     else
#       puts SOPT.doc
#     end
#     exit 0
#   end
#
#   <locals> = IndiferentHash.process_options options, :<locals>
#   <positional> = ARGV.shift if <positional>.nil?
#
#   raise MissingParameterException, :<input> if <input>.nil?
#
#   options[:<input>] = <input>
#
#   raise ParameterException, "Extra positional arguments: ..." unless ARGV.empty?
#
#   Cortex::CLI.dispatch 'cortex_<task>', options
#
# The whole SOPT.setup payload (summary, "$ cmd" synopsis, one option line
# per input with its documentation) and the template tail are *generated*
# from the Cortex workflow task declarations by
# `Cortex::CLI.generate_script` (run through
# share/scout_commands/cortex/generate). The task documentation IS the
# command documentation; the inputs are added programmatically.
#
# Two details of the generated tail fix the option/positional mixing bug:
#
# * locals are seeded from the parsed options (`process_options`), not
#   left nil, so an input given as `--type artifacts` is present in the
#   local and the MissingParameterException check passes;
# * positionals bind SEQUENTIALLY from the remaining ARGV (`ARGV.shift`),
#   not by fixed index, so `read --name X artifacts` binds `type` from
#   ARGV[0] correctly (SOPT.consume already removed every `--option value`
#   pair from ARGV, so what is left is exactly the positional stream).
#
# Every option line carries a short form (`-l--limit*`), allocated by
# `allocate_shorts` from the input names, with `h` reserved for help.

require 'scout'

module Cortex
  module CLI
    # Preferred shorts for common inputs; they win over the automatic
    # first-letter allocation.
    RESERVED_SHORTS = {
      'type' => 't',
      'name' => 'n',
      'entity' => 'e',
      'entity_type' => 'et',
      'property' => 'p',
      'query' => 'q'
    }.freeze

    # Positional parameters per task, in binding order; a positional binds
    # the next remaining ARGV entry after option consumption.
    POSITIONALS = {
      'cortex_list' => %w[type prefix],
      'cortex_search' => %w[query type],
      'cortex_read' => %w[name type],
      'cortex_write' => %w[path content],
      'cortex_edit' => %w[name find replace],
      'cortex_rename' => %w[name new_name],
      'cortex_remove' => %w[name type],
      'cortex_move' => %w[name to],
      'cortex_continue' => %w[conversation prompt],
      'cortex_brief' => %w[conversation prompt],
      'cortex_write_list' => %w[entity_type list entities],
      'cortex_read_list' => %w[entity_type list],
      'cortex_property_list' => %w[entity_type prefix],
      'cortex_property_read' => %w[entity_type property],
      'cortex_property_history' => %w[entity_type property],
      'cortex_property_validate' => %w[entity_type property],
      'cortex_property_define' => %w[entity_type property],
      'cortex_property_update' => %w[entity_type property],
      'cortex_property_remove' => %w[entity_type property],
      'cortex_entity_property' => %w[entity_type property entity list],
      'cortex_activity' => %w[entity_type entity]
    }.freeze

    # Summary line of each command (the title of SOPT.doc).
    SUMMARIES = {
      'cortex_task' => 'Run any Cortex workflow task by name',
      'cortex_list' => 'List workspace namespaces with metadata only',
      'cortex_read' => 'Read conversations, briefs, or artifacts',
      'cortex_search' => 'Lexically search conversation, brief, and artifact contents',
      'cortex_activity' => 'Report accumulated workspace activity around ONE entity',
      'cortex_write' => 'Write or append a durable artifact',
      'cortex_edit' => 'Make a targeted, exact text edit to an existing artifact',
      'cortex_rename' => 'Rename a workspace resource in place',
      'cortex_move' => 'Move a workspace resource between path maps',
      'cortex_remove' => 'Remove a workspace resource (irreversible)',
      'cortex_continue' => 'Append a turn to a named conversation, optionally through a briefed agent',
      'cortex_brief' => 'Create or refresh a reusable agent brief (prompt plus optional tooling)',
      'cortex_write_list' => 'Write or replace a named entity list',
      'cortex_read_list' => 'Read the entity ids (and optional meta) of a named entity list',
      'cortex_property_list' => 'List entity property definitions',
      'cortex_property_read' => 'Read a property definition body',
      'cortex_property_history' => 'Show the version history of a property definition',
      'cortex_property_validate' => 'Validate a candidate property definition (with optional smoke run)',
      'cortex_property_define' => 'Define (create) a new executable entity property',
      'cortex_property_update' => 'Update an existing property definition',
      'cortex_property_remove' => 'Remove a property definition (history is kept)',
      'cortex_entity_property' => 'Run a property for one entity or a named list, with a job receipt'
    }.freeze

    # Inputs declared :array but documented as JSON payloads must never be
    # comma-split (cortex_brief's tools).
    JSON_ARRAY_INPUTS = %w[tools].freeze

    class << self
      def repo_root
        @repo_root ||= File.dirname(File.dirname(File.dirname(File.realpath(__FILE__))))
      end

      def load_workflow!
        return Cortex if defined?(Cortex) && Cortex.respond_to?(:tasks) && !Cortex.tasks.empty?

        $LOAD_PATH.unshift File.join(repo_root, 'lib') unless $LOAD_PATH.include?(File.join(repo_root, 'lib'))
        require File.join(repo_root, 'workflow.rb')

        # ScoutCoder: Workflow.require_workflow 'Cortex' cannot be used from a
        # checkout that is not a discovery map member: outside its own PWD it
        # tries a GitHub autoinstall of Scout-Workflows/cortex.git (which does
        # not exist) instead of using this checkout. Load workflow.rb by path.
        Cortex
      end

      # recursive_inputs may declare the same name twice (cortex_brief
      # declares `agent` itself and inherits `agent` from the scaffold
      # through export_scaffold). NamedArray#uniq dedups whole tuples, not
      # names, so deduplicate by name here, first occurrence winning.
      def input_tuples(task)
        seen = []
        out = []
        task.recursive_inputs.each do |name, type, description, default, options|
          next if seen.include?(name.to_s)
          seen << name.to_s
          out << [name.to_s, type, description, default, options || {}]
        end
        out
      end

      def positionals_for(task_name)
        POSITIONALS[task_name.to_s]
      end

      def summary_for(task_name)
        SUMMARIES[task_name.to_s] || "Run the Cortex task #{task_name}"
      end

      # ----------------------------------------------------------------
      # Short option allocation: every input gets one, 'h' stays with help
      # ----------------------------------------------------------------

      # Deterministic short option per input of a task. Starts from the
      # reserved short or the first letter; on collision extends with the
      # subsequent letters of the input name (skipping separators), the
      # same disambiguation strategy SOPT.fix_shortcut uses. Multi-char
      # shorts are legal (-jn--jobname in scout's own workflow command).
      def allocate_shorts(task)
        taken = ['h']
        result = {}
        input_tuples(task).each do |name, _t, _d, _df, _o|
          name = name.to_s
          candidate = RESERVED_SHORTS[name] || name[0]
          rest = name.chars
          rest.shift if candidate == name[0]
          while taken.include?(candidate)
            c = rest.shift
            c = rest.shift while c && !c.match?(/[a-zA-Z0-9]/)
            break if c.nil?
            candidate = candidate + c
          end
          taken << candidate
          result[name] = candidate
        end
        result
      end

      # ----------------------------------------------------------------
      # Script generation (standard scout command template)
      # ----------------------------------------------------------------

      # The SOPT.setup option lines of a command, straight from the task
      # input declarations: short form, long form, '*' for value inputs,
      # and the documented description.
      def option_lines_for(task_name)
        task = load_workflow!.tasks[task_name.to_sym]
        raise ParameterException, "Unknown Cortex task '#{task_name}'" if task.nil?

        shorts = allocate_shorts(task)
        lines = ['-h--help Print this help']
        input_tuples(task).each do |name, type, description, _default, _options|
          line = "-#{shorts[name]}--#{name}"
          line << '*' unless type == :boolean
          desc = description.to_s.gsub(/\s+/, ' ').strip
          lines << "#{line} #{desc}"
        end
        lines
      end

      # Guard against interpolation/heredoc-hostile content in
      # descriptions when the lines are embedded in the generated script.
      def heredoc_escape(text)
        text.gsub('\\', '\\\\\\\\').gsub('#{', '\\#{')
      end

      # Full text of one dedicated subcommand script, following the
      # standard scout command template.
      def generate_script(task_name)
        task = load_workflow!.tasks[task_name.to_sym]
        raise ParameterException, "Unknown Cortex task '#{task_name}'" if task.nil?

        script_name = task_name.to_s.sub('cortex_', '')
        summary = summary_for(task_name)
        positionals = positionals_for(task_name) || []
        tuples = input_tuples(task)
        required = tuples.select { |_n, _t, _d, _df, o| o[:required] }.collect(&:first)

        # synopsis with positionals, required ones bare
        pos_str = positionals.collect { |p| required.include?(p) ? "<#{p}>" : "[<#{p}>]" } * ' '
        pos_str = pos_str.empty? ? '' : " #{pos_str}"

        # option lines, indented inside the SOPT.setup heredoc
        options_block = option_lines_for(task_name).collect { |l| "  #{heredoc_escape(l)}" } * "\n"

        # locals extracted in the template tail: positionals in binding
        # order, then required non-positional inputs
        locals = positionals + (required - positionals)
        extract = locals.empty? ? '' :
          "#{locals * ', '} = IndiferentHash.process_options options, #{locals.collect { |l| ":#{l}" } * ', '}"
        bind_lines = positionals.collect { |p| "#{p} = ARGV.shift if #{p}.nil?" }
        raise_lines = required.collect { |n| "raise MissingParameterException, :#{n} if #{n}.nil?" }
        merge_lines = locals.collect { |l| "options[:#{l}] = #{l}" }

        <<~SCRIPT
          #!/usr/bin/env ruby
          # frozen_string_literal: true

          # scout cortex #{script_name} -- #{summary}

          require 'scout'

          require_relative '../../../lib/Cortex/cli'

          $0 = "scout \#{$previous_commands.any? ? "\#{$previous_commands * ' '} " : ''}\#{File.basename(__FILE__)}" if $previous_commands
          cmd = $0

          options = SOPT.setup <<~EOF

            #{heredoc_escape(summary)}

            $ \#{cmd} [<options>]#{pos_str}

          #{options_block}
          EOF
          if options[:help]
            if defined? scout_usage
              scout_usage
            else
              puts SOPT.doc
            end
            exit 0
          end

          #{extract}

          #{bind_lines.join("\n")}

          #{raise_lines.join("\n")}

          #{merge_lines.join("\n")}

          raise ParameterException, "Extra positional arguments: \#{ARGV * ' '}" unless ARGV.empty?

          Cortex::CLI.dispatch '#{task_name}', options
        SCRIPT
      end

      # ----------------------------------------------------------------
      # Template tail execution: options + positionals -> task inputs
      # ----------------------------------------------------------------

      # Merge parsed options with positional ARGV entries into the final
      # task inputs hash, applying the scout input conventions. The
      # generated scripts seed the locals from `options` and shift the
      # positionals out of ARGV themselves before calling dispatch, so
      # this normally only re-validates; the positional zip is kept so
      # direct callers (tests, `scout cortex task`) work unchanged.
      def build_inputs(task_name, options, argv = [])
        task = load_workflow!.tasks[task_name.to_sym]
        raise ParameterException, "Unknown Cortex task '#{task_name}'" if task.nil?

        tuples = input_tuples(task)
        names = tuples.collect(&:first)

        values = IndiferentHash.process_options(options, *names.collect(&:to_sym))
        inputs = IndiferentHash.setup({})
        names.zip(values).each { |name, value| inputs[name] = value unless value.nil? }

        # Positional binding mirrors the generated template tail: an input
        # already given as an option does not consume an ARGV slot, so the
        # free positionals bind the remaining argv in order.
        pos_names = positionals_for(task_name) || []
        free = pos_names.reject { |n| inputs.include?(n) }
        raise ParameterException,
              "Extra positional arguments: #{argv * ' '}" if argv.length > free.length
        free.zip(argv).each do |name, value|
          inputs[name] = value unless value.nil?
        end

        # JSON-array inputs are documented as JSON payloads and must not be
        # comma-split.
        tuples.each do |name, type, _d, _df, _o|
          next unless type == :array && JSON_ARRAY_INPUTS.include?(name) && String === inputs[name]
          begin
            inputs[name] = JSON.parse(inputs[name])
          rescue JSON::ParserError
            raise ParameterException, "Input #{name} must be a JSON array of strings: #{inputs[name]}"
          end
        end

        # Other :array inputs follow the scout convention: comma-split
        # unless the value is an existing file.
        tuples.each do |name, type, _d, _df, _o|
          next unless type == :array && !JSON_ARRAY_INPUTS.include?(name) && String === inputs[name]
          inputs[name] = inputs[name].split(',') unless Open.exist?(inputs[name])
        end

        tuples.each do |name, _t, _d, _df, options|
          next unless options[:required]
          raise MissingParameterException, name.to_sym if inputs[name].nil?
        end

        inputs
      end

      def dispatch(task_name, options, argv = ARGV)
        run(task_name.to_s, build_inputs(task_name, options, argv))
      end

      def run(task_name, inputs)
        wf = load_workflow!
        job = wf.job(task_name.to_sym, nil, inputs)
        puts job.exec
      end

      # ----------------------------------------------------------------
      # `scout cortex task <name>` passthrough: load the dedicated
      # subcommand script, mirroring how `scout workflow cmd` descends into
      # subcommand directories. The loaded script re-runs the standard
      # template with the target task's own options.
      # ----------------------------------------------------------------

      def normalize_task_name(name)
        n = name.to_s
        n.start_with?('cortex_') ? n : "cortex_#{n}"
      end

      def load_command(name, from_file)
        name = name.to_s.sub(/^cortex_/, '')
        dir = File.dirname(File.realpath(from_file))
        script = File.join(dir, name)
        unless File.file?(script)
          known = Dir.children(dir).sort.reject { |f| File.directory?(File.join(dir, f)) }
          raise ParameterException, "Unknown Cortex task '#{name}'. Known tasks: #{known * ', '}"
        end
        $previous_commands << 'task' if $previous_commands
        load script
      end
    end
  end
end
