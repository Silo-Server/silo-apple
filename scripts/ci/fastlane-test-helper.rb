# Shared Fastfile DSL/action replacements. No commands or API calls execute.
require "minitest/autorun"
require "shellwords"

module UI
  def self.user_error!(message)
    raise ArgumentError, message
  end

  def self.message(_message); end
  def self.success(_message); end
  def self.important(_message); end
end

module FastlaneCore
  module Helper
    class << self
      attr_accessor :test_mac
    end

    def self.mac?
      test_mac
    end
  end
end

module SharedValues
  MATCH_PROVISIONING_PROFILE_MAPPING = :profiles
end

class FastfileHarness
  attr_reader :actions
  attr_accessor :test_ci, :upload_failure, :api_key_failure

  def initialize
    @actions = []
    @hooks = {}
    @test_ci = false
    path = File.expand_path("../../fastlane/Fastfile", __dir__)
    instance_eval(File.read(path), path)
  end

  def default_platform(_platform); end
  def desc(_description); end
  def platform(_platform, &block)
    instance_exec(&block)
  end

  def lane(name, &block)
    define_singleton_method(name) do
      previous_lane = @current_lane
      @current_lane = name
      result = instance_exec(&block)
      @current_lane = previous_lane
      result
    end
  end
  alias private_lane lane

  def before_all(&block)
    @hooks[:before] = block
  end

  def after_all(&block)
    @hooks[:after] = block
  end

  def error(&block)
    @hooks[:error] = block
  end

  def run_lane(name)
    @current_lane = name
    instance_exec(name, {}, &@hooks.fetch(:before))
    public_send(name)
    instance_exec(name, {}, &@hooks.fetch(:after))
  rescue StandardError => exception
    instance_exec(@current_lane, exception, {}, &@hooks.fetch(:error))
    raise
  end

  def is_ci
    test_ci
  end

  def lane_context
    { SharedValues::MATCH_PROVISIONING_PROFILE_MAPPING => {
      "org.siloserver.silo" => "app-profile",
      "org.siloserver.silo.NotificationService" => "notifications-profile",
      "org.siloserver.silo.DownloadsActivity" => "activity-profile",
      "org.siloserver.silo.topshelf" => "topshelf-profile"
    } }
  end

  def sh(*args)
    @actions << [:sh, args]
    ""
  end

  def setup_ci
    @actions << [:setup_ci, {}]
  end

  def app_store_connect_api_key(**options)
    @actions << [:api_key, options]
    raise api_key_failure if api_key_failure
    { test_key: true }
  end

  %i[match build_app update_code_signing_settings xcodebuild delete_keychain].each do |action|
    define_method(action) do |**options|
      @actions << [action, options]
    end
  end

  def latest_testflight_build_number(**options)
    @actions << [:latest_build, options]
    41
  end

  def upload_to_testflight(**options)
    @actions << [:testflight, options]
    raise upload_failure if upload_failure
  end
end
