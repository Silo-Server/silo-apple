#!/usr/bin/env ruby
# Exercise the release lanes without Fastlane, Xcode, signing, or network access.
# Every action and App Store Connect query below uses an in-memory replacement.
require_relative "fastlane-test-helper"

module FastlaneCore
  class Configuration
    def self.create(_options, values)
      { wait_processing_interval: 30 }.merge(values)
    end
  end

  class BuildWatcher
    def self.wait_for_build_processing_to_be_complete(**options)
      Spaceship::ConnectAPI.calls << [:wait, options]
      raise Spaceship::ConnectAPI.test_wait_failure if Spaceship::ConnectAPI.test_wait_failure
      builds = Spaceship::ConnectAPI.test_builds.uniq(&:id)
      raise ArgumentError, "ambiguous builds" if builds.length > 1
      builds.first
    end
  end

end

module Spaceship
  module ConnectAPI
    class << self
      attr_accessor :test_app, :test_builds, :calls, :test_wait_failure, :test_refreshed_build
    end

    class App
      def self.find(identifier)
        ConnectAPI.calls << [:app, identifier]
        ConnectAPI.test_app
      end
    end

    class Build
      def self.get(**options)
        ConnectAPI.calls << [:build, options]
        ConnectAPI.test_refreshed_build || ConnectAPI.test_builds.first
      end
    end

    module Platform
      def self.map(value)
        { "ios" => "IOS", "appletvos" => "TV_OS" }.fetch(value)
      end
    end
  end
end

module Pilot
  class Options
    def self.available_options
      []
    end
  end

  class BuildManager
    def start(options)
      Spaceship::ConnectAPI.calls << [:start, options]
    end

    def distribute(options, build:)
      Spaceship::ConnectAPI.calls << [:distribute, options, build]
    end
  end
end

TestBetaDetail = Struct.new(:auto_notify_enabled)
TestBuild = Struct.new(:id, :version, :app_version, :platform, :processing_state,
                       :expired, :build_beta_detail, :app)
TestGroup = Struct.new(:id, :name, :is_internal_group, :builds) do
  def fetch_builds
    Spaceship::ConnectAPI.calls << [:group_builds, id]
    builds
  end
end
TestApp = Struct.new(:id, :groups) do
  def get_beta_groups
    Spaceship::ConnectAPI.calls << [:groups, id]
    groups
  end
end

