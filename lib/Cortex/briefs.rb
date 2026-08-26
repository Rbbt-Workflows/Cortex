require_relative 'storage'

# ==========================================================================
# Cortex briefs: agent briefs namespace (chat file + .meta sidecar)
# ==========================================================================
#
# A brief is a chat file under briefs/ plus a JSON .meta sidecar recording
# which agent it belongs to and which job produced it. Resolution follows
# the readable maps; a missing brief raises with actionable guidance
# (legacy locations, available briefs).

module Cortex

  def self.brief_path(brief)
    resource_path :briefs, brief, default_local_map
  end

  def self.brief_meta_path(brief)
    sidecar_paths(:briefs, brief, default_local_map).first
  end

  def self.load_brief(brief)
    path = brief_path brief
    return nil unless File.exist?(path)
    chat = Chat.load path
    chat = nil if chat.respond_to?(:empty?) && chat.empty?
    chat
  end

  def self.legacy_brief_path(agent, brief)
    legacy = CORTEX[agent.to_s][brief.to_s].find default_local_map
    legacy if File.exist?(legacy)
  end

  def self.resolve_brief(agent, brief)
    return nil if brief.nil? || brief.empty?
    chat = load_brief brief
    return chat if chat

    agent = agent.to_s
    brief = brief.to_s
    messages = ["No brief #{brief} for agent #{agent}."]

    if File.exist?(conversation_path(brief))
      messages << "A conversation named #{brief} exists in the conversations namespace; conversations are not briefs."
    end

    if legacy_brief_path(agent, brief)
      messages << "Legacy location found (var/cortex/#{agent}/#{brief}); recreate the brief with cortex_brief (workflow Cortex, task cortex_brief)."
    end

    others = namespace_names(:briefs).select { |name| load_brief(name) }
    if others.any?
      messages << "Available briefs: #{others * ', '}"
    else
      messages << "No briefs exist yet; create one with cortex_brief (workflow Cortex, task cortex_brief)."
    end

    raise ScoutException, messages * ' '
  end

  def self.save_brief(brief, prompt, new, agent: nil, job: nil)
    path = brief_path brief
    Open.mkdir File.dirname(path)
    chat = load_brief(brief) || Chat.setup([])
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
