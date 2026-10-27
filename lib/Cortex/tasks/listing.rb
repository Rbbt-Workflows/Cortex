
# ==========================================================================
# Cortex exploration tasks: list / search / read
# ==========================================================================

module Cortex

  input :type, :select, 'Namespace to list: conversations, briefs, artifacts, or all', 'all', select_options: %w(conversations briefs artifacts all)
  input :prefix, :string, 'Only names starting with this prefix', nil
  input :offset, :integer, 'Skip the first N entries (pagination)', 0
  input :limit, :integer, 'Maximum entries per page', 50
  task :cortex_list => :text do |type,prefix,offset,limit|
    listing_text(type, prefix, offset, limit)
  end

  input :query, :string, 'Keyword(s) to search for; multiple terms are ANDed', nil, required: true
  input :type, :select, 'Restrict search: conversations, briefs, artifacts, or all', 'all', select_options: %w(conversations briefs artifacts all)
  input :limit, :integer, 'Maximum matches to return', 20
  task :cortex_search => :text do |query,type,limit|
    limit = 20 if limit.nil?
    out = []
    if type == 'all' || type == 'conversations'
      out += search_conversations(query, 'conversations', limit)
      out += search_conversations(query, 'briefs', limit)
    end
    out += search_artifacts(query, limit) if type == 'all' || type == 'artifacts'
    if out.empty?
      "No matches for #{query.inspect}"
    else
      out.first(limit).collect { |type, name, map, snippet| "#{type}\t#{name}\t#{map}\t#{snippet}" } * "\n"
    end
  end

  input :name, :string, 'Name of the conversation, brief, or artifact (artifacts by default)', nil, required: true, nofile: true
  input :type, :select, 'Namespace of the item to read', 'artifacts', select_options: %w(conversations briefs artifacts)
  input :last, :integer, 'Trailing N messages of a conversation/brief', nil
  input :range, :string, 'Inclusive message index range "a-b" of a conversation/brief', nil
  input :start_line, :integer, 'First line to return for artifacts (1-based)', 1
  input :lines, :integer, 'Maximum lines per artifact page', 200
  task :cortex_read => :text do |name,type,last,range,start_line,lines|
    # The task block is evaluated with its exact Scout Step as `self`. Keep the
    # consumer operation on a per-invocation Execution, never ambient/global state.
    execution = Cortex::Execution.begin_task(self)
    case type
    when 'conversations', 'briefs'
      Cortex.read_conversation(name, type, last, range)
    when 'artifacts'
      start_line = 1 if start_line.nil? || start_line < 1
      _path, map, = Cortex.resolve_resource(:artifacts, name)
      persisted_reference = Cortex.artifact_reference(name, map: map)
      output = Cortex.read_artifact(name, start_line, lines)
      execution.record_operation(Cortex::Operation.new(execution: execution, name: :read,
                                                       resource_reference: persisted_reference))
      Cortex.persist_artifact_operation(name, map: map, execution: execution, kind: :read,
                                        reference: persisted_reference)
      output
    end
  end

end
