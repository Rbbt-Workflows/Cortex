require_relative 'storage'

# ==========================================================================
# Cortex artifacts: write/edit with provenance + version history, management
# ==========================================================================
#
# Artifacts are text files under artifacts/ with two sidecars:
#   .meta/<name>.json    version records (job, agent, mode, map, size, ts)
#   .history/<name>/     one snapshot per replace/edit, <ts>.<seq>
# Sidecars travel with the resource on rename/move (see storage.rb).

module Cortex

  def self.artifact_path(artifact)
    resource_path :artifacts, artifact, default_local_map
  end

  def self.artifact_history_path(name)
    sidecar_paths(:artifacts, name, default_local_map)[1]
  end

  def self.artifact_meta_path(name)
    sidecar_paths(:artifacts, name, default_local_map)[0]
  end

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

    prune_empty_dirs(namespace, path, map)

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

    prune_empty_dirs(namespace, path, map)

    "Renamed: #{name} -> #{new_name} (:#{map})"
  end

  def self.move_resource(namespace, name, to_map, job: nil, agent: nil)
    namespace = namespace.to_sym
    to_map = to_map.to_sym
    raise ScoutException, "Unknown Cortex path map :#{to_map}; configured maps: #{map_names * ', '}" unless map?(to_map)
    raise ScoutException, "Cortex path map :#{to_map} is read-only; writable maps: #{writable_maps * ', '}" if read_only_map?(to_map)

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

    prune_empty_dirs(namespace, path, map)

    "Moved: #{name} from :#{map} to :#{to_map}"
  end

  # Remove now-empty parent directories up to (excluding) the namespace root.
  # Dot-directories (.meta, .history) never keep a directory alive.
  def self.prune_empty_dirs(namespace, path, map)
    base = namespace_dir(namespace, map)
    dir = File.dirname(path)
    while dir.start_with?(base.to_s) && dir != base.to_s
      break unless Dir.glob(File.join(dir, '*')).reject { |f| File.basename(f).start_with?('.') }.empty?
      Dir.rmdir dir rescue nil
      dir = File.dirname(dir)
    end
  end

end
