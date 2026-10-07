#!/usr/bin/env ruby
# Verify package resolution/archive options without Xcode or network access.
require_relative "fastlane-test-helper"

class FastlaneCacheTest < Minitest::Test
  ENV_KEYS = %w[
    MARKETING_VERSION BUILD_NUMBER TEAM_ID SILO_SOURCE_PACKAGES_PATH
    SILO_DEFER_TESTFLIGHT_DISTRIBUTION TESTFLIGHT_DISTRIBUTION
    TESTFLIGHT_INTERNAL_GROUPS TESTFLIGHT_EXTERNAL_GROUPS
    TESTFLIGHT_NOTIFY_EXTERNAL_TESTERS TESTFLIGHT_CHANGELOG SILO_RELEASE_SOURCE_URL
    APP_STORE_CONNECT_API_KEY_KEY_ID APP_STORE_CONNECT_API_KEY_ISSUER_ID
    APP_STORE_CONNECT_API_KEY_KEY FL_ORIG_DEFAULT_KC FL_ORIG_KC_LIST FL_CI_KEYCHAIN_MANAGED
  ].freeze

  def setup
    @saved_env = ENV_KEYS.to_h { |key| [key, ENV[key]] }
    ENV_KEYS.each { |key| ENV.delete(key) }
    ENV.update(
      "MARKETING_VERSION" => "1.4.0", "BUILD_NUMBER" => "7", "TEAM_ID" => "TESTTEAM",
      "TESTFLIGHT_CHANGELOG" => "Test release", "TESTFLIGHT_DISTRIBUTION" => "internal",
      "APP_STORE_CONNECT_API_KEY_KEY_ID" => "TESTKEY",
      "APP_STORE_CONNECT_API_KEY_ISSUER_ID" => "test-issuer",
      "APP_STORE_CONNECT_API_KEY_KEY" => ["test-key"].pack("m0")
    )
    FastlaneCore::Helper.test_mac = false
    @lane = FastfileHarness.new
  end

  def teardown
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_package_download_path_is_shared_by_resolve_and_archive
    path = File.expand_path("work/SPM cache's (test)")
    ENV["SILO_SOURCE_PACKAGES_PATH"] = path
    @lane.run_lane(:beta_ios)
    resolves = @lane.actions.select { |action, args| action == :sh && args.first == "xcodebuild" }
    assert_equal 1, resolves.length
    args = resolves.first.last
    assert_equal path, args[args.index("-clonedSourcePackagesDirPath") + 1]
    assert_includes args, "-onlyUsePackageVersionsFromResolvedFile"
    assert_includes args, "-disableAutomaticPackageResolution"
    options = action_options(:build_app)
    assert_equal path, options[:cloned_source_packages_path]
    assert_equal true, options[:skip_package_dependencies_resolution]
    assert_equal true, options[:disable_package_automatic_updates]
    assert_equal true, options[:build_timing_summary]
    build_args = Shellwords.split(options[:xcargs])
    assert_includes build_args, "-onlyUsePackageVersionsFromResolvedFile"
    refute_includes build_args, "-clonedSourcePackagesDirPath"
  end

  def test_package_path_is_optional_for_local_lanes
    @lane.run_lane(:beta_ios)
    assert_nil action_options(:build_app)[:cloned_source_packages_path]
    resolve = @lane.actions.find { |action, args| action == :sh && args.first == "xcodebuild" }.last
    refute_includes resolve, "-clonedSourcePackagesDirPath"
  end

  def test_unsigned_archive_uses_the_same_locked_package_path_and_timing
    ENV["SILO_SOURCE_PACKAGES_PATH"] = File.expand_path("work/sideload packages")
    @lane.define_singleton_method(:package_unsigned_ipa) { |**_options| }
    @lane.run_lane(:ipa_tvos_unsigned)
    build_args = Shellwords.split(action_options(:xcodebuild)[:xcargs])
    assert_includes build_args, "-showBuildTimingSummary"
    assert_includes build_args, "-onlyUsePackageVersionsFromResolvedFile"
    assert_includes build_args, "-disableAutomaticPackageResolution"
    assert_equal ENV.fetch("SILO_SOURCE_PACKAGES_PATH"), build_args[build_args.index("-clonedSourcePackagesDirPath") + 1]
  end

  private

  def action_options(name)
    @lane.actions.reverse.find { |action, _| action == name }.last
  end
end