class FastlaneReleaseTest < Minitest::Test
  ENV_KEYS = %w[
    MARKETING_VERSION BUILD_NUMBER TEAM_ID SILO_SOURCE_PACKAGES_PATH
    SILO_DEFER_TESTFLIGHT_DISTRIBUTION TESTFLIGHT_DISTRIBUTION
    TESTFLIGHT_INTERNAL_GROUPS TESTFLIGHT_EXTERNAL_GROUPS
    TESTFLIGHT_NOTIFY_EXTERNAL_TESTERS TESTFLIGHT_CHANGELOG SILO_RELEASE_SOURCE_URL
    APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID
    APP_STORE_CONNECT_API_KEY_KEY FL_ORIG_DEFAULT_KC FL_ORIG_KC_LIST FL_CI_KEYCHAIN_MANAGED
  ].freeze
  SOURCE_URL = "https://github.com/Silo-Server/silo-apple/releases/download/v1.4.0/Silo-source-#{'a' * 40}.tar.gz".freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV.update(
      "MARKETING_VERSION" => "1.4.0", "BUILD_NUMBER" => "7", "TEAM_ID" => "TESTTEAM",
      "TESTFLIGHT_CHANGELOG" => "Test release", "TESTFLIGHT_DISTRIBUTION" => "external",
      "TESTFLIGHT_EXTERNAL_GROUPS" => "Public Beta", "SILO_RELEASE_SOURCE_URL" => SOURCE_URL,
      "APP_STORE_CONNECT_API_KEY_KEY_ID" => "TESTKEY",
      "APP_STORE_CONNECT_API_KEY_ISSUER_ID" => "test-issuer",
      "APP_STORE_CONNECT_API_KEY_KEY" => ["test-key"].pack("m0")
    )
    @app = TestApp.new("app-1", [])
    @build = TestBuild.new("build-7", "7", "1.4.0", "IOS", "VALID", false, TestBetaDetail.new(true), @app)
    @group = TestGroup.new("group-1", "Public Beta", false, [@build])
    @app.groups = [@group]
    Spaceship::ConnectAPI.test_app = @app
    Spaceship::ConnectAPI.test_builds = [@build]
    Spaceship::ConnectAPI.calls = []
    Spaceship::ConnectAPI.test_wait_failure = nil
    Spaceship::ConnectAPI.test_refreshed_build = nil
    FastlaneCore::Helper.test_mac = false
    @lane = FastfileHarness.new
  end

  def teardown
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_deferred_upload_never_waits_for_changelog_or_distributes
    ENV["SILO_DEFER_TESTFLIGHT_DISTRIBUTION"] = "true"
    @lane.run_lane(:beta_ios)
    options = action_options(:testflight)
    assert_equal "build/ios/Silo.ipa", options[:ipa]
    assert_nil options[:changelog]
    assert_nil options[:groups]
    assert_equal false, options[:distribute_external]
    assert_equal false, options[:notify_external_testers]
    assert_equal true, options[:skip_submission]
    assert_equal true, options[:skip_waiting_for_build_processing]
    assert_empty Spaceship::ConnectAPI.calls
    refute @lane.actions.any? { |action, _| action == :latest_build }
  end

  def test_direct_local_upload_preserves_distribution_and_build_number_lookup
    ENV.delete("BUILD_NUMBER")
    @lane.run_lane(:beta_tvos)
    options = action_options(:testflight)
    assert_equal ["Public Beta"], options[:groups]
    assert_equal "Test release\n\nSource and rebuild instructions: #{SOURCE_URL}", options[:changelog]
    assert_equal true, options[:distribute_external]
    assert_equal true, options[:notify_external_testers]
    assert_equal false, options[:skip_submission]
    assert_equal false, options[:skip_waiting_for_build_processing]
    assert_equal "appletvos", action_options(:latest_build)[:platform]
    assert_includes action_options(:build_app)[:xcargs], "CURRENT_PROJECT_VERSION=42 "
  end




  def test_ios_distribution_waits_for_and_verifies_only_the_pinned_build
    @lane.run_lane(:distribute_ios)
    assert_distribution_options("ios")
    assert_equal [:api_key], @lane.actions.map(&:first)
    wait = Spaceship::ConnectAPI.calls.find { |call| call.first == :wait }.last
    assert_equal "app-1", wait[:app_id]
    assert_equal "1.4.0", wait[:app_version]
    assert_equal "7", wait[:build_version]
    assert_equal "ios", wait[:platform]
    assert_equal 900, wait[:timeout_duration]
    assert_equal false, wait[:select_latest]
    assert_equal false, wait[:return_when_build_appears]
    assert_equal true, wait[:wait_for_build_beta_detail_processing]
    assert_equal 1, Spaceship::ConnectAPI.calls.count { |call| call.first == :wait }
    assert_same @build, Spaceship::ConnectAPI.calls.find { |call| call.first == :distribute }.last
    assert_includes Spaceship::ConnectAPI.calls, [:build, { build_id: "build-7" }]
    assert_includes Spaceship::ConnectAPI.calls, [:group_builds, "group-1"]
  end

  def test_tvos_distribution_uses_its_own_platform_sequence
    @build.platform = "TV_OS"
    @lane.run_lane(:distribute_tvos)
    assert_distribution_options("appletvos")
    wait = Spaceship::ConnectAPI.calls.find { |call| call.first == :wait }.last
    assert_equal "appletvos", wait[:platform]
  end

  def test_distribution_hooks_do_not_access_keychains_even_on_macos_ci
    @lane.test_ci = true
    FastlaneCore::Helper.test_mac = true
    @lane.run_lane(:distribute_ios)
    assert_nil ENV["FL_ORIG_DEFAULT_KC"]
    assert_nil ENV["FL_ORIG_KC_LIST"]
    assert_equal [:api_key], @lane.actions.map(&:first)
  end

  def test_failed_private_api_lane_does_not_trigger_keychain_cleanup
    @lane.test_ci = true
    FastlaneCore::Helper.test_mac = true
    @lane.api_key_failure = ArgumentError.new("test API key failure")
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    assert_equal [:api_key], @lane.actions.map(&:first)
    assert_nil ENV["FL_ORIG_DEFAULT_KC"]
    assert_nil ENV["FL_ORIG_KC_LIST"]
  end

  def test_internal_distribution_preserves_groups_and_disables_notifications
    ENV["TESTFLIGHT_DISTRIBUTION"] = "internal"
    ENV["TESTFLIGHT_INTERNAL_GROUPS"] = "Internal QA"
    ENV.delete("SILO_RELEASE_SOURCE_URL")
    @group.name = "Internal QA"
    @group.is_internal_group = true
    @lane.run_lane(:distribute_ios)
    options = distribution_options
    assert_equal ["group-1"], options[:groups]
    assert_equal "Test release", options[:changelog]
    assert_equal false, options[:distribute_external]
    assert_equal false, options[:notify_external_testers]
  end

  def test_external_notification_preference_is_preserved
    ENV["TESTFLIGHT_NOTIFY_EXTERNAL_TESTERS"] = "false"
    @build.build_beta_detail.auto_notify_enabled = false
    @lane.run_lane(:distribute_ios)
    assert_equal false, distribution_options[:notify_external_testers]
  end

  def test_missing_or_invalid_build_and_version_fail_before_actions
    [nil, "", "0", "000", "-1", "7 CURRENT_PROJECT_VERSION=8", "7$(id)"].each do |value|
      ENV["BUILD_NUMBER"] = value
      assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
      assert_empty @lane.actions
    end
    ENV["BUILD_NUMBER"] = "7"
    [nil, "", "1", "1.4.0$(id)", "1.4.0 CURRENT_PROJECT_VERSION=8"].each do |value|
      ENV["MARKETING_VERSION"] = value
      assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
      assert_empty @lane.actions
    end
  end

  def test_deferred_upload_requires_pinned_version_and_build_before_actions
    ENV["SILO_DEFER_TESTFLIGHT_DISTRIBUTION"] = "true"
    ENV.delete("BUILD_NUMBER")
    assert_raises(ArgumentError) { @lane.run_lane(:beta_ios) }
    assert_empty @lane.actions
    ENV["BUILD_NUMBER"] = "7"
    ENV.delete("MARKETING_VERSION")
    assert_raises(ArgumentError) { @lane.run_lane(:beta_ios) }
    assert_empty @lane.actions
  end

  def test_missing_external_groups_or_source_fail_before_actions
    ENV["TESTFLIGHT_EXTERNAL_GROUPS"] = " "
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    assert_empty @lane.actions
    ENV["TESTFLIGHT_EXTERNAL_GROUPS"] = "Public Beta"
    ENV.delete("SILO_RELEASE_SOURCE_URL")
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    assert_empty @lane.actions
    ENV["SILO_RELEASE_SOURCE_URL"] = "https://example.com/source.tar.gz"
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    assert_empty @lane.actions
  end

  def test_missing_ambiguous_or_wrong_type_groups_fail_before_distribution
    @group.name = "Different group"
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    refute Spaceship::ConnectAPI.calls.any? { |call| call.first == :distribute }
    @group.name = "Public Beta"
    Spaceship::ConnectAPI.test_app.groups << TestGroup.new("other", "Public Beta", false, [])
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    refute Spaceship::ConnectAPI.calls.any? { |call| call.first == :distribute }
    Spaceship::ConnectAPI.test_app.groups.pop
    @group.is_internal_group = true
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    refute Spaceship::ConnectAPI.calls.any? { |call| call.first == :distribute }
  end

  def test_group_can_be_selected_by_id
    ENV["TESTFLIGHT_EXTERNAL_GROUPS"] = @group.id
    @lane.run_lane(:distribute_ios)
    assert_equal [@group.id], distribution_options[:groups]
  end

  def test_processing_timeout_propagates_without_claiming_distribution
    Spaceship::ConnectAPI.test_wait_failure = RuntimeError.new("processing timeout")
    assert_raises(RuntimeError) { @lane.run_lane(:distribute_ios) }
    refute Spaceship::ConnectAPI.calls.any? { |call| call.first == :distribute }
  end

  def test_invalid_or_expired_build_does_not_pass_verification
    ["FAILED", "INVALID", "PROCESSING"].each do |state|
      @build.processing_state = state
      assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    end
    @build.processing_state = "VALID"
    @build.expired = true
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    refute Spaceship::ConnectAPI.calls.any? { |call| call.first == :distribute }
  end

  def test_mismatched_or_ambiguous_build_does_not_pass_verification
    @build.version = "8"
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    @build.version = "7"
    @build.platform = "TV_OS"
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    @build.platform = "IOS"
    @build.app_version = "1.5.0"
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    @build.app_version = "1.4.0"
    duplicate = @build.dup
    duplicate.id = "other-build"
    Spaceship::ConnectAPI.test_builds = [@build, duplicate]
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    refute Spaceship::ConnectAPI.calls.any? { |call| call.first == :distribute }
  end

  def test_equivalent_version_aliases_and_leading_zeros_keep_the_watched_build
    [["1.4.0", "1.4"], ["1.4", "1.4.0"], ["01.04.00", "1.4"]].each do |requested, canonical|
      ENV["MARKETING_VERSION"] = requested
      ENV["BUILD_NUMBER"] = "007"
      @build.app_version = canonical
      @lane.run_lane(:distribute_ios)
      assert_equal requested, distribution_options[:app_version]
      assert_same @build, Spaceship::ConnectAPI.calls.reverse.find { |call| call.first == :distribute }.last
    end
  end

  def test_wrong_refreshed_build_id_fails_verification
    Spaceship::ConnectAPI.test_refreshed_build = @build.dup
    Spaceship::ConnectAPI.test_refreshed_build.id = "different-build"
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
  end

  def test_missing_group_membership_or_notification_setting_fails_verification
    @group.builds = []
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    @group.builds = [@build]
    @build.build_beta_detail.auto_notify_enabled = false
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
    @build.build_beta_detail = nil
    assert_raises(ArgumentError) { @lane.run_lane(:distribute_ios) }
  end

  private

  def action_options(name)
    @lane.actions.reverse.find { |action, _| action == name }.last
  end

  def distribution_options
    Spaceship::ConnectAPI.calls.reverse.find { |call| call.first == :distribute }[1]
  end

  def assert_distribution_options(platform)
    options = distribution_options
    assert_equal "org.siloserver.silo", options[:app_identifier]
    assert_equal platform, options[:app_platform]
    assert_equal "1.4.0", options[:app_version]
    assert_equal "7", options[:build_number]
    assert_equal true, options[:distribute_only]
    assert_equal false, options[:skip_submission]
    assert_equal false, options[:skip_waiting_for_build_processing]
    assert_equal 900, options[:wait_processing_timeout_duration]
    assert_equal ["group-1"], options[:groups]
    assert_equal "Test release\n\nSource and rebuild instructions: #{SOURCE_URL}", options[:changelog]
    assert_equal true, options[:distribute_external]
    assert_equal true, options[:notify_external_testers]
    refute options.key?(:ipa)
  end
end
