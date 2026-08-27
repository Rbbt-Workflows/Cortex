
# ==========================================================================
# Cortex exploration tasks: list / search / read
# ==========================================================================

module Cortex

  input :type, :select, "Namespace to list: conversations, briefs, artifacts, entities, lists, or all (every namespace with counts)", 'all', select_options: %w(conversations briefs artifacts entities lists all)
  input :prefix, :string, 'Only names starting with this prefix', nil
  input :offset, :integer, 'Skip the first N entries (pagination)', 0
  input :limit, :integer, 'Maximum entries per page', 50
  task :cortex_list => :text do |type,prefix,offset,limit|
    type = Cortex.validate_type! type
    listing_text type, prefix, offset, limit
  end

  input :query, :string, 'Keyword(s) to search for; multiple terms are ANDed', nil, required: true
  input :type, :select, "Restrict search: conversations, briefs, artifacts, lists, or all", 'all', select_options: %w(conversations briefs artifacts lists all)
  input :limit, :integer, 'Maximum number of matches to return', 20
  task :cortex_search => :text do |query,type,limit|
    type = Cortex.validate_type! type
    type = nil if type == 'all'
    limit = 20 if limit.nil? || limit <= 0
    rows = []
    unless type == 'artifacts' || type == 'lists'
      rows += search_conversations(query, 'conversations', limit)
      rows += search_conversations(query, 'briefs', limit - rows.length) if !type && rows.length < limit
    end
    rows += search_artifacts(query, limit - rows.length) if type != 'conversations' && type != 'lists' && rows.length < limit
    rows += Cortex.search_text_namespace(query, :lists, limit - rows.length) if type != 'conversations' && type != 'artifacts' && rows.length < limit
    if rows.empty?
      "No matches for #{query.inspect}"
    else
      (['#type' + "\t" + 'name' + "\t" + 'map' + "\t" + 'match'] +
       rows.collect { |r| r * "\t" }) * "\n" + "\n"
    end
  end

  input :name, :string, 'Name of the conversation, brief, artifact, or entity list (artifacts and lists may include subdirs, e.g. claims/C42.md or TF/C01)', nil, required: true
  input :type, :select, "Namespace of the item to read", nil, {select_options: %w(conversations briefs artifacts lists), required: true, jobname: true}
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
    when 'lists'
      entity_type, list = name.split(File::SEPARATOR, 2)
      entities, meta, _path, map, all_paths = Cortex.read_list(entity_type, list)
      out = ["Entity list #{name}: #{entities.length} entities"]
      out << "[note] exists in more than one path map; using :#{map} (#{all_paths * ' | '})" if all_paths.length > 1
      out << meta.to_s unless meta.empty?
      out << entities * "\n"
      out * "\n"
    end
  end

end
