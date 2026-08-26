require_relative 'storage'

# ==========================================================================
# Cortex listing / search / bounded read
# ==========================================================================
#
# Presentation + bounded-read layer over the storage abstraction: namespace
# listings with pagination, lexical search across all readable maps, and
# capped reads of conversations and artifacts. No task lives here.

module Cortex

  # 'entities' is an engine-managed namespace (lib/Cortex/entities.rb) and
  # 'lists' is lib/Cortex/lists.rb; both are addressable through the same
  # storage helpers, but entity lifecycle is driven by
  # Cortex.define_property / update_property / remove_property.
  VALID_TYPES = NAMESPACES.dup.freeze

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
    when 'entities' then ['#name', 'version', 'digest', 'type', 'mtime']
    when 'lists' then ['#name', 'entities', 'mtime']
    end
  end

  def self.namespace_listing(type, prefix = nil)
    type = type.to_s
    prefix = prefix.to_s unless prefix.nil?
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
    when 'artifacts', 'lists'
      namespace_entries(type.to_sym).
        select { |name, _map, _path| prefix.nil? || name.start_with?(prefix) }.
        collect do |name, map, path|
          next nil unless File.file?(path)
          tag = map_tag map
          count = type == 'lists' ? Open.read(path).to_s.split("\n").collect(&:strip).reject(&:empty?).length.to_s : nil
          row = [name + tag]
          row << count if count
          row << File.size(path).to_s
          row << File.mtime(path).strftime('%Y-%m-%d %H:%M')
          row
        end.compact
    when 'entities'
      # Group by entity type; each row is one property definition
      # (Type/property).  Meta is the source of truth for version/digest.
      require 'json'
      namespace_entries(:entities).
        select { |name, _map, _path| prefix.nil? || name.start_with?(prefix) }.
        collect do |name, map, path|
          next nil unless File.file?(path)
          meta_path = File.join(namespace_dir(:entities, map), '.meta',
                                *name.split(File::SEPARATOR)[0..-2],
                                "#{File.basename(name, '.*')}.json")
          version = digest = ptype = nil
          if File.file?(meta_path)
            meta = JSON.parse(File.read(meta_path)) rescue {}
            version = meta['version'].to_s
            digest  = meta['digest'].to_s[0, 8]
            ptype    = meta['property_type'].to_s
          end
          tag = map_tag map
          [name + tag, version.to_s, digest.to_s, ptype.to_s,
           File.mtime(path).strftime('%Y-%m-%d %H:%M')]
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

  # Artifact-like namespaces (artifacts, lists): plain text content search.
  def self.search_text_namespace(query, namespace, limit)
    terms = search_terms query
    ambiguous = ambiguous_names(namespace)
    out = []
    namespace_entries(namespace).each do |name, map, path|
      next unless File.file?(path)
      tag = ambiguous.include?(name) ? map_tag(map) : ''
      content = Open.read(path).to_s
      next if content.empty?
      down = content.downcase
      next unless matches_query?(down, terms)
      idx = down.index(terms.first) || 0
      out << [namespace.to_s, name + tag, snippet_around(content, idx)]
      break if out.length >= limit
    end
    out
  end

  def self.search_artifacts(query, limit)
    search_text_namespace(query, :artifacts, limit)
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
      raise ScoutException, "No #{SINGULAR[type]} named #{name.inspect} in the Cortex #{type} namespace (var/cortex/#{type})"
    end
    raise ScoutException, "Path #{path} is a directory" if Open.directory?(path)
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

end
