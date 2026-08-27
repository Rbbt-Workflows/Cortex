require_relative 'storage'

# ==========================================================================
# Cortex path maps: anchor discovery, map configuration, map order
# ==========================================================================
#
# PROBLEM this module solves
# --------------------------
# CORTEX = Scout.var.cortex historically left the Path's libdir unset, so
# :lib was resolved lazily by Path.caller_lib_dir AT find(:lib) TIME from the
# Ruby stack. Inside workflow job / LLM tool execution the stack is all
# framework frames, so from a foreign project (e.g. ~/git/workflows/ComputerUse)
# :lib resolved to garbage ("//var/cortex/...") instead of either project.
#
# DESIGN
# ------
# CORTEX is configured ONCE with the complete set of path maps AND the map
# order.  Everything downstream then resolves resources with plain Path
# calls (CORTEX[type][full_path].find / .follow), so a single mechanism --
# Scout's own -- traverses every configured location in the right order.
#
# 1. ANCHOR: the libdir of the project that is the object of the
#    `scout-ai llm ask`. scout-ai sets ENV['SCOUT_CHAT_DIR'] (||=, never
#    clobbering) once, at chat-compile entry (see lib/scout/llm/chat.rb,
#    LLM.chat); ENV propagates into exec/bwrap job subprocesses, which a
#    PWD-based anchor could not do (PWD under exec is the workflow's own
#    directory).  When SCOUT_CHAT_DIR is absent, Dir.pwd is used as the
#    anchor instead.  The anchor never introduces a map of its own: it only
#    sets CORTEX.libdir (so :lib = {LIBDIR}/... resolves to the chat repo)
#    and locates cortex_path_map.yaml.  Scout::Config may pin the anchor for
#    tests and explicit overrides (config key `cortex.chat_dir`).
#
# 2. CORTEX CONFIGURATION: the first time any path map is needed,
#    configure_cortex! gives CORTEX a libdir (the anchor), instance-level
#    path_maps (a private copy of Path.path_maps -- the global table is
#    never mutated) and an instance map_order built from Scout's own map
#    table:
#      :current -> {PWD}/{TOPLEVEL}/{SUBPATH}   (NEVER overridden; default
#                  write map.  PWD caveat: under exec/bwrap the job PWD is
#                  the workflow root, not the chat dir, so with a foreign
#                  chat anchor :current = the workflow checkout's store and
#                  :lib = the chat repo's store; :current is searched
#                  first.)
#      :lib     -> {LIBDIR}/{TOPLEVEL}/{SUBPATH} with LIBDIR = the anchor
#                  project (the library store)
#      :user    -> the per-user home store (read-only)
#    The head of the map_order is therefore [:current, :lib, :user], which
#    is also the head of Scout's own Path.map_order for :current/:user.
#
# 3. PER-PROJECT EXTRA MAPS: if the anchor project carries a
#    cortex_path_map.yaml (project root first, then etc/), every entry
#    becomes another instance-level map:
#
#        maps:
#          cortex:
#            dir: /home/mvazque2/git/workflows/Cortex
#          ags:
#            dir: /home/mvazque2/git/workflows/AGS
#            read_only: true
#          lib:                      # optional: redefine :lib itself
#            dir: /home/mvazque2/git/workflows/Cortex
#
#    Read traversal order becomes [:current, :lib, :user, configured maps in
#    yaml order, then the rest of Scout's base Path.map_order table minus
#    :default]; read_only maps are readable but rejected as move/write
#    targets.

