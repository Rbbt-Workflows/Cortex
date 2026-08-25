require 'scout-ai'

module Cortex
  extend Workflow
  self.include_workflow AgentWorkflow

  # ------------------------------------------------------------------
  # Storage abstraction: namespace x logical name x path map
  # ------------------------------------------------------------------
  #
  # Every Cortex resource is (namespace, logical name, path map). Writes go
  # to CORTEX_WRITE_MAP; reads/searches resolve across CORTEX_READ_MAPS in
  # order. :lib and :current currently resolve to the same directory from
  # the repository checkout (see research/reference-scout-paths.md), so
  # existing data needs no migration, but the maps are kept distinct so the
  # semantics are explicit and future-proof.

  CORTEX = Scout.var.cortex

  def self.write_map
    map = Scout::Config.get('cortex', 'write_map', default: :lib)
    map.to_sym
  end

  def self.read_maps
    maps = Scout::Config.get('cortex', 'read_maps', default: [:lib, :current])
    maps = [maps] unless Array === maps
    maps.collect(&:to_sym)
  end

  def self.map_tag(map, maps = nil)
    maps ||= read_maps
    maps.length > 1 ? ":#{map}" : ''
  end

  def self.namespace_dir(namespace, path_map = nil)
    path_map ||= write_map
    CORTEX[namespace.to_s].find path_map.to_sym
  end

  # Validate a logical resource name for any namespace. Nested relative
  # paths are legal everywhere; absolute paths, ~, '..' segments, and
  # control characters are not.
  def self.sanitize_resource_name!(name)
    name = name.to_s.strip
    raise ScoutException, 'Cortex resource name cannot be empty' if name.empty?
    if name.start_with?('/', '~') || name.split(File::SEPARATOR).include?('..') || name.include?("\n") || name.include?("\t")
      shown = Log.truncate_string(name.inspect)
      raise ScoutException, "Invalid Cortex resource name #{shown}: use simple relative paths (no leading '/', no '..' segment, no '~' prefix, no newline or tab)"
    end
    name
  end

  def self.resource_path(namespace, name, path_map = nil)
    name = sanitize_resource_name! name
    File.join(namespace_dir(namespace, path_map), name)
  end

  def self.resource_paths(namespace, name, maps = nil)
    maps ||= read_maps
    maps.collect { |map| [resource_path(namespace, name, map), map] }.
      # Two maps may resolve to the same physical directory (e.g. :lib and
      # :current in a checkout without a separate lib tree): that is one
      # resource, not an ambiguity. Dedupe by physical path, first map wins.
      uniq { |path, _map| path }
  end

  def self.resource_exists?(namespace, name, maps = nil)
    resource_paths(namespace, name, maps).any? { |path, _map| File.exist?(path) }
  end

  # Resolve a resource across the readable path maps, first hit wins.
  # Returns [path, map, all_paths] where all_paths lists every physical
  # location that exists (used to report cross-map ambiguity).
  def self.resolve_resource(namespace, name, maps = nil)
    found = resource_paths(namespace, name, maps).select { |path, _map| File.exist?(path) }
    return nil if found.empty?
    [found.first.first, found.first.last, found.collect(&:first)]
  end

  # Sidecar stores that travel with their resource on rename/move.
  def self.sidecar_paths(namespace, name, path_map)
    base = namespace_dir(namespace, path_map)
    case namespace.to_sym
    when :artifacts then [File.join(base, '.meta', "#{name}.json"), File.join(base, '.history', name)]
    when :briefs then [File.join(base, '.meta', "#{name}.json")]
    when :conversations then []
    else raise ScoutException, "Unknown Cortex namespace #{namespace}"
    end
  end

  def self.existing_sidecars(namespace, name, path_map)
    sidecar_paths(namespace, name, path_map).select { |p| File.exist?(p) }
  end

  # Recursive enumeration of logical names in a namespace under one map.
  # Dot-directories (.meta, .history) are excluded at every level.
  def self.namespace_names(namespace, path_map = nil)
    dir = namespace_dir(namespace, path_map)
    return [] unless File.directory?(dir)
    Dir.glob(File.join(dir.to_s, '**', '*')).
      select { |f| File.file?(f) }.
      reject { |f| f.split(File::SEPARATOR).any? { |p| p.start_with?('.') } }.
      collect { |f| f[dir.to_s.length + 1..-1] }.
      sort
  end

  # All (name, map, path) entries across the readable maps.
  def self.namespace_entries(namespace, maps = nil)
    maps ||= read_maps
    out = []
    maps.each do |map|
      namespace_names(namespace, map).each do |name|
        path = resource_path(namespace, name, map)
        out << [name, map, path] unless out.any? { |n, _m, p| n == name && p == path }
      end
    end
    out
  end

  # Names present in more than one readable map: listing/search tag these
  # with their map so the ambiguity stays visible.
  def self.ambiguous_names(namespace, maps = nil)
    candidates = namespace_entries(namespace, maps).collect(&:first).uniq
    candidates.select do |name|
      resource_paths(namespace, name, maps).
        select { |path, _map| File.exist?(path) }.
        collect(&:first).uniq.length > 1
    end
  end

  # --- namespace-specific convenience accessors -----------------------

  def self.conversation_path(conversation)
    resource_path :conversations, conversation, :current
  end

  def self.brief_path(brief)
    resource_path :briefs, brief, :current
  end

  def self.brief_meta_path(brief)
    sidecar_paths(:briefs, brief, :current).first
  end

  def self.artifact_path(artifact)
    resource_path :artifacts, artifact, :current
  end

  def self.artifact_history_path(name)
    sidecar_paths(:artifacts, name, :current)[1]
  end

  def self.artifact_meta_path(name)
    sidecar_paths(:artifacts, name, :current)[0]
  end

  def self.load_conversation(conversation)
    path = conversation_path conversation
    File.exist?(path) ? Chat.load(path) : Chat.setup([])
  end

  def self.load_brief(brief)
    path = brief_path brief
    return nil unless File.exist?(path)
    chat = Chat.load path
    chat = nil if chat.respond_to?(:empty?) && chat.empty?
    chat
  end

  def self.legacy_brief_path(agent, brief)
    legacy = CORTEX[agent.to_s][brief.to_s].find :current
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

  def self.save_conversation(conversation, prompt, new)
    path = conversation_path conversation
    Open.mkdir File.dirname(path)
    chat = load_conversation conversation
    chat.user prompt
    chat.follow new
    chat.save path
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

  # Single dep-chat builder used by cortex_continue (conversations
  # namespace) and cortex_brief (fresh brief: prompt only).
  def self.conversation_prompt_chat(conversation, prompt, namespace: :conversations)
    path = resource_path namespace, conversation, :current
    chat = File.exist?(path) ? Chat.load(path) : Chat.setup([])
    chat.user prompt
    chat
  end

  # ------------------------------------------------------------------
  # Workspace metadata, listing, pagination
  # ------------------------------------------------------------------

  VALID_TYPES = %w(conversations briefs artifacts).freeze

  def self.validate_type!(type)
    type = 'all' if type.nil?
    type = type.to_s
    return type if type == 'all' || VALID_TYPES.include?(type)
    raise ScoutException, "Unknown Cortex namespace type #{type.inspect}; valid types: #{VALID_TYPES * ', '} (or 'all')"
  end

  # Chat.load of a file whose first message is empty yields a leading empty
  # separator message; every count/index below drops messages with empty
  # content so listings and indices stay stable.
  def self.chat_messages(chat)
    chat.select { |m| !m[:content].to_s.empty? }
  end

  DEFAULT_LIST_LIMIT = 50

  def self.listing_header(type)
    case type.to_s
    when 'conversations', 'briefs' then ['#name', 'messages', 'bytes', 'mtime']
    when 'artifacts' then ['#name', 'bytes', 'mtime']
    end
  end

  def self.namespace_listing(type, prefix = nil)
    type = type.to_s
    prefix = prefix.to_s unless prefix.nil?
    ambiguous = ambiguous_names(type.to_sym)
    case type
    when 'conversations', 'briefs'
      namespace_entries(type.to_sym).
        select { |name, _map, _path| prefix.nil? || name.start_with?(prefix) }.
        collect do |name, map, path|
          next nil unless File.file?(path)
          chat = Chat.load path
          tag = map_tag map
          [name + tag, chat_messages(chat).length.to_s, File.size(path).to_s,
           File.mtime(path).strftime('%Y-%m-%d %H:%M')]
        end.compact
    when 'artifacts'
      namespace_entries(:artifacts).
        select { |name, _map, _path| prefix.nil? || name.start_with?(prefix) }.
        collect do |name, map, path|
          next nil unless File.file?(path)
          tag = map_tag map
          [name + tag, File.size(path).to_s, File.mtime(path).strftime('%Y-%m-%d %H:%M')]
        end.compact
    end
  end

  def self.paginate_rows(rows, offset, limit)
    offset = offset.to_i
    limit = limit.to_i
    limit = DEFAULT_LIST_LIMIT if limit.nil? || limit <= 0
    total = rows.length
    last_idx = [offset + limit, total].min - 1
    page = last_idx < [offset, total].min ? [] : rows[[offset, total].min..last_idx]
    next_offset = offset + page.length
    next_offset = nil if next_offset >= total
    [page, total, next_offset]
  end

  def self.paginated_section(type, prefix, offset, limit)
    rows = namespace_listing(type, prefix)
    page, total, next_offset = paginate_rows(rows, offset, limit)
    header = listing_header(type)
    lines = ["#{type}\t#{page.length}/#{total} entr#{total == 1 ? 'y' : 'ies'}"]
    if page.empty?
      lines << '  (none)'
    else
      lines += ([header] + page).collect { |r| '  ' + r * "\t" }
    end
    lines << "  more: next_offset=#{next_offset}" if next_offset
    lines * "\n"
  end

  def self.listing_text(type, prefix = nil, offset = 0, limit = DEFAULT_LIST_LIMIT)
    if type == 'all'
      VALID_TYPES.collect { |t| paginated_section(t, prefix, offset, limit) } * "\n" + "\n"
    else
      paginated_section(type, prefix, offset, limit) + "\n"
    end
  end

  # ------------------------------------------------------------------
  # Lexical search (all readable path maps)
  # ------------------------------------------------------------------

  def self.search_terms(query)
    query.to_s.downcase.split(/\s+/).reject { |t| t.empty? }
  end

  def self.matches_query?(down_content, terms)
    return false if terms.empty?
    return true if terms.length == 1 && down_content.include?(terms.first)
    terms.all? { |t| down_content.include?(t) }
  end

  def self.search_conversations(query, type, limit)
    terms = search_terms query
    ambiguous = ambiguous_names(type.to_sym)
    out = []
    namespace_entries(type.to_sym).each do |name, map, path|
      next unless File.file?(path)
      tag = ambiguous.include?(name) ? map_tag(map) : ''
      chat = Chat.load path
      chat_messages(chat).each_with_index do |m, i|
        content = m[:content].to_s
        next unless matches_query?(content.downcase, terms)
        snippet = content.gsub(/\s+/, ' ').strip[0, 100]
        out << [type, name + tag, "#{i}:#{m[:role]}: #{snippet}"]
        break if out.length >= limit
      end
      break if out.length >= limit
    end
    out
  end

  def self.snippet_around(content, idx, window = 200)
    pre = idx < 80 ? 0 : idx - 80
    snip = content[pre, window].to_s
    snip = '...' + snip if pre > 0
    snip = snip + '...' if pre + window < content.length
    snip.gsub(/\s+/, ' ').strip
  end

  def self.search_artifacts(query, limit)
    terms = search_terms query
    ambiguous = ambiguous_names(:artifacts)
    out = []
    namespace_entries(:artifacts).each do |name, map, path|
      next unless File.file?(path)
      tag = ambiguous.include?(name) ? map_tag(map) : ''
      content = Open.read(path).to_s
      next if content.empty?
      down = content.downcase
      next unless matches_query?(down, terms)
      idx = down.index(terms.first) { |t| down.include?(t) } || down.index(terms.first)
      out << ['artifacts', name + tag, snippet_around(content, idx)]
      break if out.length >= limit
    end
    out
  end

  # ------------------------------------------------------------------
  # Bounded read
  # ------------------------------------------------------------------

  READ_CAP = 50_000
  DEFAULT_READ_LINES = 200

  def self.cap_string(text, cap = READ_CAP)
    return text if text.nil? || text.length <= cap
    text[0, cap] + "\n[truncated at #{cap} chars]"
  end

  def self.conversation_index(chat)
    chat_messages(chat).collect.with_index do |m, i|
      fp = m[:fingerprint].to_s
      fp = Log.truncate_string(m[:content].to_s) if fp.empty?
      "#{i}\t#{m[:role]}\t#{fp}"
    end * "\n"
  end

  def self.parse_range(range)
    return nil unless range
    a, b = range.to_s.split('-', 2)
    a = a.to_i
    b = b ? b.to_i : a
    raise ScoutException, "Invalid range #{range.inspect}: expected 'a-b' with a <= b" if a < 0 || b < a
    [a, b]
  end

  def self.conversation_slice(chat, a, b)
    msgs = chat_messages chat
    return '' if msgs.empty?
    # Range start past the end: empty result, never msgs[a..b] == nil
    return '' if a >= msgs.length
    b = msgs.length - 1 if b >= msgs.length
    msgs[a..b].collect { |m| "#{m[:role]}:\n#{m[:content]}" } * "\n\n"
  end

  # Line-based pagination for text artifacts. Returns [text, meta-lines].
  def self.artifact_page(path, start_line, lines)
    content = Open.read(path).to_s
    all_lines = content.split("\n", -1)
    total = all_lines.length
    start_line = 1 if start_line.nil?
    start_line = start_line.to_i
    lines = DEFAULT_READ_LINES if lines.nil? || lines.to_i <= 0
    lines = lines.to_i
    raise ScoutException, "Artifact has #{total} lines; start_line #{start_line} is past the end" if start_line > total
    a = start_line
    b = [start_line + lines - 1, total].min
    page = all_lines[(a - 1)...b] || []
    next_line = b + 1
    next_line = nil if next_line > total
    header = "# lines #{a}-#{b} of #{total}" + (next_line ? " (next: #{next_line})" : ' (end)')
    [page * "\n", [header]]
  end

  def self.read_conversation(name, type, last, range)
    path, map, all_paths = resolve_resource(type.to_sym, name)
    unless path
      raise ScoutException, "No #{type.chomp('s')} named #{name.inspect} in the Cortex #{type} namespace (var/cortex/#{type})"
    end
    chat = Chat.load path
    out = []
    if all_paths.length > 1
      out << "[note] #{name} exists in more than one path map; using :#{map} (#{all_paths * ' | '})"
    end
    if last || range
      msgs = chat_messages chat
      a, b = parse_range range
      if last
        a = [msgs.length - last.to_i, 0].max
        b = msgs.length - 1
      end
      out << cap_string(conversation_slice(chat, a, b))
    else
      out << conversation_index(chat)
    end
    out * "\n"
  end

  def self.read_artifact(name, start_line, lines)
    path, map, all_paths = resolve_resource(:artifacts, name)
    unless path
      raise ScoutException, "No artifact named #{name.inspect} under var/cortex/artifacts (list with cortex_list type=artifacts)"
    end
    out = []
    if all_paths.length > 1
      out << "[note] #{name} exists in more than one path map; using :#{map} (#{all_paths * ' | '})"
    end
    text, meta = artifact_page(path, start_line, lines)
    out += meta
    out << cap_string(text)
    out * "\n"
  end

  # ------------------------------------------------------------------
  # Artifact write with provenance + version history
  # ------------------------------------------------------------------

  def self.write_artifact(path, content, mode = :replace, job: nil, agent: nil, map: nil)
    name = sanitize_resource_name! path
    map ||= write_map
    target = resource_path :artifacts, name, map
    Open.mkdir File.dirname(target)

    if File.exist?(target) && mode.to_sym == :replace
      # Per-artifact history dir: .history/<name>/<ts.seq>. The full artifact
      # name (including subdirs) is the directory, so every artifact has its
      # own snapshot sequence and no sibling artifact shares the counter.
      hpath = sidecar_paths(:artifacts, name, map)[1]
      Open.mkdir hpath
      seq = Dir.glob(File.join(hpath, '*')).length + 1
      Open.write File.join(hpath, "#{Time.now.strftime('%Y%m%d%H%M%S')}.#{seq}"), Open.read(target)
    end

    content = Open.read(target) + "\n" + content if mode.to_sym == :append && File.exist?(target) && !Open.read(target).empty?
    Open.write target, content

    mpath = sidecar_paths(:artifacts, name, map)[0]
    Open.mkdir File.dirname(mpath)
    meta = File.exist?(mpath) ? JSON.parse(Open.read(mpath)) : {}
    versions = meta['versions'] || []
    versions << { 'job' => job, 'agent' => agent, 'mode' => mode.to_s,
                  'map' => map.to_s,
                  'timestamp' => Time.now.strftime('%Y-%m-%d %H:%M:%S'),
                  'size' => content.bytesize }
    meta['versions'] = versions
    Open.write mpath, JSON.pretty_generate(meta)

    [name, content.bytesize, versions.length]
  end

  # ------------------------------------------------------------------
  # Edit / rename / remove / move: single resource-management layer
  # ------------------------------------------------------------------

  def self.edit_artifact(name, find, replace, all: false, job: nil, agent: nil)
    raise ScoutException, 'find cannot be empty' if find.nil? || find.empty?
    raise ScoutException, 'replace must be a string' unless replace.is_a?(String)
    path, map, all_paths = resolve_resource :artifacts, name
    raise ScoutException, "No artifact named #{name.inspect} under var/cortex/artifacts" unless path

    content = Open.read path
    # NOTE: build an explicit Regexp; String#scan with a plain String is not
    # reliable in this environment (scout-essentials patches String).
    occurrences = content.scan(Regexp.new(Regexp.escape(find))).length
    raise ScoutException, "Cannot edit #{name.inspect}: text not found: #{Log.truncate_string(find.inspect)}" if occurrences == 0
    if occurrences > 1 && !all
      raise ScoutException, "Cannot edit #{name.inspect}: #{find.inspect} occurs #{occurrences} times; pass all=true to replace every occurrence"
    end

    new_content = all ? content.gsub(find, replace) : content.sub(find, replace)
    # Reuse the write path so history snapshots and version records behave
    # identically for edits and full replacements.
    _n, size, version = write_artifact name, new_content, :replace, job: job, agent: agent, map: map
    note = all_paths.length > 1 ? " [note] #{name} exists in more than one path map; edited :#{map}" : ''
    "Artifact edited: #{name} (#{occurrences} occurrence#{occurrences == 1 ? '' : 's'} replaced, #{size} bytes, v#{version})#{note}"
  end

  def self.remove_resource(namespace, name, job: nil)
    namespace = namespace.to_sym
    path, map, = resolve_resource namespace, name
    raise ScoutException, "No #{namespace.to_s.chomp('s')} named #{name.inspect} in the Cortex #{namespace} namespace" unless path

    removed = [path] + existing_sidecars(namespace, name, map)
    removed.each { |p| Open.rm_rf p }

    # Prune now-empty parent dirs up to (excluding) the namespace root.
    base = namespace_dir(namespace, map)
    dir = File.dirname(path)
    while dir.start_with?(base.to_s) && dir != base.to_s
      break unless Dir.glob(File.join(dir, '*')).reject { |f| File.basename(f).start_with?('.') }.empty?
      Dir.rmdir dir rescue nil
      dir = File.dirname(dir)
    end
    removed
  end

  def self.rename_resource(namespace, name, new_name, job: nil, agent: nil)
    namespace = namespace.to_sym
    sanitize_resource_name! new_name
    path, map, = resolve_resource namespace, name
    raise ScoutException, "No #{namespace.to_s.chomp('s')} named #{name.inspect} in the Cortex #{namespace} namespace" unless path
    raise ScoutException, "Rename target #{new_name.inspect} already exists in the Cortex #{namespace} namespace" if resource_exists?(namespace, new_name)

    target = resource_path namespace, new_name, map
    Open.mkdir File.dirname(target)
    FileUtils.mv path, target

    # Move sidecars (meta + history) with the resource.
    s_path = sidecar_paths(namespace, name, map)[0]
    if File.exist?(s_path)
      t_side = sidecar_paths(namespace, new_name, map)[0]
      Open.mkdir File.dirname(t_side)
      FileUtils.mv s_path, t_side
    end
    h_path = sidecar_paths(namespace, name, map)[1]
    if h_path && File.exist?(h_path)
      t_side = sidecar_paths(namespace, new_name, map)[1]
      Open.mkdir File.dirname(t_side)
      FileUtils.mv h_path, t_side
    end

    if namespace == :artifacts
      mpath = sidecar_paths(namespace, new_name, map)[0]
      meta = File.exist?(mpath) ? JSON.parse(Open.read(mpath)) : {}
      versions = meta['versions'] || []
      versions << { 'job' => job, 'agent' => agent, 'mode' => 'rename',
                    'renamed_from' => name,
                    'timestamp' => Time.now.strftime('%Y-%m-%d %H:%M:%S') }
      meta['versions'] = versions
      Open.write mpath, JSON.pretty_generate(meta)
    end

    # Prune empty dirs left by the source.
    base = namespace_dir(namespace, map)
    dir = File.dirname(path)
    while dir.start_with?(base.to_s) && dir != base.to_s
      break unless Dir.glob(File.join(dir, '*')).reject { |f| File.basename(f).start_with?('.') }.empty?
      Dir.rmdir dir rescue nil
      dir = File.dirname(dir)
    end

    "Renamed: #{name} -> #{new_name} (:#{map})"
  end

  def self.move_resource(namespace, name, to_map, job: nil, agent: nil)
    namespace = namespace.to_sym
    to_map = to_map.to_sym
    path, map, = resolve_resource namespace, name
    raise ScoutException, "No #{namespace.to_s.chomp('s')} named #{name.inspect} in the Cortex #{namespace} namespace" unless path
    target = resource_path namespace, name, to_map
    if to_map == map || target == path
      # Maps can resolve to the same physical directory (:lib and :current do
      # in a checkout without a separate lib tree): the resource is already
      # there; treat as a no-op move rather than an error or a self-clobber.
      return "Moved: #{name} (:#{map} -> :#{to_map} resolve to the same location; no-op)"
    end
    raise ScoutException, "Move target already exists in :#{to_map}: #{target}" if File.exist?(target)

    Open.mkdir File.dirname(target)
    FileUtils.mv path, target

    existing_sidecars(namespace, name, map).each do |s_path|
      idx = sidecar_paths(namespace, name, map).index(s_path)
      t_side = sidecar_paths(namespace, name, to_map)[idx]
      Open.mkdir File.dirname(t_side)
      FileUtils.mv s_path, t_side
    end

    if namespace == :artifacts
      mpath = sidecar_paths(namespace, name, to_map)[0]
      if File.exist?(mpath)
        meta = JSON.parse(Open.read(mpath))
        versions = meta['versions'] || []
        versions << { 'job' => job, 'agent' => agent, 'mode' => 'move',
                      'from' => map.to_s, 'to' => to_map.to_s,
                      'timestamp' => Time.now.strftime('%Y-%m-%d %H:%M:%S') }
        meta['versions'] = versions
        Open.write mpath, JSON.pretty_generate(meta)
      end
    end

    # Prune empty dirs left by the source.
    base = namespace_dir(namespace, map)
    dir = File.dirname(path)
    while dir.start_with?(base.to_s) && dir != base.to_s
      break unless Dir.glob(File.join(dir, '*')).reject { |f| File.basename(f).start_with?('.') }.empty?
      Dir.rmdir dir rescue nil
      dir = File.dirname(dir)
    end

    "Moved: #{name} from :#{map} to :#{to_map}"
  end

  # ------------------------------------------------------------------
  # Workflow helpers
  # ------------------------------------------------------------------

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
  helper :namespace_listing do |type,prefix=nil| Cortex.namespace_listing(type, prefix) end
  helper :listing_text do |type,prefix=nil,offset=0,limit=nil| Cortex.listing_text(type, prefix, offset, limit) end
  helper :search_conversations do |query,type=nil,limit=20| Cortex.search_conversations(query, type, limit) end
  helper :search_artifacts do |query,limit=20| Cortex.search_artifacts(query, limit) end
  helper :conversation_index do |chat| Cortex.conversation_index(chat) end
  helper :conversation_slice do |chat,a,b| Cortex.conversation_slice(chat, a, b) end
  helper :parse_range do |range| Cortex.parse_range(range) end
  helper :cap_string do |text,cap=Cortex::READ_CAP| Cortex.cap_string(text, cap) end
  helper :write_artifact do |path,content,mode=:replace,**kw| Cortex.write_artifact(path, content, mode, **kw) end

  helper :load_agent_conversation do |agent_conversation=nil|
    agent = if agent_conversation.nil?
              self.agent nil
            else
              name, _sep, conversation = agent_conversation.partition('/')
              brief = resolve_brief name, conversation if conversation && !conversation.empty?
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

  # ------------------------------------------------------------------
  # Canonical conversation/brief tools (+ legacy aliases at the bottom)
  # ------------------------------------------------------------------

  desc <<~EOF
    Continue a named research conversation in the Cortex conversations
    namespace: appends the prompt to conversations/<conversation>, runs the
    AgentWorkflow continue task on it, persists the grown conversation and
    returns a receipt (agent_meta job + answer) only; content stays in the
    conversation file.
  EOF
  input :conversation, :string, 'Conversation name in the Cortex conversations namespace', nil, required: true
  input :prompt, :text, 'Prompt to continue the conversation', nil, required: true
  dep :continue, chat: :placeholder do |jobname,options|
    conversation, prompt = options.values_at :conversation, :prompt
    {chat: Cortex.conversation_prompt_chat(conversation, prompt, namespace: :conversations)}
  end
  task :cortex_continue => :json do |conversation,prompt|
    continue = step(:continue)
    res = continue.load
    save_conversation conversation, prompt, res
    {agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
  end

  desc <<~EOF
    Create or update a brief in the Cortex briefs namespace: briefs/<name> is
    grown with the prompt (a fresh brief starts prompt-only) and saved with a
    .meta sidecar (agent, producing job, timestamp). Use before cortex_continue
    when an agent needs a reusable brief.
  EOF
  input :conversation, :string, 'Brief name in the Cortex briefs namespace; it does not need to contain the agent name', nil, required: true
  input :prompt, :text, 'Prompt for the agent that will produce the brief', nil, required: true
  input :agent, :string, 'Agent the brief is for (e.g. Worker); recorded in the briefs .meta sidecar and used to produce the brief', nil, required: true
  dep :continue, chat: :placeholder do |jobname,options|
    conversation, prompt = options.values_at :conversation, :prompt
    {chat: Cortex.conversation_prompt_chat(conversation, prompt, namespace: :briefs)}
  end
  task :cortex_brief => :json do |conversation,prompt,agent|
    continue = step(:continue)
    res = continue.load
    save_brief conversation, prompt, res, agent: agent.to_s, job: continue.short_path
    {agent_meta: [{role: :meta, content: Chat.serialize_meta({job: continue.short_path})}], content: res.answer}
  end

  # ------------------------------------------------------------------
  # Workspace exploration tools
  # ------------------------------------------------------------------

  desc <<~EOF
    List the Cortex workspace namespaces: metadata only (name, size, mtime;
    message count for conversations/briefs). Dot-dirs (.meta, .history) are
    never listed. Names present in more than one readable path map are
    tagged with their map. Supports offset/limit pagination; the footer
    reports total entries and the next offset when more exist. Use
    cortex_read to fetch content, cortex_search to find content by keyword.
  EOF
  input :type, :select, "Namespace to list: conversations, briefs, artifacts, or all (three namespaces with counts)", 'all', select_options: %w(conversations briefs artifacts all)
  input :prefix, :string, 'Only names starting with this prefix', nil
  input :offset, :integer, 'Skip the first N entries (pagination)', 0
  input :limit, :integer, 'Maximum entries per page', 50
  task :cortex_list => :text do |type,prefix,offset,limit|
    type = Cortex.validate_type! type
    listing_text type, prefix, offset, limit
  end

  desc <<~EOF
    Lexical (case-insensitive) search over conversation and brief message
    content plus artifact file contents, across all readable path maps.
    Single-term queries use substring match; multi-term queries require
    every term (AND). Returns compact matches with short snippets (~200
    chars) only, never whole files; hits whose name exists in more than one
    path map carry the map tag. Raise the limit or use cortex_read for more.
  EOF
  input :query, :string, 'Keyword(s) to search for; multiple terms are ANDed', nil, required: true
  input :type, :select, "Restrict search: conversations, briefs, artifacts, or all", 'all', select_options: %w(conversations briefs artifacts all)
  input :limit, :integer, 'Maximum number of matches to return', 20
  task :cortex_search => :text do |query,type,limit|
    type = Cortex.validate_type! type
    type = nil if type == 'all'
    limit = 20 if limit.nil? || limit <= 0
    rows = []
    unless type == 'artifacts'
      rows += search_conversations(query, 'conversations', limit)
      rows += search_conversations(query, 'briefs', limit - rows.length) if !type && rows.length < limit
    end
    rows += search_artifacts(query, limit - rows.length) if type != 'conversations' && rows.length < limit
    if rows.empty?
      "No matches for #{query.inspect}"
    else
      (['#type' + "\t" + 'name' + "\t" + 'match'] + rows.collect { |r| r * "\t" }) * "\n" + "\n"
    end
  end

  desc <<~EOF
    Read from the Cortex workspace with bounded output. For conversations and
    briefs the default is a compact per-message index (role + fingerprint);
    use last or range for message content (capped at 50k chars). Artifacts
    are read with line-based pagination (start_line + lines; default 200
    lines per page, same 50k cap); the header reports the returned range,
    total lines, and the next start line. Conversation indices exclude
    empty separator messages. Resources found in more than one path map
    resolve to the first readable map and report the ambiguity.
  EOF
  input :name, :string, 'Name of the conversation, brief, or artifact (artifacts may include subdirs, e.g. claims/C42.md)', nil, required: true
  input :type, :select, "Namespace of the item to read", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :last, :integer, 'Trailing N messages of a conversation/brief (full content)', nil
  input :range, :string, 'Inclusive message index range "a-b" (e.g. "0-3") of a conversation/brief', nil
  input :start_line, :integer, 'First line to return for artifacts (1-based)', 1
  input :lines, :integer, 'Maximum lines per artifact page', 200
  task :cortex_read => :text do |name,type,last,range,start_line,lines|
    type = Cortex.validate_type! type
    raise ScoutException, "Unknown Cortex namespace type #{type.inspect}" if type == 'all'
    case type
    when 'conversations', 'briefs'
      Cortex.read_conversation(name, type, last, range)
    when 'artifacts'
      start_line = 1 if start_line.nil? || start_line < 1
      Cortex.read_artifact(name, start_line, lines)
    end
  end

  desc <<~EOF
    Write or append a durable artifact under var/cortex/artifacts. On
    replace, the previous version is snapshotted to artifacts/.history and a
    version record (job, agent, mode, map, timestamp, size) is accumulated
    in artifacts/.meta/<name>.json. Conversations are working space;
    artifacts are durable research objects. Extract reusable results as
    artifacts.
  EOF
  input :path, :string, 'Artifact path relative to var/cortex/artifacts (e.g. claims/C42.md); no absolute paths, no ..', nil, required: true
  input :content, :text, 'Full artifact content to write (mode replace) or append (mode append); never echoed back', nil, required: true
  input :mode, :select, 'replace overwrites (with history snapshot); append adds to the end, creating if absent', 'replace', select_options: %w(replace append)
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_write => :text do |path,content,mode,agent|
    name, size, version = Cortex.write_artifact(path, content, mode, job: self.short_path, agent: agent)
    "Artifact written: #{name} (#{size} bytes, v#{version})"
  end

  desc <<~EOF
    Make a targeted, exact text edit to an existing artifact: every
    occurrence of find (or the single occurrence, unless all=true) is
    replaced by replace. Fails rather than guessing when find is missing or
    ambiguous. The previous version is snapshotted to .history and a
    version record (mode 'edit') is appended to .meta, exactly like
    cortex_write replace. Do not resend whole artifacts for small fixes;
    use this tool.
  EOF
  input :name, :string, 'Artifact path relative to var/cortex/artifacts', nil, required: true
  input :find, :text, 'Exact text to find in the artifact', nil, required: true
  input :replace, :text, 'Replacement text', nil, required: true
  input :all, :boolean, 'Replace every occurrence (required when find matches more than once)', false
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_edit => :text do |name,find,replace,all,agent|
    Cortex.edit_artifact(name, find, replace, all: all, job: self.short_path, agent: agent)
  end

  desc <<~EOF
    Rename a resource (conversation, brief, or artifact) without changing its
    path map. Artifacts and briefs take their sidecar metadata and history
    along, so provenance and prior versions stay attached; artifact .meta
    gets a version record (mode 'rename'). The target name must not already
    exist. Use only for deliberate workspace management.
  EOF
  input :type, :select, "Namespace of the resource to rename", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :name, :string, 'Current logical name', nil, required: true
  input :new_name, :string, 'New logical name', nil, required: true
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_rename => :text do |type,name,new_name,agent|
    Cortex.rename_resource(type, name, new_name, job: self.short_path, agent: agent)
  end

  desc <<~EOF
    Remove a resource (conversation, brief, or artifact) explicitly. For
    artifacts and briefs the associated .meta metadata and .history
    snapshots are removed together, so no orphaned provenance is left
    behind. The namespace is required; there is no implicit delete-anything.
    This is irreversible; use only for deliberate workspace management.
  EOF
  input :type, :select, "Namespace of the resource to remove", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :name, :string, 'Logical name to remove', nil, required: true
  task :cortex_remove => :text do |type,name|
    removed = Cortex.remove_resource(type, name, job: self.short_path)
    "Removed: #{removed.length} item#{removed.length == 1 ? '' : 's'} (#{removed.collect { |p| Log.truncate_string(p, 60) } * ', '})"
  end

  desc <<~EOF
    Move a resource (conversation, brief, or artifact) between path maps
    (e.g. :current -> :lib) keeping its logical name, following resource
    sync semantics: content, .meta metadata, and .history snapshots travel
    together as one logical object; the source disappears. Artifact .meta
    gets a version record (mode 'move') with from/to maps. The target must
    not already exist.
  EOF
  input :type, :select, "Namespace of the resource to move", nil, {select_options: %w(conversations briefs artifacts), required: true, jobname: true}
  input :name, :string, 'Logical name to move', nil, required: true
  input :to, :select, 'Target path map', nil, {select_options: %w(lib current), required: true}
  input :agent, :string, 'Optional agent name recorded in the .meta version entry', nil
  task :cortex_move => :text do |type,name,to,agent|
    Cortex.move_resource(type, name, to, job: self.short_path, agent: agent)
  end

  # ------------------------------------------------------------------
  # Compatibility aliases: continue_chat -> cortex_continue,
  # brief_agent -> cortex_brief. Same inputs, same receipts.
  # ------------------------------------------------------------------
  task_alias :continue_chat, Cortex, :cortex_continue
  task_alias :brief_agent, Cortex, :cortex_brief

  export :cortex_continue, :cortex_brief, :continue_chat, :brief_agent,
         :cortex_list, :cortex_search, :cortex_read, :cortex_write,
         :cortex_edit, :cortex_rename, :cortex_remove, :cortex_move
end
