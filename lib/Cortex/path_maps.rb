require_relative 'storage'

# ==========================================================================
# Cortex path maps: anchor discovery, per-project yaml configuration
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
# 1. ANCHOR: the libdir of the project that is the object of the
#    `scout-ai llm ask`. scout-ai sets ENV['SCOUT_CHAT_DIR'] (||=, never
#    clobbering) once, at chat-compile entry (see
#    lib/scout/llm/chat.rb, LLM.chat); ENV propagates into exec/bwrap job
#    subprocesses, which a PWD-based anchor could not do (PWD under exec is
#    the workflow's own directory). Scout::Config may pin the same value
#    (config key `chat_dir`) for tests and explicit overrides.
#
# 2. CORTEX RECONFIGURATION: the first time any path map is needed,
#    configure_cortex! gives CORTEX a libdir (the anchor) and instance-level
#    path_maps (a private copy of Path.path_maps — the global table is never
#    mutated) such that:
#      :chat  -> {LIBDIR}/{TOPLEVEL}/{SUBPATH} with LIBDIR = the anchor project
#      :lib   -> pinned to the Cortex checkout template       (shared store)
#    so from ComputerUse, :chat is ComputerUse/var/cortex and :lib is
#    Cortex/var/cortex — both deterministic, neither stack-dependent.
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
#    Read traversal order becomes [configured maps in yaml order, then :lib,
#    :current, :user]; read_only maps are readable but rejected as move/write
#    targets. Without an anchor (direct library use from the checkout) every
#    map keeps its historical template and behaviour is unchanged.

module Cortex

  # Maps that may not be used as write/move targets even when configured.
  READ_ONLY_MAPS = [:user].freeze
  CONFIGURED_READ_ONLY_MAPS = []

  # --- anchor ---------------------------------------------------------

  # Libdir of the project the chat belongs to, or nil when Cortex is used
  # directly from its own checkout. ENV (set by scout-ai) wins over Config.
  def self.chat_anchor
    anchor = ENV['SCOUT_CHAT_DIR']
    anchor ||= Scout::Config.get('chat_dir', 'cortex', env: 'SCOUT_CHAT_DIR')
    return nil if anchor.nil? || anchor.to_s.empty?
    anchor = File.expand_path(anchor.to_s)
    # Marker-based climbs can overshoot to '/' (a bare dir has a lib/ marker
    # at the filesystem root); guard it explicitly.
    return nil if anchor == '/'
    anchor
  end

  # --- configuration --------------------------------------------------

  @@configured = nil
  @@path_map_config = nil

  def self.cortex_configured?
    !@@configured.nil?
  end

  # Libdir CORTEX was configured with (nil = not yet / unanchored).
  def self.cortex_libdir
    configure_cortex!
    CORTEX.libdir
  end

  # Idempotent: installs libdir + instance path_maps on CORTEX and loads the
  # anchor project's cortex_path_map.yaml if present. Safe to call from any
  # map lookup; runs at most once per anchor (re-running with a different
  # anchor re-configures, which keeps tests hermetic).
  def self.configure_cortex!
    anchor = chat_anchor
    return CORTEX if @@configured == anchor

    maps = Path.path_maps.dup

    if anchor
      # :chat is the anchor project's own cortex dir; :current follows the
      # anchor (instead of the lazy CWD-based template) so that writes land
      # in the invoking project; :lib is pinned absolutely to the Cortex
      # checkout template so it is never stack-dependent again.
      maps[:chat] = '{LIBDIR}/{TOPLEVEL}/{SUBPATH}'
      maps[:current] = '{LIBDIR}/{TOPLEVEL}/{SUBPATH}'
      maps[:lib] = cortex_checkout_template

      # Read order without an explicit config: the yaml-configured maps first
      # (declaration order), then the anchor store, then the shared Cortex
      # store, then the fallbacks. :lib stays readable so foreign projects
      # can still consult the shared store and promote into it.

      CORTEX.libdir = anchor
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
    @@configured = anchor
    @@path_map_config = yaml
    CORTEX
  end

  # Absolute template for the shared Cortex store: the directory containing
  # THIS file is <checkout>/lib/Cortex/path_maps.rb.
  def self.cortex_checkout_template
    File.join(File.dirname(File.dirname(File.dirname(File.expand_path(__FILE__)))),
              '{TOPLEVEL}/{SUBPATH}')
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

  # Stable name other modules delegate to; `write_map` may be overridden
  # by later requires (entities.rb defines its own delegation).
  def self.configured_write_map
    configure_cortex!
    # No Config `default:` here on purpose: Scout::Config caches resolved
    # values per (key, tokens), so an earlier call with a different
    # anchor-derived default would stick after the anchor changes in-process
    # (tests, nested use). Resolve the fallback in Ruby instead.
    map = Scout::Config.get('write_map', 'cortex')
    map ||= chat_anchor ? :chat : :current
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
    maps ||= default_read_maps
    maps = maps.to_s.split(',').collect{|m| m.strip } unless Array === maps
    maps = maps.collect(&:to_sym)
    unknown = maps - map_names
    raise ScoutException, "Unknown Cortex path maps #{unknown.inspect}; configured maps: #{map_names * ', '}" if unknown.any?
    maps
  end

  def self.default_read_maps
    configure_cortex!
    extra = (@@path_map_config || {}).keys - %w(lib)
    extra.collect(&:to_sym) + [:lib, :current, :user]
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