module Cortex

  # Maps that may not be used as write/move targets even when configured.
  READ_ONLY_MAPS = [].freeze
  CONFIGURED_READ_ONLY_MAPS = []

  # --- anchor ---------------------------------------------------------

  # Libdir of the project the chat belongs to.  SCOUT_CHAT_DIR (set by
  # scout-ai, inherited by job subprocesses) wins, then the config key,
  # then the repo containing Dir.pwd.  The PWD fallback CLIMBS to the
  # repository root (marker-based: lib/, bin/ or README.md), so running
  # from a subdirectory still resolves the project the way the anchored
  # case does -- `:lib` is the repo store and cortex_path_map.yaml is
  # found at the repo root.  From a repo root :current and :lib collapse
  # on the same directory; from a subdir they diverge (:current = the
  # subdir store, :lib = the repo store).  A PWD inside no repo leaves the
  # anchor unset (nil): CORTEX.libdir is not pinned and :lib keeps Scout's
  # lazy semantics.
  def self.chat_anchor
    @@chat_anchor ||= begin
                        anchor = ENV['SCOUT_CHAT_DIR']
                        anchor ||= Scout::Config.get('chat_dir', 'cortex', env: 'SCOUT_CHAT_DIR')
                        if anchor.nil? || anchor.to_s.empty?
                          return nil if Dir.pwd.nil? || Dir.pwd == '/'
                          # Explicit file argument => caller frames are never
                          # consulted (see Path.caller_file): the climb below is
                          # pure path analysis, stable under `scout task`.
                          # Nil-safe: no repo around the PWD (the marker
                          # climb only reaches '/', whose bin/ is guarded
                          # below) keeps the anchor unset.
                          repo = Path.caller_lib_dir(Dir.pwd)
                          # `return` (not a local assignment) so the memo
                          # `||=` does NOT cache a nil anchor as configured.
                          return nil if repo.nil? || repo.to_s == '/'
                          anchor = repo
                        end
                        anchor = File.expand_path(anchor.to_s)
                        # Defensive: a climb may still land on '/' (the
                        # filesystem root has a bin/ marker); reject it.
                        return nil if anchor == '/'
                        anchor
                      end
  end

  # --- configuration --------------------------------------------------

  @@configured = nil
  @@chat_anchor = nil
  @@path_map_config = nil

  def self.cortex_configured?
    !@@configured.nil?
  end

  # Libdir CORTEX was configured with (nil = not yet / unanchored).
  def self.cortex_libdir
    configure_cortex!
    CORTEX.libdir
  end

  # Forget the memoized anchor and configuration.  Tests (and any nested
  # re-anchoring) use this to force reconfiguration after changing
  # SCOUT_CHAT_DIR or the PWD.
  def self.reset_cortex!
    @@chat_anchor = nil
    @@configured = nil
    @@path_map_config = nil
    CONFIGURED_READ_ONLY_MAPS.clear
    # Also drop any pinned libdir: @@configured == nil == anchor makes
    # configure_cortex! short-circuit on the next call, so the pin must be
    # cleared here for :lib to fall back to Scout's lazy resolution.
    CORTEX.libdir = nil
    CORTEX
  end

  # Idempotent: installs libdir + instance path_maps + map_order on CORTEX
  # and loads the anchor project's cortex_path_map.yaml if present. Safe to
  # call from any map lookup; runs at most once per anchor (re-running with
  # a different anchor re-configures, which keeps tests hermetic).
  def self.configure_cortex!
    anchor = chat_anchor
    return CORTEX if @@configured == anchor

    maps = Path.path_maps.dup

    if anchor
      # The anchor only sets CORTEX.libdir: :lib then resolves to
      # {LIBDIR}/... = the chat project's own cortex store, deterministically
      # instead of lazily from the Ruby stack.  :current keeps Scout's own
      # {PWD} template (never overridden) and stays the default write map.
      CORTEX.libdir = anchor
    else
      # Re-configure without an anchor (tests, nested in-process use) must
      # drop any previously pinned libdir, otherwise :lib keeps pointing at
      # the previous chat project instead of Scout's lazy caller-lib
      # resolution.
      CORTEX.libdir = nil
    end

    # Rebuild the configured read-only list from scratch on every
    # (re)configuration so switching anchors in-process (tests, nested use)
    # never leaks a stale read-only marker from a previous anchor's yaml.
    CONFIGURED_READ_ONLY_MAPS.clear

    yaml = path_map_config(anchor)
    yaml.each do |name, spec|
      spec = {'dir' => spec} if String === spec
      dir = File.expand_path(spec['dir'].to_s)
      template = File.join(dir, '{TOPLEVEL}/{SUBPATH}')
      maps[name.to_sym] = template
      CONFIGURED_READ_ONLY_MAPS << name.to_sym if spec['read_only'].to_s == 'true'
    end

    CORTEX.path_maps = maps
    CORTEX.map_order = default_map_order(yaml)

    @@configured = anchor
    @@path_map_config = yaml
    CORTEX
  end

  # Instance map order: the head [:current, :lib, :user] (:lib is the chat
  # project's store, :current the PWD one, never overridden), then the
  # yaml-configured maps in declaration order (a yaml `lib:` redefinition
  # only changes the :lib TEMPLATE, not its position, hence it is excluded
  # from extras), then the rest of Scout's base Path.map_order table minus
  # :default.  A plain .find on CORTEX[ns][name] therefore traverses every
  # configured location in exactly this order.
  def self.default_map_order(yaml = nil, anchored = nil)
    yaml ||= (@@path_map_config || {})
    extra = (yaml.keys - ['lib']).collect(&:to_sym)
    head  = [:current, :lib, :user]
    tail  = Path.map_order - head - extra - [:default]
    head + extra + tail
  end

  # Read (and memoize) the anchor project's cortex_path_map.yaml.
  # Lookup order: <anchor>/cortex_path_map.yaml then <anchor>/etc/cortex_path_map.yaml.
  # Returns {} when there is no anchor or no file. A `maps:` section that is
  # not a Hash raises (configuration must fail loudly, not silently).
  def self.path_map_config(anchor = nil)
    return {} if anchor.nil?
    if @@path_map_config.nil?
      config = begin
                 file = [File.join(anchor, 'cortex_path_map.yaml'),
                         File.join(anchor, 'etc', 'cortex_path_map.yaml')].find { |f| File.file?(f) }
                 maps = nil
                 if file
                   require 'yaml'
                   doc = YAML.safe_load(Open.read(file)) || {}
                   maps = doc['maps'] || {}
                 end
                 raise ScoutException,
                       "Invalid cortex_path_map.yaml #{file}: 'maps' must be a mapping of name -> {dir:, read_only:}" if maps && !(Hash === maps)
                 maps || {}
               end
      @@path_map_config = config
    end
    @@path_map_config
  end

  # --- map queries (the public face used by storage/tasks) ------------

  # Every configured map name (instance table on CORTEX).
  def self.map_names
    configure_cortex!
    CORTEX.path_maps.keys
  end

  def self.map?(map)
    configure_cortex!
    CORTEX.path_maps.include?(map.to_sym)
  end

  # The traversal order CORTEX uses for a plain .find.
  def self.map_order
    configure_cortex!
    CORTEX.map_order
  end

  # Read-only maps: the module-level :user plus any yaml `read_only: true`
  # entries recorded in CONFIGURED_READ_ONLY_MAPS at configure time.
  def self.read_only_map?(map)
    configure_cortex!
    READ_ONLY_MAPS.include?(map.to_sym) || CONFIGURED_READ_ONLY_MAPS.include?(map.to_sym)
  end

  # Writable maps: every configured map except :user and yaml read_only ones.
  def self.writable_maps
    configure_cortex!
    CORTEX.path_maps.keys - READ_ONLY_MAPS - CONFIGURED_READ_ONLY_MAPS
  end

  # Stable alias: the anchor is the project owning this Cortex session,
  # wherever it came from (SCOUT_CHAT_DIR, config, or the PWD fallback).
  def self.project_anchor
    chat_anchor
  end

  # Stable name other modules delegate to.
  def self.configured_write_map
    configure_cortex!
    # No Config `default:` here on purpose: Scout::Config caches resolved
    # values per (key, tokens), so an earlier call with a different
    # anchor-derived default would stick after the anchor changes in-process
    # (tests, nested use). Resolve the fallback in Ruby instead.
    map = Scout::Config.get('write_map', 'cortex')
    map ||= :current
    map = map.to_sym
    raise ScoutException, "Unknown Cortex path map :#{map}; configured maps: #{map_names * ', '}" unless map?(map)
    raise ScoutException, "Cortex path map :#{map} is read-only; writable maps: #{writable_maps * ', '}" if read_only_map?(map)
    map
  end

  def self.configured_read_maps
    configure_cortex!
    # Same Config default-caching caveat as write_map: the fallback is
    # resolved in Ruby, not through `default:`.
    maps = Scout::Config.get('read_maps', 'cortex')
    maps ||= map_order
    maps = maps.to_s.split(',').collect{|m| m.strip } unless Array === maps
    maps = maps.collect(&:to_sym)
    unknown = maps - map_names
    raise ScoutException, "Unknown Cortex path maps #{unknown.inspect}; configured maps: #{map_names * ', '}" if unknown.any?
    maps
  end

  def self.default_read_maps
    map_order
  end

  def self.map_tag(map, maps = nil)
    maps ||= read_maps
    maps.length > 1 ? ":#{map}" : ''
  end

  def self.write_map
    configured_write_map
  end

  def self.read_maps
    configured_read_maps
  end

end
