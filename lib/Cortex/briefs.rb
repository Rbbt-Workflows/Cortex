require_relative 'storage'
require 'shellwords'

# ==========================================================================
# Cortex briefs: agent briefs namespace (chat file + .meta sidecar)
# ==========================================================================
#
# A brief is a chat file under briefs/ plus a JSON .meta sidecar recording
# which agent it belongs to and which job produced it. Resolution follows
# the unified mechanism (CORTEX[ns][name].find across all configured maps);
# a missing brief raises with actionable guidance (legacy locations,
# available briefs).

module Cortex

  # Grammar of one tool spec, mirrored from scout-ai's `tool:` message
  # processing (chat/process/tools.rb): `Workflow [task [inputs...]]`.
  # The spec strings are pasted VERBATIM into the brief body; scout-ai
  # parses them (Shellwords) at continue time.  Validation here is syntax
  # only: a workflow absent at brief time may be installed by continue
  # time, and unknown workflows make scout-ai attempt a network install,
  # so existence is never checked here.
  TOOL_SPEC_GRAMMAR = '"Workflow [task [input|name=value ...]]", e.g. ' \
                      '"ScoutCoder help_workflow", "Boolean trap_spaces network cft=default", "Baking"'

  def self.brief_path(brief)
    resource_path :briefs, brief, write_map
  end

  def self.brief_meta_path(brief)
    sidecar_paths(:briefs, brief, write_map).first
  end

  def self.load_brief(brief)
    path, = resolve_resource(:briefs, brief)
    return nil unless path
    chat = Chat.load path
    chat = nil if chat.respond_to?(:empty?) && chat.empty?
    chat
  end

  def self.legacy_brief_path(agent, brief)
    # Historical location var/cortex/<Agent>/<brief>: addressed through the
    # same mechanism (a non-namespaced toplevel) and only reported, never
    # silently used.
    legacy = CORTEX[agent.to_s][brief.to_s]
    legacy = legacy.find
    legacy if File.exist?(legacy)
  end

  def self.resolve_brief(agent, brief)
    return nil if brief.nil? || brief.empty?
    chat = load_brief brief
    return chat if chat

    agent = agent.to_s
    brief = brief.to_s
    messages = ["No brief #{brief} for agent #{agent}."]

    if resolve_resource(:conversations, brief)
      messages << "A conversation named #{brief} exists in the conversations namespace; conversations are not briefs."
    end

    if legacy_brief_path(agent, brief)
      messages << "Legacy location found (var/cortex/#{agent}/#{brief}); recreate the brief with cortex_brief (workflow Cortex, task cortex_brief)."
    end

    others = namespace_names(:briefs, write_map).select { |name| load_brief(name) }
    if others.any?
      messages << "Available briefs: #{others * ', '}"
    else
      messages << "No briefs exist yet; create one with cortex_brief (workflow Cortex, task cortex_brief)."
    end

    raise ScoutException, messages * ' '
  end

  # ------------------------------------------------------------------
  # Tool provisioning: `tools` specs persisted in the brief body
  # ------------------------------------------------------------------
  #
  # A tool spec is `Workflow [task [input|name=value ...]]`.  The specs are
  # pasted VERBATIM into the brief body as `tool:` (+ `introduce:`) chat
  # messages; scout-ai parses them (Shellwords) when the briefed agent
  # runs, so provisioning is resolved at continue time, not at brief time.

  # True when the spec names a whole workflow (no task token).
  def self.whole_workflow_spec?(tokens)
    tokens.length == 1
  end

  # Validate one tool spec and return its tokens.  Syntax ONLY: grammar
  # shape, never workflow/task existence.  A workflow may be absent at
  # brief time and installed by continue time, and an unknown workflow
  # makes scout-ai attempt a network install, so existence checks here
  # would be wrong, not just expensive.
  def self.validate_tool_spec(spec)
    if spec.to_s.strip.empty?
      raise ScoutException, "Invalid tool spec #{spec.inspect}: a tool spec must be a non-empty string. Tool specs follow the grammar #{TOOL_SPEC_GRAMMAR}."
    end

    tokens = Shellwords.split(spec)
    workflow = tokens.first
    unless workflow =~ /\A[\w.:-]+\z/
      raise ScoutException, "Invalid tool spec #{spec.inspect}: first token (workflow name) must be an identifier, got #{workflow.inspect}. Tool specs follow the grammar #{TOOL_SPEC_GRAMMAR}."
    end
    return tokens if whole_workflow_spec?(tokens)

    task = tokens[1]
    unless task =~ /\A[\w.:-]+\z/
      raise ScoutException, "Invalid tool spec #{spec.inspect}: second token (task name) must be an identifier, got #{task.inspect}. Tool specs follow the grammar #{TOOL_SPEC_GRAMMAR}."
    end

    inputs = tokens[2..-1]
    %w[noinputs none].each do |reserved|
      if inputs.include?(reserved) && inputs.length > 1
        raise ScoutException, "Invalid tool spec #{spec.inspect}: '#{reserved}' may only appear as the sole input token (it exposes the task with no inputs). Tool specs follow the grammar #{TOOL_SPEC_GRAMMAR}."
      end
    end
    inputs.each do |token|
      name = token.split('=', 2).first # name=value or the bare token
      next if token.include?('=') && name =~ /\A[\w.:-]+\z/ # name=value (value may be empty, any content)
      next if !token.include?('=') && token =~ /\A[\w.:-]+\z/ # bare input name
      raise ScoutException, "Invalid tool spec #{spec.inspect}: input token #{token.inspect} is neither a bare input name nor a name=value assignment. Tool specs follow the grammar #{TOOL_SPEC_GRAMMAR}."
    end
    tokens
  end

  # Dep chat for cortex_brief: the existing brief (with whatever tooling it
  # already carries) plus the new prompt turn.  Given `tools`, the specs are
  # also pasted into the dep chat (side-channel `tool:` roles, compiled away
  # by scout-ai) so the brief-producing agent sees them; the replace/strip/
  # keep block persisted in the brief file is save_brief's job below.
  def self.brief_prompt_chat(brief, prompt, tools = nil)
    chat = load_conversation_or_brief(brief, :briefs)
    tools.each{|t| chat.tool t } if Array === tools
    chat.user prompt
    chat
  end

  # Expand tool specs, in array order, into the message block persisted at
  # the top of the brief body (Chat builder API, never string surgery):
  # - whole-workflow spec -> `introduce:` (documentation) then `tool:`
  #   (one tool per workflow task);
  # - task-level spec -> a single `tool:` line, verbatim.
  def self.tool_messages(tools)
    block = Chat.setup([])
    Array(tools).each do |spec|
      tokens = validate_tool_spec spec
      if whole_workflow_spec?(tokens)
        block.introduce tokens.first
        block.tool tokens.first
      else
        block.tool tokens.join(' ')
      end
    end
    block
  end

  # Copy of the brief chat with every tooling role removed.  Returns a
  # copy: replace semantics rewrite the brief through save only.
  def self.strip_brief_tooling(chat)
    copy = Chat.setup(chat.collect { |m| IndiferentHash.setup(m.dup) })
    %w(tool introduce kb mcp).each { |role| copy.remove_role(role) }
    copy
  end

  def self.save_brief(brief, prompt, new, agent: nil, job: nil, tools: nil)
    path = brief_path brief
    Open.mkdir File.dirname(path)
    chat = load_brief(brief) || Chat.setup([])
    if tools
      # Replace semantics: tools given -> ALL existing tool:/introduce:
      # (and kb:/mcp:) messages are stripped and the new block is inserted
      # at the top.  tools == [] strips all tooling.  tools omitted (nil)
      # leaves the brief's tooling untouched (keep).
      block = tool_messages tools
      chat = strip_brief_tooling chat
      chat.prepend block unless block.empty?
    end
    chat.user prompt
    chat.follow new
    chat.save path

    meta_path = brief_meta_path brief
    Open.mkdir File.dirname(meta_path)
    meta = File.exist?(meta_path) ? JSON.parse(Open.read(meta_path)) : {}
    meta['agent'] = agent.to_s
    meta['job'] = job.to_s
    meta['timestamp'] = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Open.write meta_path, JSON.pretty_generate(meta)
  end

end
