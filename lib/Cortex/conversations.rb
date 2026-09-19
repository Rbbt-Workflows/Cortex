require_relative 'storage'
require 'digest'
require 'securerandom'
require 'json'
require 'time'

# ===========================================================================
# Cortex conversations: namespace-specific accessors + persistence
# ===========================================================================

module Cortex

  def self.conversation_path(conversation)
    resource_path :conversations, conversation, write_map
  end

  def self.load_conversation(conversation)
    path, = resolve_resource(:conversations, conversation)
    path ? Chat.load(path) : Chat.setup([])
  end

  # In-flight claims are deliberately separate from the conversation file.  A
  # claim is created exclusively before inference and is never held as an OS
  # lock during the (potentially very long) model call.
  def self.continue_claim_path(conversation)
    digest = Digest::SHA256.hexdigest(sanitize_resource_name!(conversation.to_s))
    File.join(namespace_dir(:conversations, write_map), '.claims', "#{digest}.json")
  end

  def self.claim_prompt_excerpt(prompt)
    prompt.to_s.gsub(/[\x00-\x1f\x7f]/, ' ')[0, 240]
  end

  def self.claim_status(claim)
    job = claim['job_path']
    return [:unknown, 'job path is absent'] if job.to_s.empty?
    begin
      step = Step.load(job)
      status = step.status.to_s
      return [:terminal, status] if %w(done error aborted).include?(status) || step.done? || step.error? || step.aborted?
      return [:active, status]
    rescue Exception => e
      [:unknown, "job inspection failed: #{e.class}: #{e.message.to_s[0, 160]}"]
    end
  end

  def self.acquire_continue_claim(conversation, prompt, job_path: nil, agent: nil)
    path = continue_claim_path(conversation)
    Open.mkdir File.dirname(path)
    token = SecureRandom.hex(24)
    claim = {
      'conversation' => conversation.to_s,
      'job_path' => job_path.to_s,
      'agent' => agent.to_s,
      'prompt_excerpt' => claim_prompt_excerpt(prompt),
      'timestamp' => Time.now.utc.iso8601,
      'process' => "#{Process.pid}:#{Thread.current.object_id}",
      'owner_token' => token
    }
    begin
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(JSON.generate(claim)) }
      claim.merge('_path' => path)
    rescue Errno::EEXIST
      existing = begin JSON.parse(File.read(path)); rescue Exception => e; { '_error' => e.message }; end
      if existing['_error'] || existing['conversation'].to_s != conversation.to_s
        raise ScoutException, "Cortex conversation continuation is blocked for #{conversation.inspect}: existing claim is malformed or uninspectable; refusing recovery (#{existing['_error'] || 'conversation mismatch'})"
      end
      state, detail = claim_status(existing)
      if state == :terminal
        begin
          current = JSON.parse(File.read(path))
          if current['owner_token'] == existing['owner_token']
            File.delete(path)
            return acquire_continue_claim(conversation, prompt, job_path: job_path, agent: agent)
          end
        rescue Exception => e
          raise ScoutException, "Cortex conversation continuation is blocked for #{conversation.inspect}: terminal claim could not be removed safely (#{e.message})"
        end
        raise ScoutException, "Cortex conversation continuation is blocked for #{conversation.inspect}: claim identity changed while recovering"
      end
      raise ScoutException, "Cortex conversation continuation already in flight for #{conversation.inspect}: job=#{existing['job_path'].inspect}, status=#{detail.inspect}, agent=#{existing['agent'].inspect}, prompt=#{existing['prompt_excerpt'].inspect}"
    end
  end

  def self.release_continue_claim(claim)
    return unless claim && claim['_path']
    begin
      current = JSON.parse(File.read(claim['_path']))
      File.delete(claim['_path']) if current['owner_token'] == claim['owner_token']
    rescue Errno::ENOENT
    end
  end

  def self.save_conversation(conversation, prompt, new)
    path = conversation_path conversation
    lock_path = path + '.write.lock'
    Open.lock(lock_path) do
      Open.mkdir File.dirname(path)
      chat = load_conversation conversation
      chat.user prompt
      chat.follow new
      tmp = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}-#{SecureRandom.hex(6)}"
      begin
        chat.save tmp
        File.rename(tmp, path)
      ensure
        File.delete(tmp) if File.exist?(tmp)
      end
    end
  end

end
