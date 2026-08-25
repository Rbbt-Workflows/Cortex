require 'scout-ai'

module Cortex
  extend Workflow
  self.include_workflow AgentWorkflow

  CORTEX = Scout.var.cortex

  class << self
    def namespace_dir(namespace)
      CORTEX[namespace.to_s].find :current
    end

    def conversation_path(conversation)
      namespace_dir(:conversations)[conversation.to_s].find :current
    end

    def brief_path(brief)
      namespace_dir(:briefs)[brief.to_s].find :current
    end

    def brief_meta_path(brief)
      namespace_dir(:briefs)['.meta']["#{brief}.json"].find :current
    end

    def artifact_path(artifact)
      namespace_dir(:artifacts)[artifact.to_s].find :current
    end

    def namespace_names(namespace)
      dir = namespace_dir(namespace)
      return [] unless File.directory?(dir)
      Dir.glob(File.join(dir.to_s, '*')).
        reject{|f| File.basename(f).start_with?('.') }.
        collect{|f| File.basename f }.sort
    end

    def load_conversation(conversation)
      path = conversation_path conversation
      File.exist?(path) ? Chat.load(path) : Chat.setup([])
    end

    def load_brief(brief)
      path = brief_path brief
      return nil unless File.exist?(path)
      chat = Chat.load path
      chat = nil if chat.respond_to?(:empty?) && chat.empty?
      chat
    end

    def legacy_brief_path(agent, brief)
      legacy = CORTEX[agent.to_s][brief.to_s].find :current
      legacy if File.exist?(legacy)
    end

    def resolve_brief(agent, brief)
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
        messages << "Legacy location found (var/cortex/#{agent}/#{brief}); recreate the brief with brief_agent (workflow Cortex, task brief_agent)."
      end

      others = namespace_names(:briefs).select{|name| load_brief(name) }
      if others.any?
        messages << "Available briefs: #{others * ', '}"
      else
        messages << "No briefs exist yet; create one with brief_agent (workflow Cortex, task brief_agent)."
      end

      raise ScoutException, messages * ' '
    end

    def save_conversation(conversation, prompt, new)
      path = conversation_path conversation
      Open.mkdir File.dirname(path)
      chat = load_conversation conversation
      chat.user prompt
      chat.follow new
      chat.save path
    end

    def save_brief(brief, prompt, new, agent: nil, job: nil)
      path = brief_path brief
      Open.mkdir File.dirname(path)
      chat = load_brief(brief) || Chat.setup([])
      chat.user prompt
      chat.follow new
      chat.save path

      meta_path = brief_meta_path brief
      Open.mkdir File.dirname(meta_path)
      Open.write meta_path, JSON.pretty_generate({
        'agent' => agent.to_s,
        'job' => job.to_s,
        'timestamp' => Time.now.strftime('%Y-%m-%d %H:%M:%S')
      })
    end

    # Single dep-chat builder used by continue_chat (conversations namespace)
    # and brief_agent (fresh brief: prompt only).
    def conversation_prompt_chat(conversation, prompt, namespace: :conversations)
      path = case namespace.to_sym
             when :conversations then conversation_path conversation
             when :briefs then brief_path conversation
             else raise ScoutException, "Unknown Cortex namespace #{namespace}"
             end

      chat = File.exist?(path) ? Chat.load(path) : Chat.setup([])
      chat.user prompt
      chat
    end
  # --- workspace metadata / listing (step 3) ------------------------------

  VALID_TYPES = %w(conversations briefs artifacts).freeze

  def validate_type!(type)
    type = 'all' if type.nil?
    type = type.to_s
    return type if type == 'all' || VALID_TYPES.include?(type)
    raise ScoutException, "Unknown Cortex namespace type #{type.inspect}; valid types: #{VALID_TYPES * ', '} (or 'all')"
  end

  # Chat.load of a file whose first message is empty yields a leading empty
  # separator message; every count/index below drops messages with empty
  # content so listings and indices stay stable.
  def chat_messages(chat)
    chat.select{|m| ! m[:content].to_s.empty? }
  end

  def artifact_names
    dir = namespace_dir(:artifacts)
    return [] unless File.directory?(dir)
    Dir.glob(File.join(dir.to_s, '**', '*')).
      select{|f| File.file?(f) }.
      reject{|f| f.split(File::SEPARATOR).any?{|p| p.start_with?('.') } }.
      collect{|f| f[dir.to_s.length + 1..-1] }.
      sort
  end

  def listing_header(type)
    case type.to_s
    when 'conversations', 'briefs' then ['#name', 'messages', 'bytes', 'mtime']
    when 'artifacts' then ['#name', 'bytes', 'mtime']
    end
  end

  def namespace_listing(type, prefix = nil)
    type = type.to_s
    prefix = prefix.to_s unless prefix.nil?
    case type
    when 'conversations', 'briefs'
      namespace_names(type.to_sym).select{|n| prefix.nil? || n.start_with?(prefix) }.collect do |name|
        path = type == 'conversations' ? conversation_path(name) : brief_path(name)
        next nil unless File.file?(path)
        chat = Chat.load path
        [name, chat_messages(chat).length.to_s, File.size(path).to_s,
         File.mtime(path).strftime('%Y-%m-%d %H:%M')]
      end.compact
    when 'artifacts'
      artifact_names.select{|n| prefix.nil? || n.start_with?(prefix) }.collect do |name|
        path = artifact_path name
        [name, File.size(path).to_s, File.mtime(path).strftime('%Y-%m-%d %H:%M')]
      end
    end
  end

  def listing_tsv(type, prefix = nil)
    header = listing_header(type)
    TSV.setup(header.dup + namespace_listing(type, prefix),
              type: :list, key_field: 'name', fields: header[1..-1],
              namespace: Cortex)
  end

  def listing_text(type, prefix = nil)
    case type.to_s
    when 'all'
      VALID_TYPES.collect do |t|
        rows = namespace_listing(t, prefix)
        "#{t}\t#{rows.length} entr#{rows.length == 1 ? 'y' : 'ies'}\n" +
          (rows.empty? ? "  (none)" : ([listing_header(t)] + rows).collect{|r| '  ' + r * "\t" } * "\n")
      end * "\n" + "\n"
    else
      header = listing_header(type)
      rows = namespace_listing(type, prefix)
      ([header] + rows).collect{|r| r * "\t" } * "\n" + "\n"
    end
  end

  # --- lexical search -----------------------------------------------------

  def search_terms(query)
    query.to_s.downcase.split(/\s+/).reject{|t| t.empty? }
  end

  def matches_query?(down_content, terms)
    return false if terms.empty?
    return true if terms.length == 1 && down_content.include?(terms.first)
    terms.all?{|t| down_content.include?(t) }
  end

  def search_conversations(query, type, limit)
    terms = search_terms query
    out = []
    types = %w(conversations).include?(type) ? [type] : %w(conversations briefs)
    types.each do |t|
      namespace_names(t.to_sym).each do |name|
        path = t == 'conversations' ? conversation_path(name) : brief_path(name)
        next unless File.file?(path)
        chat = Chat.load path
        chat_messages(chat).each_with_index do |m, i|
          content = m[:content].to_s
          next unless matches_query?(content.downcase, terms)
          snippet = content.gsub(/\s+/, ' ').strip[0, 100]
          out << [t, name, "#{i}:#{m[:role]}: #{snippet}"]
          break if out.length >= limit
        end
      end
    end
    out
  end

  def snippet_around(content, idx, window = 200)
    pre = idx < 80 ? 0 : idx - 80
    snip = content[pre, window].to_s
    snip = '...' + snip if pre > 0
    snip = snip + '...' if pre + window < content.length
    snip.gsub(/\s+/, ' ').strip
  end

  def search_artifacts(query, limit)
    terms = search_terms query
    out = []
    artifact_names.each do |name|
      content = Open.read(artifact_path(name)).to_s
      next if content.empty?
      down = content.downcase
      next unless matches_query?(down, terms)
      idx = down.index(terms.first){|t| down.include?(t) } || down.index(terms.first)
      out << ['artifacts', name, snippet_around(content, idx)]
      break if out.length >= limit
    end
    out
  end

  # --- bounded read -------------------------------------------------------

  READ_CAP = 50_000

  def cap_string(text, cap = READ_CAP)
    return text if text.nil? || text.length <= cap
    text[0, cap] + "\n[truncated at #{cap} chars]"
  end

  def conversation_index(chat)
    chat_messages(chat).collect.with_index do |m, i|
      fp = m[:fingerprint].to_s
      fp = Log.truncate_string(m[:content].to_s) if fp.empty?
      "#{i}\t#{m[:role]}\t#{fp}"
    end * "\n"
  end

  def parse_range(range)
    return nil unless range
    a, b = range.to_s.split('-', 2)
    a = a.to_i
    b = b ? b.to_i : a
    raise ScoutException, "Invalid range #{range.inspect}: expected 'a-b' with a <= b" if a < 0 || b < a
    [a, b]
  end

  def conversation_slice(chat, a, b)
    msgs = chat_messages chat
    return '' if msgs.empty?
    # Range start past the end: empty result, never msgs[a..b] == nil
    return '' if a >= msgs.length
    b = msgs.length - 1 if b >= msgs.length
    msgs[a..b].collect{|m| "#{m[:role]}:\n#{m[:content]}" } * "\n\n"
  end

  # --- bounded write ------------------------------------------------------

  def sanitize_artifact_path(path)
    path = path.to_s.strip
    raise ScoutException, 'Artifact path cannot be empty' if path.empty?
    if path.start_with?('/', '~') || path.split(File::SEPARATOR).include?('..') || path.include?("\n") || path.include?("\t")
      shown = Log.truncate_string(path.inspect)
      raise ScoutException, "Invalid artifact path #{shown}: only simple relative paths under var/cortex/artifacts are allowed (no leading '/', no '..' segment, no '~' prefix, no newline or tab)"
    end
    path
  end

  def artifact_history_path(name)
    namespace_dir(:artifacts)['.history'][name].find :current
  end

  def artifact_meta_path(name)
    namespace_dir(:artifacts)['.meta']["#{name}.json"].find :current
  end

  def write_artifact(path, content, mode = :replace, job: nil, agent: nil)
    name = sanitize_artifact_path path
    target = artifact_path name
    Open.mkdir File.dirname(target)

    if File.exist?(target) && mode.to_sym == :replace
      # Per-artifact history dir: .history/<name>/<ts.seq>. The full artifact
      # name (including subdirs) is the directory, so every artifact has its
      # own snapshot sequence and no sibling artifact shares the counter.
      hpath = artifact_history_path name
      Open.mkdir hpath
      seq = Dir.glob(File.join(hpath, '*')).length + 1
      Open.write File.join(hpath, "#{Time.now.strftime('%Y%m%d%H%M%S')}.#{seq}"), Open.read(target)
    end

    content = Open.read(target) + "\n" + content if mode.to_sym == :append && File.exist?(target) && ! Open.read(target).empty?
    Open.write target, content

    mpath = artifact_meta_path name
    Open.mkdir File.dirname(mpath)
    meta = File.exist?(mpath) ? JSON.parse(Open.read(mpath)) : {}
    versions = meta['versions'] || []
    versions << {'job' => job, 'agent' => agent, 'mode' => mode.to_s,
                 'timestamp' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
                 'size' => content.bytesize}
    meta['versions'] = versions
    Open.write mpath, JSON.pretty_generate(meta)

    [name, content.bytesize, versions.length]
  end

  end


  helper :conversation_path do |conversation| Cortex.conversation_path(conversation) end
  helper :brief_path do |brief| Cortex.brief_path(brief) end
  helper :artifact_path do |artifact| Cortex.artifact_path(artifact) end
  helper :namespace_names do |namespace| Cortex.namespace_names(namespace) end
  helper :load_conversation do |conversation| Cortex.load_conversation(conversation) end
  helper :load_brief do |brief| Cortex.load_brief(brief) end
  helper :resolve_brief do |agent, brief| Cortex.resolve_brief(agent, brief) end
  helper :save_conversation do |conversation,prompt,new| Cortex.save_conversation(conversation, prompt, new) end
  helper :save_brief do |brief,prompt,new,**kw| Cortex.save_brief(brief, prompt, new, **kw) end
  helper :validate_type! do |type| Cortex.validate_type!(type) end
  helper :artifact_names do Cortex.artifact_names end
  helper :listing_header do |type| Cortex.listing_header(type) end
  helper :namespace_listing do |type,prefix=nil| Cortex.namespace_listing(type, prefix) end
  helper :listing_tsv do |type,prefix=nil| Cortex.listing_tsv(type, prefix) end
  helper :listing_text do |type,prefix=nil| Cortex.listing_text(type, prefix) end
  helper :search_conversations do |query,type=nil,limit=20| Cortex.search_conversations(query, type, limit) end
  helper :search_artifacts do |query,limit=20| Cortex.search_artifacts(query, limit) end
  helper :conversation_index do |chat| Cortex.conversation_index(chat) end
  helper :conversation_slice do |chat,a,b| Cortex.conversation_slice(chat, a, b) end
  helper :parse_range do |range| Cortex.parse_range(range) end
  helper :sanitize_artifact_path do |path| Cortex.sanitize_artifact_path(path) end
  helper :artifact_history_path do |name| Cortex.artifact_history_path(name) end
  helper :artifact_meta_path do |name| Cortex.artifact_meta_path(name) end
  helper :write_artifact do |path,content,mode=:replace,**kw| Cortex.write_artifact(path, content, mode, **kw) end
  helper :cap_string do |text,cap=Cortex::READ_CAP| Cortex.cap_string(text, cap) end


  helper :load_agent_conversation do |agent_conversation=nil|
    agent = if agent_conversation.nil?
              self.agent nil
            else
              name, _sep, conversation = agent_conversation.partition('/')
              brief = resolve_brief name, conversation if conversation && ! conversation.empty?
              chat = self.chat
              agent = self.agent name, chat: nil
              agent.start_chat.follow brief if brief
              agent
            end
    agent.start_chat.tool 'Cortex'
    agent
  end

  desc <<~EOF
    Continue a named conversation in the Cortex conversations namespace using
    an agent, optionally loading an agent brief from the Cortex briefs
    namespace. Returns a receipt with agent meta pointing at the producing
    job.
  EOF
  input :agent, :string, 'Agent name; optionally Agent/brief_name to load a brief stored in the Cortex briefs namespace (e.g. Worker/math loads brief math for agent Worker)', nil
  chat_task :continue do
    agent_conversation = inputs[:agent]
    agent = load_agent_conversation agent_conversation
    agent.follow chat
    agent
  end

  desc <<~EOF
    Continue a named conversation in the Cortex conversations namespace:
    appends the prompt to conversations/<conversation>, runs the AgentWorkflow
    continue task on it, persists the grown conversation and returns a receipt
    (agent_meta job + answer) only; content stays in the conversation file.
  EOF
  input :conversation, :string, 'Conversation name in the Cortex conversations namespace', nil, required: true
  input :prompt, :text, 'Prompt to continue the conversation', nil, required: true
  dep :continue, chat: :placeholder do |jobname,options|
    conversation, prompt = options.values_at :conversation, :prompt
    {chat: Cortex.conversation_prompt_chat(conversation, prompt, namespace: :conversations)}
  end
  task :continue_chat => :json do |conversation,prompt|
    continue = step(:continue)
    res = continue.load
    save_conversation conversation, prompt, res
    {agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
  end

  desc <<~EOF
    Create or update a brief in the Cortex briefs namespace: briefs/<name> is
    grown with the prompt (a fresh brief starts prompt-only) and saved with a
    .meta sidecar (agent, producing job, timestamp). Use before continue_chat
    when an agent needs a reusable brief.
  EOF
  input :conversation, :string, 'Brief name in the Cortex briefs namespace; it does not need to contain the agent name', nil, required: true
  input :prompt, :text, 'Prompt for the agent that will produce the brief', nil, required: true
  input :agent, :string, 'Agent the brief is for (e.g. Worker); recorded in the briefs .meta sidecar and used to produce the brief', nil, required: true
  dep :continue, chat: :placeholder do |jobname,options|
    conversation, prompt = options.values_at :conversation, :prompt
    {chat: Cortex.conversation_prompt_chat(conversation, prompt, namespace: :briefs)}
  end
  task :brief_agent => :json do |conversation,prompt,agent|
    continue = step(:continue)
    res = continue.load
    save_brief conversation, prompt, res, agent: agent.to_s, job: continue.short_path
    {agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
  end

  desc <<~EOF
    List the Cortex workspace namespaces: metadata only (name, size, mtime;
    message count for conversations/briefs). Dot-dirs (.meta, .history) are
    never listed. Use cortex_read to fetch content, cortex_search to find
    content by keyword.
  EOF
  input :type, :select, "Namespace to list: conversations, briefs, artifacts, or all (three namespaces with counts)", 'all', select_options: %w(conversations briefs artifacts all)
  input :prefix, :string, 'Only names starting with this prefix', nil
  task :cortex_list => :text do |type,prefix|
    type = Cortex.validate_type! type
    listing_text type, prefix
  end

  desc <<~EOF
    Lexical (case-insensitive) search over conversation and brief message
    content plus artifact file contents. Single-term queries use substring
    match; multi-term queries require every term (AND). Returns compact
    matches with short snippets (~200 chars) only, never whole files; raise
    the limit or use cortex_read for more.
  EOF
  input :query, :string, 'Keyword(s) to search for; multiple terms are ANDed', nil, required: true
  input :type, :select, "Restrict search to conversations (covers briefs too), artifacts, or nil for both", nil, select_options: %w(conversations artifacts)
  input :limit, :integer, 'Maximum number of matches to return', 20
  task :cortex_search => :text do |query,type,limit|
    type = type.to_s if type
    limit = 20 if limit.nil? || limit <= 0
    rows = []
    rows += search_conversations(query, type, limit) unless type == 'artifacts'
    rows += search_artifacts(query, limit - rows.length) if type != 'conversations' && rows.length < limit
    if rows.empty?
      "No matches for #{query.inspect}"
    else
      (['#type' + "\t" + 'name' + "\t" + 'match'] + rows.collect{|r| r * "\t" }) * "\n" + "\n"
    end
  end

  desc <<~EOF
    Read from the Cortex workspace with bounded output. For conversations and
    briefs the default is a compact per-message index (role + fingerprint);
    use last or range for message content (capped at 50k chars). Artifacts
    return full content (same cap). Conversation indices exclude empty
    separator messages.
  EOF
  input :name, :string, 'Name of the conversation, brief, or artifact (artifacts may include subdirs, e.g. claims/C42.md)', nil, required: true
  input :type, :select, "Namespace of the item to read", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :last, :integer, 'Trailing N messages of a conversation/brief (full content)', nil
  input :range, :string, 'Inclusive message index range "a-b" (e.g. "0-3") of a conversation/brief', nil
  task :cortex_read => :text do |name,type,last,range|
    type = Cortex.validate_type! type
    raise ScoutException, "Unknown Cortex namespace type #{type.inspect}" if type == 'all'
    case type
    when 'conversations', 'briefs'
      path = type == 'conversations' ? conversation_path(name) : brief_path(name)
      unless File.file?(path)
        raise ScoutException, "No #{type.chomp('s')} named #{name.inspect} in the Cortex #{type} namespace (var/cortex/#{type})"
      end
      chat = Chat.load path
      if last || range
        msgs = Cortex.chat_messages chat
        a, b = Cortex.parse_range range
        if last
          a = [msgs.length - last.to_i, 0].max
          b = msgs.length - 1
        end
        Cortex.cap_string(Cortex.conversation_slice(chat, a, b))
      else
        Cortex.conversation_index(chat)
      end
    when 'artifacts'
      path = artifact_path name
      raise ScoutException, "No artifact named #{name.inspect} under var/cortex/artifacts (list with cortex_list type=artifacts)" unless File.file?(path)
      Cortex.cap_string(Open.read(path))
    end
  end

  desc <<~EOF
    Write or append a durable artifact under var/cortex/artifacts. On
    replace, the previous version is snapshotted to artifacts/.history and a
    version record (job, agent, mode, timestamp, size) is accumulated in
    artifacts/.meta/<name>.json. Conversations are working space; artifacts
    are durable research objects. Extract reusable results as artifacts.
  EOF
  input :path, :string, 'Artifact path relative to var/cortex/artifacts (e.g. claims/C42.md); no absolute paths, no ..', nil, required: true
  input :content, :text, 'Full artifact content to write (mode replace) or append (mode append); never echoed back', nil, required: true
  input :mode, :select, 'replace overwrites (with history snapshot); append adds to the end, creating if absent', 'replace', select_options: %w(replace append)
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_write => :text do |path,content,mode,agent|
    name, size, version = Cortex.write_artifact(path, content, mode, job: self.short_path, agent: agent)
    "Artifact written: #{name} (#{size} bytes, v#{version})"
  end

  export :continue_chat, :brief_agent, :cortex_list, :cortex_search, :cortex_read, :cortex_write
end
