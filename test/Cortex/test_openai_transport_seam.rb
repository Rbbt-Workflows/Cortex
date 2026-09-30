# Offline feasibility regression for one Scout-AI provider path.
# The backend client factory is stubbed before SDK construction, and the fake
# client's chat method only records the request; neither can send.
require File.expand_path(__FILE__).sub(%r(/test/.*), '/test/Cortex/test_helper.rb')
require 'scout/llm/backends/openai'
require 'uri'

class TestOpenAITransportSeam < Test::Unit::TestCase
  class FakeClient
    attr_reader :parameters

    def chat(parameters:)
      @parameters = parameters
      :offline_response
    end
  end

  def setup
    @method_snapshots = {
      [LLM::OpenAI, :client] => singleton_method_snapshot(LLM::OpenAI, :client),
      [Scout::Config, :get] => singleton_method_snapshot(Scout::Config, :get),
      [LLM, :get_url_config] => singleton_method_snapshot(LLM, :get_url_config)
    }
  end

  def teardown
    @method_snapshots.each do |(receiver, name), snapshot|
      restore_singleton_method(receiver, name, snapshot)
      assert_equal snapshot[:owner], receiver.method(name).owner
    end
  end

  def singleton_method_snapshot(receiver, name)
    singleton = receiver.singleton_class
    visibility = %i[public protected private].find do |level|
      singleton.public_send("#{level}_instance_methods", false).include?(name)
    end
    {singleton: singleton, visibility: visibility,
     definition: visibility && singleton.instance_method(name),
     owner: receiver.method(name).owner}
  end

  def restore_singleton_method(receiver, name, snapshot)
    singleton = snapshot[:singleton]
    if %i[public protected private].any? do |level|
         singleton.public_send("#{level}_instance_methods", false).include?(name)
       end
      singleton.remove_method(name)
    end
    if snapshot[:definition]
      singleton.define_method(name, snapshot[:definition])
      singleton.send(snapshot[:visibility], name)
    end
  end

  def test_explicit_loopback_url_reaches_guarded_fake_factory
    fake_client = FakeClient.new
    factory_options = nil
    LLM::OpenAI.define_singleton_method(:client) do |options|
      factory_options = options.dup
      uri = URI.parse(factory_options.fetch(:url))
      unless uri.scheme == 'http' && uri.host == '127.0.0.1' &&
             uri.port == 18765 && uri.path == '/v1' && uri.userinfo.nil?
        raise "Non-loopback provider destination rejected: #{uri.host}"
      end
      fake_client
    end
    # Fail closed on configuration lookup. All options are explicit, and no
    # credentials, environment variables, or provider profiles are read.
    Scout::Config.define_singleton_method(:get) do |*|
      raise 'Unexpected configuration lookup in explicit-URL probe'
    end

    options = {url: 'http://127.0.0.1:18765/v1', key: 'offline-test-key',
               model: 'offline-test-model'}
    client = LLM::OpenAI.prepare_client(options)
    result = LLM::OpenAI.query(client, [{role: 'user', content: 'offline probe'}])

    assert_same fake_client, client
    assert_equal 'http://127.0.0.1:18765/v1', factory_options.fetch(:url)
    assert_equal :offline_response, result
    assert_equal [{role: 'user', content: 'offline probe'}], fake_client.parameters[:messages]
  end

  def test_missing_url_is_omitted_without_constructing_a_client
    requested_keys = []
    Scout::Config.define_singleton_method(:get) do |key, *|
      requested_keys << key.to_sym
      raise 'Unexpected non-URL configuration lookup' unless key.to_sym == :url
      nil
    end
    # client_options ordinarily asks get_url_config for a key even when URL is
    # absent. Replace that resolver so this test never consults credential
    # configuration or secret-bearing environment variables.
    LLM.define_singleton_method(:get_url_config) do |key, *|
      raise 'Unexpected non-key configuration lookup' unless key.to_sym == :key
      'offline-test-key'
    end

    options = LLM::OpenAI.client_options(model: 'offline-test-model')

    assert_equal [:url], requested_keys
    refute options.key?(:url)
  end
end

if $PROGRAM_NAME == __FILE__
  Test::Unit::AutoRunner.run
end
