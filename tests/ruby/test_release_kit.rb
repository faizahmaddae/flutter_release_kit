# Characterization tests for fastlane/Fastfile.
#
# The Fastfile is a fastlane DSL script, not a library, so it cannot simply be
# required. Instead this file stubs the handful of DSL entry points the Fastfile
# touches at LOAD time (UI, fastlane_version, lane, platform, ...) and then
# module_evals the real file into a plain Ruby module. The `def`s in the Fastfile
# become instance methods of that module, which makes every pure helper directly
# callable without fastlane installed.
#
# Lane bodies are never executed: `lane` and `private_lane` capture their block
# and drop it. `platform` does run its block, because all that block does is
# register more lanes.
#
# These tests pin what the Fastfile does TODAY, including a few places where
# today's behaviour is wrong. Those are called out in comments and deliberately
# NOT fixed here.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

REPO_ROOT = File.expand_path("../..", __dir__).freeze
FASTFILE_PATH = File.join(REPO_ROOT, "fastlane", "Fastfile").freeze

# The real class fastlane's `UI.user_error!` raises. The Fastfile names this
# constant in `rescue` clauses so a user error passes straight through a blanket
# `rescue StandardError`, and Ruby resolves a rescue class at match time — so the
# harness has to provide the real constant path, not a look-alike, or those
# clauses would blow up with NameError instead of matching. FastlaneUIError stays
# as the short alias every assertion in this file already uses.
module FastlaneCore
  module Interface
    class FastlaneError < StandardError; end
  end
end
FastlaneUIError = FastlaneCore::Interface::FastlaneError

module UI
  # Every call is recorded so a test can assert on what the user was actually
  # told, not just on what was raised. `UI.reset!` runs in setup.
  MESSAGES = []

  def self.messages
    MESSAGES
  end

  def self.reset!
    MESSAGES.clear
  end

  def self.record(level, text)
    MESSAGES << [level, text.to_s]
    nil
  end

  def self.user_error!(message)
    record(:user_error, message)
    raise FastlaneUIError, message.to_s
  end

  def self.abort_with_message!(message)
    record(:abort, message)
    raise FastlaneUIError, message.to_s
  end

  def self.message(*args); record(:message, args.first); end
  def self.important(*args); record(:important, args.first); end
  def self.success(*args); record(:success, args.first); end
  def self.error(*args); record(:error, args.first); end
  def self.header(*args); record(:header, args.first); end
  def self.verbose(*args); record(:verbose, args.first); end
end

module FastlaneCore
  module FastlaneFolder
    def self.path
      File.join(REPO_ROOT, "fastlane")
    end
  end
end

# Minimal stand-ins for the two Google gems `play_status` loads. Only the calls
# the Fastfile actually makes are modelled; the subject's `require` is stubbed to
# a no-op so the real gems are never touched.
module Google
  module Apis
    class ClientError < StandardError
      attr_accessor :status_code, :body
    end

    module AndroidpublisherV3
      AUTH_ANDROIDPUBLISHER = "https://www.googleapis.com/auth/androidpublisher".freeze

      class AndroidPublisherService
        class << self
          # Installed per test; `new` hands back that object.
          attr_accessor :stub
        end

        def self.new
          stub || raise("no AndroidPublisherService stub installed")
        end
      end
    end
  end

  module Auth
    module ServiceAccountCredentials
      class << self
        # The IO `play_status` handed us, kept so a test can check it was closed.
        attr_accessor :last_key_io
      end

      def self.make_creds(json_key_io:, scope:)
        self.last_key_io = json_key_io
        :stub_credentials
      end
    end
  end
end

# Stand-in for the spaceship gem, for `appstore_released_versions`.
module Spaceship
  module ConnectAPI
    class << self
      attr_accessor :token
    end

    module Token
      def self.create(**_api_key)
        :stub_token
      end
    end

    module App
      class << self
        # Installed per test: called with the bundle id, returns an app or raises.
        attr_accessor :finder
      end

      def self.find(bundle_id)
        finder ? finder.call(bundle_id) : nil
      end
    end

    # For `testflight_builds`, which lists builds directly rather than going
    # through the app object.
    module Build
      class << self
        # Installed per test: called with (app_id, sort, limit).
        attr_accessor :lister
      end

      def self.all(app_id:, sort:, limit:)
        lister ? lister.call(app_id, sort, limit) : []
      end
    end
  end
end

# Lane names the Fastfile registers, in load order, as "<platform>:<lane>".
REGISTERED_LANES = []

# Defined at the top level so they land on Object as private methods and can be
# called with an implicit receiver from inside the module_eval'd Fastfile.
def fastlane_version(*); end
def opt_out_usage(*); end
def skip_docs(*); end
def desc(*); end
def before_all(*); end
def after_all(*); end
def error(*); end

def lane(name, &_block)
  REGISTERED_LANES << [$current_platform, name].compact.join(":")
end

def private_lane(name, &_block)
  REGISTERED_LANES << [$current_platform, name].compact.join(":")
end

def platform(name, &block)
  $current_platform = name.to_s
  block.call
ensure
  $current_platform = nil
end

$current_platform = nil

module Harness; end
# Read as UTF-8 explicitly: the Fastfile has no magic comment, and a runner with
# an unset LANG would otherwise hand eval a US-ASCII string and choke on the
# em dashes in its comments.
Harness.module_eval(File.read(FASTFILE_PATH, encoding: "UTF-8"), FASTFILE_PATH, 1)

class ReleaseKitFastfileTest < Minitest::Test
  CONFIG_PATH = "fastlane/release_kit.yml".freeze

  # `version_args` falls back to <PREFIX>_BUILD_NAME / <PREFIX>_BUILD_NUMBER and
  # `store_versions_timeout` falls back to FRK_STORE_VERSIONS_TIMEOUT, so any of
  # these exported in the ambient environment (common on CI runners) would leak
  # into tests that assume they are unset. Clear them for every test and restore
  # afterwards; tests that want a value set it via `with_env`.
  CLEARED_ENV_KEYS = %w[
    ANDROID_BUILD_NAME
    ANDROID_BUILD_NUMBER
    IOS_BUILD_NAME
    IOS_BUILD_NUMBER
    FRK_STORE_VERSIONS_TIMEOUT
  ].freeze

  def setup
    @saved_version_env = CLEARED_ENV_KEYS.map { |k| [k, ENV[k]] }
    CLEARED_ENV_KEYS.each { |k| ENV.delete(k) }
    @tmpdirs = []
    UI.reset!
    Google::Apis::AndroidpublisherV3::AndroidPublisherService.stub = nil
    Google::Auth::ServiceAccountCredentials.last_key_io = nil
    Spaceship::ConnectAPI::App.finder = nil
    Spaceship::ConnectAPI::Build.lister = nil
    Spaceship::ConnectAPI.token = nil
  end

  def teardown
    @saved_version_env.each { |k, v| ENV[k] = v }
    @tmpdirs.each { |d| FileUtils.rm_rf(d) }
  end

  def tmpdir
    dir = Dir.mktmpdir("frk-fastfile-test")
    @tmpdirs << dir
    dir
  end

  # A helper object carrying a pre-seeded @config, so `config` never has to read
  # a real release_kit.yml off disk.
  def helper(config = {})
    obj = Object.new.extend(Harness)
    obj.instance_variable_set(:@config, config)
    obj
  end

  def android_helper(android = {})
    helper("name" => "demo", "platforms" => ["android"], "android" => android)
  end

  # `config` and `pubspec_version` are the two helpers that actually read the app
  # off disk, and they both resolve their path through `abs`. Overriding `abs` on
  # a bare subject (no pre-seeded @config) exercises the real file-reading code
  # against a throwaway directory.
  def disk_helper(files = {})
    dir = tmpdir
    files.each { |name, body| File.write(File.join(dir, name), body) }
    subject = Object.new.extend(Harness)
    subject.define_singleton_method(:abs) { |relative| File.join(dir, File.basename(relative)) }
    subject
  end

  def config_helper(yaml_text)
    disk_helper("release_kit.yml" => yaml_text)
  end

  # --- config -----------------------------------------------------------------

  # A syntax error in release_kit.yml is the single most likely user mistake.
  # It has to arrive as a fastlane user error naming the file, not as a raw
  # Psych::SyntaxError with a Ruby backtrace.
  def test_config_reports_a_yaml_syntax_error_as_a_user_error
    subject = config_helper("name: demo\nplatforms: [android\n")
    error = assert_raises(FastlaneUIError) { subject.config }
    assert_includes error.message, CONFIG_PATH
    assert_includes error.message, "did not find expected"
  end

  # Aliases and merge keys must behave the same on Psych 3 (system Ruby 2.6,
  # where the old YAML.load_file allowed them) and on Psych 4+ (where the same
  # call raises Psych::AliasesNotEnabled). Anchors are the documented way to
  # share settings between the android and ios blocks.
  def test_config_accepts_yaml_aliases_and_merge_keys
    subject = config_helper(<<~YML)
      defaults: &defaults
        track: internal
      name: demo
      platforms: [android]
      android:
        <<: *defaults
        package_name: com.demo.app
    YML
    assert_equal "internal", subject.config["android"]["track"]
    assert_equal "com.demo.app", subject.config["android"]["package_name"]
  end

  # Symbols are permitted today (YAML.load_file is unrestricted on Psych 3 and
  # permits Symbol on Psych 5), so the hardened loader must keep permitting them
  # or it would narrow the input this tool accepts.
  def test_config_still_permits_ruby_symbols
    subject = config_helper("name: demo\nmarker: !ruby/symbol internal\n")
    assert_equal :internal, subject.config["marker"]
  end

  def test_config_rejects_a_non_mapping_document
    subject = config_helper("- one\n- two\n")
    error = assert_raises(FastlaneUIError) { subject.config }
    assert_equal "#{CONFIG_PATH} is not a YAML mapping", error.message
  end

  def test_config_defaults_the_name_to_the_project_directory
    subject = config_helper("platforms: [android]\n")
    assert_equal File.basename(Harness::PROJECT_ROOT), subject.config["name"]
  end

  # --- pubspec_version --------------------------------------------------------

  def test_pubspec_version_reads_the_version_line
    assert_equal "1.2.3+4", disk_helper("pubspec.yaml" => "name: demo\nversion: 1.2.3+4\n").pubspec_version
  end

  # A missing pubspec.yaml has to be a user error naming the file, not an
  # Errno::ENOENT backtrace out of File.read.
  def test_pubspec_version_reports_a_missing_pubspec_as_a_user_error
    subject = disk_helper
    error = assert_raises(FastlaneUIError) { subject.pubspec_version }
    assert_includes error.message, "pubspec.yaml"
  end

  # --- pubspec_version_parts --------------------------------------------------

  def test_pubspec_version_parts_splits_name_from_build_number
    assert_equal ["1.2.3", "4"], version_helper("1.2.3+4").pubspec_version_parts
  end

  # No `+build` suffix: the number side is empty, NOT the whole version string.
  # Reading it as the version string is what silently disabled both
  # duplicate-version guards.
  def test_pubspec_version_parts_leaves_the_number_empty_without_a_suffix
    assert_equal ["1.2.3", ""], version_helper("1.2.3").pubspec_version_parts
  end

  # Must not raise: a pubspec with no `version:` still builds when both
  # overrides are supplied, and every caller relies on `||` short-circuiting
  # rather than on this method refusing to answer.
  def test_pubspec_version_parts_is_empty_rather_than_raising
    assert_equal ["", ""], version_helper("").pubspec_version_parts
  end

  def test_pubspec_version_parts_is_memoised
    subject = version_helper("1.2.3+4")
    first = subject.pubspec_version_parts
    assert_same first, subject.pubspec_version_parts
  end

  # --- load smoke -------------------------------------------------------------

  def test_fastfile_registers_the_documented_lanes
    assert_includes REGISTERED_LANES, "verify"
    assert_includes REGISTERED_LANES, "doctor"
    assert_includes REGISTERED_LANES, "upload_all"
    assert_includes REGISTERED_LANES, "store_versions"
    assert_includes REGISTERED_LANES, "android:release"
    assert_includes REGISTERED_LANES, "android:upload_internal"
    assert_includes REGISTERED_LANES, "ios:release"
    assert_includes REGISTERED_LANES, "ios:upload_testflight"
  end

  # --- android_track ----------------------------------------------------------

  def test_android_track_defaults_to_internal_when_key_absent
    assert_equal "internal", android_helper("package_name" => "com.demo").android_track
  end

  def test_android_track_defaults_to_internal_when_key_is_nil
    assert_equal "internal", android_helper("track" => nil).android_track
  end

  def test_android_track_accepts_the_three_testing_tracks
    assert_equal "internal", android_helper("track" => "internal").android_track
    assert_equal "alpha", android_helper("track" => "alpha").android_track
    assert_equal "beta", android_helper("track" => "beta").android_track
  end

  def test_android_track_strips_surrounding_whitespace
    assert_equal "beta", android_helper("track" => "  beta\n").android_track
  end

  def test_android_track_rejects_production
    error = assert_raises(FastlaneUIError) { android_helper("track" => "production").android_track }
    assert_equal(
      "#{CONFIG_PATH}: android.track must be one of internal, alpha, beta (got 'production')",
      error.message
    )
  end

  # The allow-list comparison is case sensitive, so a capitalised value is
  # rejected too -- but by the allow-list, not by any production-specific guard.
  def test_android_track_rejects_capitalised_production
    error = assert_raises(FastlaneUIError) { android_helper("track" => "Production").android_track }
    assert_equal(
      "#{CONFIG_PATH}: android.track must be one of internal, alpha, beta (got 'Production')",
      error.message
    )
  end

  # An empty string is truthy in Ruby, so `|| "internal"` does NOT kick in: the
  # track stays "" and is rejected by the allow-list rather than defaulting.
  def test_android_track_rejects_empty_string_instead_of_defaulting
    error = assert_raises(FastlaneUIError) { android_helper("track" => "").android_track }
    assert_equal(
      "#{CONFIG_PATH}: android.track must be one of internal, alpha, beta (got '')",
      error.message
    )
  end

  # Whitespace-only survives the same way: stripped to "", then rejected.
  def test_android_track_rejects_whitespace_only_value
    error = assert_raises(FastlaneUIError) { android_helper("track" => "   ").android_track }
    assert_equal(
      "#{CONFIG_PATH}: android.track must be one of internal, alpha, beta (got '')",
      error.message
    )
  end

  def test_android_track_reports_a_missing_android_section
    subject = helper("name" => "demo", "platforms" => ["android"])
    error = assert_raises(FastlaneUIError) { subject.android_track }
    assert_equal "#{CONFIG_PATH}: `android:` section is missing", error.message
  end

  # The second production guard lives inside the `upload_internal` lane body
  # (Fastfile:219), which these tests never execute -- lane blocks are captured
  # and dropped by the stub. android_track already refuses 'production' before
  # that guard could ever be reached, so the guard is currently dead code from
  # the point of view of any config that loads.
  def test_android_track_is_the_only_reachable_production_guard
    assert_raises(FastlaneUIError) { android_helper("track" => "production").android_track }
  end

  # --- validation_rejection ---------------------------------------------------

  def test_validation_rejection_explains_a_closed_version_train
    message = helper.validation_rejection(
      "ERROR ITMS-4000: Invalid Pre-Release Train. The train version '1.4.0' is closed."
    )
    refute_nil message
    assert_includes message, "the version train 1.4.0 is CLOSED"
    assert_includes message, "A higher build number will NOT help."
    assert_includes message, "fastlane ios release build_name:<higher than 1.4.0> build_number:1"
  end

  def test_validation_rejection_matches_the_closed_for_new_submissions_wording
    message = helper.validation_rejection("The train is closed for new build submissions")
    refute_nil message
    # No `train version '...'` in the text, so the placeholder is used.
    assert_includes message, "the version train this version is CLOSED"
  end

  def test_validation_rejection_explains_a_too_low_marketing_version
    message = helper.validation_rejection(
      "The bundle version must contain a higher version than that of the " \
      "previously approved version [2.3.1]."
    )
    refute_nil message
    assert_includes message, "higher than the already-approved version 2.3.1"
    assert_includes message, "fastlane ios release build_name:<higher than 2.3.1> build_number:1"
  end

  def test_validation_rejection_falls_back_when_the_approved_version_is_unparsable
    message = helper.validation_rejection(
      "must contain a higher version than that of the previously approved version"
    )
    refute_nil message
    assert_includes message, "higher than the already-approved version the released version"
  end

  def test_validation_rejection_returns_nil_for_an_unrelated_message
    assert_nil helper.validation_rejection("Connection reset by peer")
  end

  def test_validation_rejection_returns_nil_for_nil_and_empty
    assert_nil helper.validation_rejection(nil)
    assert_nil helper.validation_rejection("")
  end

  # --- version_args -----------------------------------------------------------

  # version_args reads pubspec.yaml through `pubspec_version`; stub it so the
  # tests do not depend on a Flutter project existing on disk.
  def version_helper(pubspec = "1.2.3+7")
    subject = helper
    subject.define_singleton_method(:pubspec_version) { pubspec }
    subject
  end

  def with_env(pairs)
    saved = pairs.keys.map { |k| [k, ENV[k]] }
    pairs.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  def test_version_args_is_empty_when_nothing_is_overridden
    assert_equal [], version_helper.version_args({}, "ANDROID")
  end

  def test_version_args_emits_both_flags_when_both_are_overridden
    args = version_helper.version_args({ build_name: "1.5.7", build_number: "57" }, "ANDROID")
    assert_equal ["--build-name=1.5.7", "--build-number=57"], args
  end

  # Only the explicitly supplied side becomes a flag; the other stays implicit.
  def test_version_args_emits_only_the_supplied_flag
    assert_equal ["--build-number=9"], version_helper.version_args({ build_number: "9" }, "ANDROID")
    assert_equal ["--build-name=2.0.0"], version_helper.version_args({ build_name: "2.0.0" }, "ANDROID")
  end

  # version_args emits raw values. Quoting is `flutter`'s job -- it escapes each
  # argv element that needs it -- so escaping here as well would double-escape.
  # The metacharacter is still neutralised one layer down; see
  # test_flutter_neutralises_a_metacharacter_in_a_version_value.
  def test_version_args_emits_raw_values_and_leaves_quoting_to_flutter
    args = version_helper.version_args({ build_name: "1.0.0-rc;rm" }, "ANDROID")
    assert_equal ["--build-name=1.0.0-rc;rm"], args
  end

  def test_version_args_falls_back_to_the_env_prefix
    with_env("IOS_BUILD_NAME" => "3.1.0", "IOS_BUILD_NUMBER" => "12") do
      assert_equal ["--build-name=3.1.0", "--build-number=12"], version_helper.version_args({}, "IOS")
    end
  end

  def test_version_args_prefers_options_over_env
    with_env("ANDROID_BUILD_NUMBER" => "99") do
      assert_equal ["--build-number=4"], version_helper.version_args({ build_number: "4" }, "ANDROID")
    end
  end

  def test_version_args_rejects_zero_build_number
    error = assert_raises(FastlaneUIError) do
      version_helper.version_args({ build_number: "0" }, "ANDROID")
    end
    assert_equal "Build number must be an integer between 1 and 2100000000 (got '0')", error.message
  end

  def test_version_args_rejects_a_non_numeric_build_number
    error = assert_raises(FastlaneUIError) do
      version_helper.version_args({ build_number: "abc" }, "ANDROID")
    end
    assert_equal "Build number must be an integer between 1 and 2100000000 (got 'abc')", error.message
  end

  def test_version_args_rejects_a_build_number_above_the_play_ceiling
    error = assert_raises(FastlaneUIError) do
      version_helper.version_args({ build_number: "2100000001" }, "ANDROID")
    end
    assert_equal(
      "Build number must be an integer between 1 and 2100000000 (got '2100000001')",
      error.message
    )
  end

  def test_version_args_accepts_the_play_ceiling_exactly
    assert_equal ["--build-number=2100000000"],
                 version_helper.version_args({ build_number: "2100000000" }, "ANDROID")
  end

  def test_version_args_rejects_a_build_name_containing_whitespace
    error = assert_raises(FastlaneUIError) do
      version_helper.version_args({ build_name: "1.0 beta" }, "ANDROID")
    end
    assert_equal "Build name cannot be empty or contain whitespace", error.message
  end

  # BUG PINNED AS-IS: a whitespace-only build_name is NOT rejected. It strips to
  # "" and is therefore treated as "not supplied", so the pubspec version is used
  # and no --build-name flag is emitted. The `effective_name.empty?` guard can
  # only fire when pubspec.yaml itself has no version.
  def test_version_args_treats_a_whitespace_only_build_name_as_unset
    assert_equal [], version_helper.version_args({ build_name: "   " }, "ANDROID")
  end

  def test_version_args_rejects_an_unparsable_pubspec_version
    error = assert_raises(FastlaneUIError) { version_helper("").version_args({}, "ANDROID") }
    assert_equal "Build name cannot be empty or contain whitespace", error.message
  end

  # pubspec.yaml with a version but no `+build` suffix. The message has to name
  # pubspec.yaml -- the generic integer complaint (got '') never told the user
  # which file to edit.
  def test_version_args_rejects_a_pubspec_version_without_a_build_number
    error = assert_raises(FastlaneUIError) { version_helper("1.2.3").version_args({}, "ANDROID") }
    assert_includes error.message, "pubspec.yaml"
    assert_includes error.message, "1.2.3"
    refute_includes error.message, "got ''"
  end

  # ...but only when nothing was overridden. A pubspec with no build number, or
  # no `version:` line at all, still builds when the caller supplies both sides.
  def test_version_args_accepts_a_pubspec_without_a_build_number_when_overridden
    assert_equal ["--build-number=8"],
                 version_helper("1.2.3").version_args({ build_number: "8" }, "ANDROID")
    assert_equal ["--build-name=2.0.0", "--build-number=8"],
                 version_helper("").version_args({ build_name: "2.0.0", build_number: "8" }, "ANDROID")
  end

  # --- ios_version ------------------------------------------------------------

  def test_ios_version_falls_back_to_the_pubspec_halves
    assert_equal ["1.2.3", "7"], version_helper.ios_version({})
  end

  # Without a `+build` suffix the number side is empty, not a repeat of the
  # version name. `warn_if_testflight_build_taken` gates on /\A\d+\z/, so a
  # marketing version that happens to be all digits used to be checked against
  # TestFlight as if it were a build number.
  def test_ios_version_leaves_the_number_empty_without_a_pubspec_suffix
    assert_equal ["1.2.3", ""], version_helper("1.2.3").ios_version({})
    assert_equal ["7", ""], version_helper("7").ios_version({})
  end

  def test_ios_version_prefers_options_then_env
    with_env("IOS_BUILD_NUMBER" => "12") do
      assert_equal ["9.9.9", "12"], version_helper.ios_version({ build_name: "9.9.9" })
    end
  end

  # --- flutter ----------------------------------------------------------------
  #
  # `flutter` joins argv itself rather than calling `Shellwords.shelljoin`,
  # because shelljoin's safe set excludes `=` and would echo every
  # `--flag=value` as `--flag\=value`. The call site passes no `log: false`, so
  # fastlane prints the raw string three times per build (the
  # `--- Step: ... ---` banner, the `$ <command>` line, and the lane summary
  # table), and those backslashes are visible in `frk build` / `frk release`
  # stdout.
  #
  # The pass-through set is /\A[A-Za-z0-9\-_.\/=+:@,]+\z/ -- Shellwords' own
  # safe set, minus the newline it tolerates, plus `=`. It is therefore never
  # more permissive than shelljoin on a character shelljoin already leaves
  # alone. Why each member is in it:
  #
  #   A-Z a-z 0-9  subcommands, flag names, version and build-number values
  #   -            flag prefixes (`--release`), semver prereleases (`1.0.0-rc.1`)
  #   _            identifiers, e.g. `--dart-define` keys
  #   .            version numbers, file extensions (`ExportOptions.plist`)
  #   /            app-relative paths (`build/symbols`, `ios/ExportOptions.plist`)
  #   =            the `--flag=value` form -- the whole point of not using
  #                shelljoin. `=` is literal inside an argument; it only means
  #                assignment in command position, and the command word here is
  #                always FLUTTER_BIN
  #   +            semver build metadata (`1.5.7+57`)
  #   :            URL- and namespace-shaped `--dart-define` values
  #   @            scoped package names, address-shaped `--dart-define` values
  #   ,            comma-separated flag lists (`--target-platform=a,b`)
  #
  # None of those can open a quote, start an expansion (`$`, backtick, leading
  # `~`), glob (`*?[]`), redirect, or separate commands (`;`, `&`, `|`,
  # newline), so passing a match through verbatim cannot widen argv. Everything
  # else -- whitespace, quotes, metacharacters, the empty string -- fails the
  # match and is shellescaped exactly once.
  #
  # Three tests hold that shape down:
  #   test_flutter_echoes_the_pre_varargs_command_strings  the echoed bytes
  #   test_flutter_leaves_safe_arguments_unescaped         no spurious escaping
  #   test_flutter_escapes_every_shell_metacharacter       no missing escaping

  # `flutter` shells out through fastlane's `sh`. Capture the command string it
  # would run instead of running it.
  def flutter_helper
    subject = version_helper
    captured = []
    subject.define_singleton_method(:sh) { |cmd, **_opts| captured << cmd; "" }
    subject.define_singleton_method(:captured) { captured }
    subject
  end

  def flutter_prefix
    "cd #{Harness::PROJECT_ROOT.shellescape} && #{Harness::FLUTTER_BIN.shellescape}"
  end

  # Call sites Fastfile:55, :184, :337.
  def test_flutter_builds_the_pub_get_command
    subject = flutter_helper
    subject.flutter("pub", "get")
    assert_equal "#{flutter_prefix} pub get", subject.captured.last
  end

  # Call site Fastfile:59.
  def test_flutter_builds_the_analyze_command
    subject = flutter_helper
    subject.flutter("analyze", "--no-fatal-infos", "--no-fatal-warnings")
    assert_equal "#{flutter_prefix} analyze --no-fatal-infos --no-fatal-warnings", subject.captured.last
  end

  # Call site Fastfile:60.
  def test_flutter_builds_the_test_command
    subject = flutter_helper
    subject.flutter("test")
    assert_equal "#{flutter_prefix} test", subject.captured.last
  end

  # Call site Fastfile:185, with obfuscation on and both version flags set.
  # `--flag=value` is echoed unescaped: `=` is literal inside an argument, so
  # quoting it would only add backslashes to the three places fastlane prints
  # this string.
  def test_flutter_builds_the_android_appbundle_command
    subject = flutter_helper
    args = ["build", "appbundle", "--release", "--obfuscate", "--split-debug-info=#{Harness::SYMBOLS_DIR}"]
    args.concat(subject.version_args({ build_name: "1.5.7", build_number: "57" }, "ANDROID"))
    subject.flutter(args)
    assert_equal(
      "#{flutter_prefix} build appbundle --release --obfuscate " \
      "--split-debug-info=build/symbols --build-name=1.5.7 --build-number=57",
      subject.captured.last
    )
  end

  # Call site Fastfile:185 again, obfuscation off and the version left to
  # pubspec.yaml -- the shape with nothing to escape at all.
  def test_flutter_builds_the_android_appbundle_command_without_flags
    subject = flutter_helper
    args = ["build", "appbundle", "--release"]
    args.concat(subject.version_args({}, "ANDROID"))
    subject.flutter(args)
    assert_equal "#{flutter_prefix} build appbundle --release", subject.captured.last
  end

  # Call site Fastfile:338.
  def test_flutter_builds_the_ios_ipa_command
    subject = flutter_helper
    args = ["build", "ipa", "--release", "--export-options-plist=#{Harness::EXPORT_OPTIONS}"]
    args.concat(subject.version_args({ build_name: "1.5.7", build_number: "57" }, "IOS"))
    subject.flutter(args)
    assert_equal(
      "#{flutter_prefix} build ipa --release " \
      "--export-options-plist=ios/ExportOptions.plist --build-name=1.5.7 --build-number=57",
      subject.captured.last
    )
  end

  # Call site Fastfile:338 with the version left to pubspec.yaml.
  def test_flutter_builds_the_ios_ipa_command_without_version_flags
    subject = flutter_helper
    args = ["build", "ipa", "--release", "--export-options-plist=#{Harness::EXPORT_OPTIONS}"]
    args.concat(subject.version_args({}, "IOS"))
    subject.flutter(args)
    assert_equal(
      "#{flutter_prefix} build ipa --release --export-options-plist=ios/ExportOptions.plist",
      subject.captured.last
    )
  end

  # The load-bearing invariant behind the join: whatever escaping it applies,
  # what the shell hands the process is byte-for-byte the argv the old
  # string-concatenation form produced.
  def test_flutter_escaping_leaves_the_parsed_argv_unchanged
    subject = flutter_helper
    version = subject.version_args({ build_name: "1.5.7", build_number: "57" }, "ANDROID")
    [
      [%w[pub get],
       %w[pub get]],
      [%w[analyze --no-fatal-infos --no-fatal-warnings],
       %w[analyze --no-fatal-infos --no-fatal-warnings]],
      [%w[test],
       %w[test]],
      [["build", "appbundle", "--release", "--obfuscate", "--split-debug-info=build/symbols", *version],
       ["build", "appbundle", "--release", "--obfuscate", "--split-debug-info=build/symbols",
        "--build-name=1.5.7", "--build-number=57"]],
      [["build", "appbundle", "--release"],
       ["build", "appbundle", "--release"]],
      [["build", "ipa", "--release", "--export-options-plist=ios/ExportOptions.plist", *version],
       ["build", "ipa", "--release", "--export-options-plist=ios/ExportOptions.plist",
        "--build-name=1.5.7", "--build-number=57"]],
      [["build", "ipa", "--release", "--export-options-plist=ios/ExportOptions.plist"],
       ["build", "ipa", "--release", "--export-options-plist=ios/ExportOptions.plist"]]
    ].each do |args, expected_tail|
      subject.flutter(args)
      assert_equal ["cd", Harness::PROJECT_ROOT, "&&", Harness::FLUTTER_BIN, *expected_tail],
                   Shellwords.split(subject.captured.last),
                   "argv drifted for #{args.inspect}"
    end
  end

  # version_args no longer escapes its values, so this is the layer that has to
  # neutralise a shell metacharacter -- and it does: the value arrives as one
  # argv element, not as a command separator.
  def test_flutter_neutralises_a_metacharacter_in_a_version_value
    subject = flutter_helper
    args = ["build", "appbundle", *subject.version_args({ build_name: "1.0.0-rc;rm" }, "ANDROID")]
    subject.flutter(args)
    assert_equal ["cd", Harness::PROJECT_ROOT, "&&", Harness::FLUTTER_BIN,
                  "build", "appbundle", "--build-name=1.0.0-rc;rm"],
                 Shellwords.split(subject.captured.last)
  end

  # Why every call site passes separate arguments rather than one pre-joined
  # string: the space is quoted, so a stray `flutter("pub get")` would ask for a
  # single subcommand literally named "pub get".
  def test_flutter_treats_a_pre_joined_string_as_one_argument
    subject = flutter_helper
    subject.flutter("pub get")
    assert_equal "#{flutter_prefix} pub\\ get", subject.captured.last
    assert_equal ["cd", Harness::PROJECT_ROOT, "&&", Harness::FLUTTER_BIN, "pub get"],
                 Shellwords.split(subject.captured.last)
  end

  # Byte-for-byte lock on the echoed command for all seven call sites, against
  # the strings the pre-varargs `flutter(args)` form produced. `flutter` calls
  # `sh` without `log: false`, so fastlane prints this string three times per
  # build (step banner, `$ <command>` line, lane summary) and any drift is
  # visible in `frk build` / `frk release` stdout.
  #
  # Expected values were recovered by re-running the previous implementation
  # (`sh(".. #{args}")` plus a `version_args` that shellescaped each value) --
  # not from memory.
  def test_flutter_echoes_the_pre_varargs_command_strings
    version = { build_name: "1.5.7", build_number: "57" }
    android = ["build", "appbundle", "--release", "--obfuscate",
               "--split-debug-info=#{Harness::SYMBOLS_DIR}"]
    ios = ["build", "ipa", "--release", "--export-options-plist=#{Harness::EXPORT_OPTIONS}"]

    [
      # Fastfile:55, :184, :337 -- was flutter("pub get")
      [["pub", "get"], "pub get"],
      # Fastfile:59 -- was flutter("analyze --no-fatal-infos --no-fatal-warnings")
      [["analyze", "--no-fatal-infos", "--no-fatal-warnings"],
       "analyze --no-fatal-infos --no-fatal-warnings"],
      # Fastfile:60 -- was flutter("test")
      [["test"], "test"],
      # Fastfile:185 -- was flutter(args.join(" ")), obfuscation on, versions set
      [[android, "--build-name=1.5.7", "--build-number=57"],
       "build appbundle --release --obfuscate --split-debug-info=build/symbols " \
       "--build-name=1.5.7 --build-number=57"],
      # Fastfile:185 -- obfuscation off, version left to pubspec.yaml
      [[["build", "appbundle", "--release"]], "build appbundle --release"],
      # Fastfile:338 -- was flutter(args.join(" ")), versions set
      [[ios, "--build-name=1.5.7", "--build-number=57"],
       "build ipa --release --export-options-plist=ios/ExportOptions.plist " \
       "--build-name=1.5.7 --build-number=57"],
      # Fastfile:338 -- version left to pubspec.yaml
      [[ios], "build ipa --release --export-options-plist=ios/ExportOptions.plist"]
    ].each do |args, expected_tail|
      subject = flutter_helper
      subject.flutter(*args)
      assert_equal "#{flutter_prefix} #{expected_tail}", subject.captured.last,
                   "echoed command drifted for #{args.inspect}"
    end
    # Guard the fixture itself: `version` is the options hash the two
    # version-flag shapes above stand for, so it must still produce them.
    assert_equal ["--build-name=1.5.7", "--build-number=57"],
                 version_helper.version_args(version, "ANDROID")
  end

  # No backslash reaches the echoed string for any argument built from the safe
  # set -- the specific regression the pre-varargs comparison above guards
  # against, stated as a property so a widened safe set cannot reintroduce it.
  def test_flutter_leaves_safe_arguments_unescaped
    subject = flutter_helper
    safe = ["--flag=value", "1.5.7+57", "build/symbols", "a,b", "https://x.test:8080",
            "user@host", "snake_case", "--no-fatal-infos"]
    subject.flutter(safe)
    assert_equal "#{flutter_prefix} #{safe.join(' ')}", subject.captured.last
    refute_includes subject.captured.last[flutter_prefix.length..-1], "\\"
  end

  # The other half of the property: anything carrying a shell metacharacter is
  # still escaped, exactly once, and still arrives as a single argv element.
  def test_flutter_escapes_every_shell_metacharacter
    hostile = [
      "1.0 beta",          # space
      "1.0.0-rc;rm",       # command separator
      "$(id)",             # command substitution
      "`id`",              # backtick substitution
      "a&b",               # background / and
      "a|b",               # pipe
      "a>b",               # redirect
      "it's",              # single quote
      'say"hi"',           # double quote
      "*.aab",             # glob
      "~root",             # tilde expansion
      "line\nbreak",       # newline
      ""                   # empty string must survive as an empty argv element
    ]
    hostile.each do |value|
      subject = flutter_helper
      subject.flutter("build", "appbundle", value)
      echoed = subject.captured.last
      assert_equal ["cd", Harness::PROJECT_ROOT, "&&", Harness::FLUTTER_BIN,
                    "build", "appbundle", value],
                   Shellwords.split(echoed),
                   "argv drifted for #{value.inspect}"
      # Escaped exactly once: a second round-trip is a fixed point, which a
      # double-escape (`\\;` for `;`) would fail.
      assert_equal Shellwords.split(echoed), Shellwords.split(Shellwords.join(Shellwords.split(echoed))),
                   "escaping was not idempotent for #{value.inspect}"
      refute_equal "build appbundle #{value}",
                   echoed[(flutter_prefix.length + 1)..-1],
                   "#{value.inspect} was passed through unquoted"
    end
  end

  # --- boolean vocabulary -----------------------------------------------------
  #
  # One vocabulary, used by both `truthy?` and `obfuscate?`. The two halves are
  # mirror images of each other: every YAML 1.1 boolean spelling a user could
  # reasonably write appears on exactly one side. They are listed here once and
  # the tables below drive every case off these two constants, so the halves
  # cannot drift apart again.
  #
  # Why quoted spellings matter: Psych resolves BARE `on`/`off`/`yes`/`no` to
  # real booleans before the Fastfile ever sees them, so the string branch is
  # reached only for the QUOTED forms -- `obfuscate: 'on'`. Those quoted forms
  # are exactly what an incomplete vocabulary turns into a release-stopping
  # error, which is why they are enumerated rather than sampled.
  TRUTHY_WORDS = %w[true yes y on 1].freeze
  FALSY_WORDS = %w[false no n off 0].freeze

  # as-written, upper case, capitalised, and surrounded by whitespace.
  def spelling_variants(word)
    [word, word.upcase, word.capitalize, "  #{word}  ", "\t#{word}\n"].uniq
  end

  # --- truthy? ----------------------------------------------------------------

  def test_truthy_accepts_every_truthy_spelling_in_every_casing
    subject = helper
    TRUTHY_WORDS.each do |word|
      spelling_variants(word).each do |value|
        assert_equal true, subject.truthy?(value),
                     "expected #{value.inspect} to be truthy"
      end
    end
  end

  def test_truthy_rejects_every_falsy_spelling_in_every_casing
    subject = helper
    FALSY_WORDS.each do |word|
      spelling_variants(word).each do |value|
        assert_equal false, subject.truthy?(value),
                     "expected #{value.inspect} to be falsey"
      end
    end
  end

  def test_truthy_accepts_non_string_equivalents
    subject = helper
    assert_equal true, subject.truthy?(true)
    assert_equal true, subject.truthy?(1)
    assert_equal true, subject.truthy?(:yes)
    assert_equal true, subject.truthy?(:on)
  end

  # Nothing outside the vocabulary is truthy. `truthy?` has no error branch --
  # its callers are opt-in skip flags, where "unrecognised" and "not set" both
  # mean "do the work", so an unknown word simply reads as false.
  def test_truthy_rejects_everything_outside_the_vocabulary
    subject = helper
    [nil, false, "", "  ", "True ish", "onward", "offer", 2, 0].each do |value|
      assert_equal false, subject.truthy?(value), "expected #{value.inspect} to be falsey"
    end
  end

  # --- obfuscate? -------------------------------------------------------------

  def test_obfuscate_defaults_to_true_when_the_key_is_absent
    assert_equal true, helper("name" => "demo").obfuscate?
  end

  def test_obfuscate_is_true_when_explicitly_true
    assert_equal true, helper("obfuscate" => true).obfuscate?
  end

  def test_obfuscate_is_false_when_explicitly_false
    assert_equal false, helper("obfuscate" => false).obfuscate?
  end

  # A bare `obfuscate:` line in release_kit.yml parses to nil. nil is "written
  # but left blank", which is not a request to turn obfuscation off, so it takes
  # the documented default. (Before: nil was present-but-falsey, `fetch`'s
  # default never applied, and the release shipped UNOBFUSCATED.)
  def test_obfuscate_defaults_to_true_for_a_blank_yaml_value
    parsed = YAML.load("obfuscate:\nname: demo\n")
    assert_nil parsed["obfuscate"]
    assert_equal true, helper(parsed).obfuscate?
  end

  # `obfuscate: ""` and `obfuscate: "   "` express no intent at all -- the same
  # situation as omitting the key or leaving the line blank -- so they take the
  # documented default rather than stopping the release. Erroring here would
  # reject a config that has said nothing wrong, only nothing at all.
  def test_obfuscate_defaults_to_true_for_an_empty_or_blank_string
    ["", "   ", "\t\n", YAML.load("obfuscate: ''\n")["obfuscate"]].each do |value|
      assert_equal true, helper("obfuscate" => value).obfuscate?,
                   "expected #{value.inspect} to fall back to the default"
    end
  end

  # obfuscate? and truthy? share one vocabulary, so the same word means the same
  # thing here as on every other flag in the file, in every casing.
  def test_obfuscate_is_true_for_every_truthy_spelling
    TRUTHY_WORDS.each do |word|
      spelling_variants(word).each do |value|
        assert_equal true, helper("obfuscate" => value).obfuscate?,
                     "expected #{value.inspect} to be treated as obfuscate=true"
      end
    end
  end

  def test_obfuscate_is_false_for_every_falsy_spelling
    FALSY_WORDS.each do |word|
      spelling_variants(word).each do |value|
        assert_equal false, helper("obfuscate" => value).obfuscate?,
                     "expected #{value.inspect} to be treated as obfuscate=false"
      end
    end
  end

  def test_obfuscate_accepts_non_string_equivalents
    assert_equal true, helper("obfuscate" => 1).obfuscate?
    assert_equal true, helper("obfuscate" => :yes).obfuscate?
    assert_equal false, helper("obfuscate" => 0).obfuscate?
    assert_equal false, helper("obfuscate" => :off).obfuscate?
  end

  # Anything outside both vocabularies is a typo, and guessing either way ships
  # the wrong artifact, so it stops the run instead. This is the branch that
  # keeps a misspelling from silently shipping an unobfuscated release.
  def test_obfuscate_rejects_a_value_that_is_neither_true_nor_false
    error = assert_raises(FastlaneUIError) { helper("obfuscate" => "maybe").obfuscate? }
    assert_includes error.message, CONFIG_PATH
    assert_includes error.message, "obfuscate"
    ["nope", "onward", "offer", "truthy", 2, -1, []].each do |value|
      assert_raises(FastlaneUIError, "expected #{value.inspect} to be rejected") do
        helper("obfuscate" => value).obfuscate?
      end
    end
  end

  # In practice release_kit.yml is parsed by Psych, which resolves the YAML 1.1
  # boolean words itself: BARE `on`/`off`/`yes`/`no` never reach the string
  # branch at all. Quoting is what routes a word through the vocabulary, and
  # single letters (`n`, `y`) never resolve, so they arrive as strings either
  # way. Both routes must agree, which is what this pins.
  def test_obfuscate_follows_yaml_scalar_resolution
    {
      "obfuscate: yes\n" => true,
      "obfuscate: 'yes'\n" => true,
      "obfuscate: on\n" => true,
      "obfuscate: 'on'\n" => true,
      "obfuscate: 'ON'\n" => true,
      "obfuscate: y\n" => true,
      "obfuscate: 'y'\n" => true,
      "obfuscate: true\n" => true,
      "obfuscate: '1'\n" => true,
      "obfuscate: no\n" => false,
      "obfuscate: 'no'\n" => false,
      "obfuscate: off\n" => false,
      "obfuscate: 'off'\n" => false,
      "obfuscate: 'OFF'\n" => false,
      "obfuscate: n\n" => false,
      "obfuscate: 'n'\n" => false,
      "obfuscate: false\n" => false,
      "obfuscate: '0'\n" => false
    }.each do |yaml, expected|
      assert_equal expected, helper(YAML.load(yaml)).obfuscate?,
                   "expected #{yaml.strip.inspect} to yield obfuscate=#{expected}"
    end
  end

  # --- extra_build_args --------------------------------------------------------

  def test_extra_build_args_is_empty_when_neither_source_is_set
    assert_equal [], helper("name" => "demo").extra_build_args("android")
    assert_equal [], helper("name" => "demo").extra_build_args("ios")
  end

  def test_extra_build_args_is_empty_for_an_explicit_empty_list
    assert_equal [], helper("extra_build_args" => []).extra_build_args("android")
  end

  def test_extra_build_args_returns_the_shared_list_for_every_platform
    flags = ["--dart-define=A=1", "--dart-define=B=2", "--flavor=prod"]
    assert_equal flags, helper("extra_build_args" => flags).extra_build_args("android")
    assert_equal flags, helper("extra_build_args" => flags).extra_build_args("ios")
  end

  # The actual case this exists for: one flag needed on Android and never on
  # iOS. Only `android:`'s own list carries it; iOS sees none of it.
  def test_extra_build_args_keeps_a_platform_only_flag_off_the_other_platform
    config = { "android" => { "extra_build_args" => ["--dart-define=ANDROID_ONLY=1"] } }
    assert_equal ["--dart-define=ANDROID_ONLY=1"], helper(config).extra_build_args("android")
    assert_equal [], helper(config).extra_build_args("ios")
  end

  # Shared and platform-only flags are additive, shared first, so a project
  # can have both a flag every build needs and one only Android needs.
  def test_extra_build_args_concatenates_shared_then_platform_own_in_order
    config = {
      "extra_build_args" => ["--dart-define=COMMON=1"],
      "android" => { "extra_build_args" => ["--dart-define=A=1"] },
      "ios" => { "extra_build_args" => ["--dart-define=I=1"] }
    }
    assert_equal ["--dart-define=COMMON=1", "--dart-define=A=1"], helper(config).extra_build_args("android")
    assert_equal ["--dart-define=COMMON=1", "--dart-define=I=1"], helper(config).extra_build_args("ios")
  end

  # A project with no other android/ios settings at all (a shape `platform_config`
  # itself would reject with "section is missing") must not raise here — that
  # precondition belongs to REQUIRED settings like package_name, not to this
  # optional one.
  def test_extra_build_args_does_not_require_the_platform_section_to_exist
    assert_equal [], helper("name" => "demo").extra_build_args("android")
    assert_equal ["--x"], helper("extra_build_args" => ["--x"]).extra_build_args("ios")
  end

  # The whole point of requiring a list is that `flutter(*args)` escapes each
  # ARRAY ELEMENT as its own shell token. A single string with several flags
  # run together would arrive as one unsplittable argument instead of two
  # flags, so this is rejected rather than guessed at (e.g. by splitting on
  # whitespace, which would reopen the injection risk array-based escaping
  # exists to close).
  def test_extra_build_args_rejects_a_bare_string_instead_of_a_list
    error = assert_raises(FastlaneUIError) { helper("extra_build_args" => "--dart-define=A=1").extra_build_args("android") }
    assert_includes error.message, CONFIG_PATH
    assert_includes error.message, "extra_build_args"
    assert_includes error.message, "list"
  end

  def test_extra_build_args_rejects_a_platform_own_list_with_a_bare_string
    config = { "android" => { "extra_build_args" => "--dart-define=A=1" } }
    error = assert_raises(FastlaneUIError) { helper(config).extra_build_args("android") }
    assert_includes error.message, CONFIG_PATH
    assert_includes error.message, "android.extra_build_args"
  end

  def test_extra_build_args_rejects_a_list_containing_a_non_string
    [[1], [nil], [true], [{ "a" => 1 }], ["--ok", 2]].each do |value|
      assert_raises(FastlaneUIError, "expected #{value.inspect} to be rejected") do
        helper("extra_build_args" => value).extra_build_args("android")
      end
      assert_raises(FastlaneUIError, "expected #{value.inspect} to be rejected") do
        helper("android" => { "extra_build_args" => value }).extra_build_args("android")
      end
    end
  end

  # --- export_options_plist ---------------------------------------------------

  def test_export_options_plist_exports_locally_rather_than_uploading
    plist = helper.export_options_plist("ABCDE12345", "com.demo.app")
    assert_includes plist, "<key>destination</key>\n    <string>export</string>"
  end

  def test_export_options_plist_keeps_the_flutter_baked_version_numbers
    plist = helper.export_options_plist("ABCDE12345", "com.demo.app")
    assert_includes plist, "<key>manageAppVersionAndBuildNumber</key>\n    <false/>"
  end

  def test_export_options_plist_pins_manual_signing_to_the_team_and_profile
    plist = helper.export_options_plist("ABCDE12345", "com.demo.app")
    assert_includes plist, "<key>method</key>\n    <string>app-store-connect</string>"
    assert_includes plist, "<key>teamID</key>\n    <string>ABCDE12345</string>"
    assert_includes plist, "<key>signingStyle</key>\n    <string>manual</string>"
    assert_includes plist, "<key>signingCertificate</key>\n    <string>Apple Distribution</string>"
    assert_includes plist, "<key>com.demo.app</key>\n        <string>com.demo.app AppStore</string>"
  end

  # The profile name written into the plist has to match what `ios setup_signing`
  # creates, or export picks a stale automatic profile.
  def test_export_options_plist_profile_name_matches_ios_profile_name
    subject = helper("name" => "demo", "platforms" => ["ios"], "ios" => { "bundle_id" => "com.demo.app" })
    assert_includes subject.export_options_plist("ABCDE12345", "com.demo.app"), subject.ios_profile_name
  end

  # --- play_status ------------------------------------------------------------

  # Records the Publishing API calls `play_status` makes, and can be told to fail
  # at `insert_edit` — the first call, and the one that raises in practice.
  class FakePlayService
    attr_reader :calls
    attr_accessor :authorization

    Edit    = Struct.new(:id)
    Track   = Struct.new(:releases)
    Release = Struct.new(:version_codes)
    Bundles = Struct.new(:bundles)
    Bundle  = Struct.new(:version_code)

    # The tracks listing carries release *names*; the plain `Release` above
    # deliberately does not, because a track release with no name is the case
    # `play_release_version_name` has to answer nil for.
    Tracks       = Struct.new(:tracks)
    TrackEntry   = Struct.new(:track, :releases)
    NamedRelease = Struct.new(:version_codes, :name)

    # `tracks:` accepts [{ track: "internal", releases: [{ codes: [38], name: "2.0.9 (38)" }] }],
    # or an Exception to make the extra listing call blow up on its own.
    def initialize(track_codes: [], bundle_codes: [], error: nil, tracks: nil)
      @track_codes  = track_codes
      @bundle_codes = bundle_codes
      @error        = error
      @tracks       = tracks
      @calls        = []
    end

    def insert_edit(package)
      @calls << [:insert_edit, package]
      raise @error if @error
      Edit.new("edit-1")
    end

    def get_edit_track(package, edit_id, track)
      @calls << [:get_edit_track, package, edit_id, track]
      Track.new([Release.new(@track_codes)])
    end

    def list_edit_bundles(package, edit_id)
      @calls << [:list_edit_bundles, package, edit_id]
      Bundles.new(@bundle_codes.map { |code| Bundle.new(code) })
    end

    def list_edit_tracks(package, edit_id)
      @calls << [:list_edit_tracks, package, edit_id]
      raise @tracks if @tracks.is_a?(Exception)

      entries = Array(@tracks).map do |entry|
        releases = Array(entry[:releases]).map { |r| NamedRelease.new(r[:codes], r[:name]) }
        TrackEntry.new(entry[:track], releases)
      end
      Tracks.new(entries)
    end

    def delete_edit(package, edit_id)
      @calls << [:delete_edit, package, edit_id]
      nil
    end
  end

  def install_play_service(service)
    Google::Apis::AndroidpublisherV3::AndroidPublisherService.stub = service
    service
  end

  # A subject whose `require` is a no-op, so `play_status` uses the stub gems
  # defined at the top of this file rather than loading the real ones.
  def play_helper(android = {})
    subject = android_helper({ "package_name" => "com.demo.app" }.merge(android))
    subject.define_singleton_method(:require) { |_name| false }
    subject
  end

  def play_key
    path = File.join(tmpdir, "play.json")
    File.write(path, %({"type":"service_account"}))
    path
  end

  def ui_important
    UI.messages.select { |level, _| level == :important }.map(&:last)
  end

  def test_play_status_reads_the_track_and_bundle_version_codes
    service = install_play_service(FakePlayService.new(track_codes: [7], bundle_codes: [9, 7]))
    status = play_helper.play_status(play_key)

    assert_equal true, status[:ok]
    assert_equal [7], status[:internal_codes]
    assert_equal [7, 9], status[:uploaded_codes]
    assert_equal %i[insert_edit get_edit_track list_edit_bundles delete_edit],
                 service.calls.map(&:first)
  end

  # The service-account key is opened only to build credentials. Without the
  # block form of File.open the handle stays open for the life of the process.
  def test_play_status_closes_the_service_account_key_file
    install_play_service(FakePlayService.new)
    play_helper.play_status(play_key)

    io = Google::Auth::ServiceAccountCredentials.last_key_io
    refute_nil io, "play_status never handed an IO to make_creds"
    assert_equal true, io.closed?, "play_status leaked the service-account key file descriptor"
  end

  # A misconfigured `android.track` is a user error raised by `android_track`,
  # not a Play failure. The blanket rescue used to turn it into a result hash,
  # which downgraded a fatal config mistake into "skipping the version-code
  # check" — see test_warn_if_version_code_not_higher_fails_fast_on_a_bad_track.
  def test_play_status_lets_a_config_user_error_through
    install_play_service(FakePlayService.new)
    error = assert_raises(FastlaneUIError) do
      play_helper("track" => "production").play_status(play_key)
    end
    assert_equal(
      "#{CONFIG_PATH}: android.track must be one of internal, alpha, beta (got 'production')",
      error.message
    )
  end

  # The other half: a genuine API refusal is still reported as a result hash, so
  # the re-raise did not widen into "every failure is now fatal".
  def test_play_status_still_reports_a_client_error_as_a_result_hash
    denied = Google::Apis::ClientError.new("Invalid request")
    denied.status_code = 403
    denied.body = %({"error":{"message":"The caller does not have permission"}})
    install_play_service(FakePlayService.new(error: denied))

    status = play_helper.play_status(play_key)
    assert_equal false, status[:ok]
    assert_equal true, status[:denied]
    assert_equal false, status[:missing]
    assert_equal 403, status[:status_code]
    assert_equal "The caller does not have permission", status[:message]
  end

  def test_play_status_still_reports_a_transport_error_as_a_result_hash
    install_play_service(FakePlayService.new(error: StandardError.new("getaddrinfo failed")))

    status = play_helper.play_status(play_key)
    assert_equal false, status[:ok]
    assert_equal false, status[:denied]
    assert_equal false, status[:missing]
    assert_nil status[:status_code]
    assert_equal "getaddrinfo failed", status[:message]
  end

  # --- warn_if_version_code_not_higher ----------------------------------------

  # This is called at Fastfile:207 precisely so a bad setup fails before the
  # multi-minute release build. A bad `android.track` used to be swallowed by
  # play_status, so the user paid for the whole build and only then hit the
  # track guard in the lane body.
  def test_warn_if_version_code_not_higher_fails_fast_on_a_bad_track
    install_play_service(FakePlayService.new)
    error = assert_raises(FastlaneUIError) do
      play_helper("track" => "production").warn_if_version_code_not_higher({ build_number: "5" }, play_key)
    end
    assert_equal(
      "#{CONFIG_PATH}: android.track must be one of internal, alpha, beta (got 'production')",
      error.message
    )
  end

  # A real Play failure still only warns — the check is best-effort by design.
  def test_warn_if_version_code_not_higher_still_skips_when_play_cannot_be_read
    missing = Google::Apis::ClientError.new("Invalid request")
    missing.status_code = 404
    missing.body = %({"error":{"message":"Package not found: com.demo.app"}})
    install_play_service(FakePlayService.new(error: missing))

    assert_nil play_helper.warn_if_version_code_not_higher({ build_number: "5" }, play_key)
    assert ui_important.any? { |text| text.include?("skipping the version-code check") },
           "expected the best-effort warning, got #{ui_important.inspect}"
  end

  def test_warn_if_version_code_not_higher_rejects_a_reused_version_code
    install_play_service(FakePlayService.new(bundle_codes: [5, 11]))
    error = assert_raises(FastlaneUIError) do
      play_helper.warn_if_version_code_not_higher({ build_number: "5" }, play_key)
    end
    assert_includes error.message, "versionCode 5 is already uploaded"
    assert_includes error.message, "fastlane android release build_number:12"
  end

  def test_warn_if_version_code_not_higher_accepts_a_higher_version_code
    install_play_service(FakePlayService.new(bundle_codes: [5, 11]))
    assert_nil play_helper.warn_if_version_code_not_higher({ build_number: "12" }, play_key)
  end

  # --- appstore_released_versions ---------------------------------------------

  def appstore_helper(ios = { "bundle_id" => "com.demo.app" })
    subject = helper("name" => "demo", "platforms" => ["ios"], "ios" => ios)
    subject.define_singleton_method(:require) { |_name| false }
    subject
  end

  # Same shape as play_status: `ios_bundle_id` raises a user error for a config
  # mistake, and the blanket rescue used to reduce it to a verbose log line and
  # an empty list, so the caller silently skipped its guard.
  def test_appstore_released_versions_lets_a_config_user_error_through
    subject = appstore_helper("team_id" => "ABCDE12345") # ios: present, bundle_id: missing
    error = assert_raises(FastlaneUIError) { subject.appstore_released_versions({}) }
    assert_equal "#{CONFIG_PATH}: `ios.bundle_id` is required", error.message
  end

  def test_appstore_released_versions_still_swallows_a_transport_error
    Spaceship::ConnectAPI::App.finder = ->(_id) { raise StandardError, "socket hang up" }
    assert_equal [], appstore_helper.appstore_released_versions({})
  end

  def test_appstore_released_versions_keeps_only_terminal_states
    version = Struct.new(:app_store_state, :version_string)
    app = Object.new
    app.define_singleton_method(:get_app_store_versions) do |limit:|
      [version.new("READY_FOR_SALE", "1.2.0"),
       version.new("PREPARE_FOR_SUBMISSION", "1.3.0"),
       version.new("PENDING_DEVELOPER_RELEASE", "1.4.0")]
    end
    Spaceship::ConnectAPI::App.finder = ->(_id) { app }

    assert_equal %w[1.2.0 1.4.0], appstore_helper.appstore_released_versions({})
  end

  # --- store_versions ---------------------------------------------------------
  #
  # The read-only "what does each store already hold" report. Two properties
  # matter more than any individual field, and both are asserted repeatedly
  # below because both are load-bearing for a caller that runs this
  # speculatively behind a spinner:
  #
  #   1. it NEVER raises — every failure becomes a status + detail;
  #   2. it never puts credential material in the payload.

  TFBuild = Struct.new(:app_version, :version, :processing_state)

  DEFAULT_STORE_CONFIG = {
    "name" => "example_app",
    "platforms" => %w[android ios],
    "android" => { "package_name" => "com.demo.app", "track" => "internal" },
    "ios" => { "bundle_id" => "com.demo.app", "team_id" => "ABCDE12345" }
  }.freeze

  # A subject with both credential lookups satisfied, so a test only has to say
  # what the *stores* answer. Either lookup can be replaced with a raiser to
  # exercise the no_credentials paths.
  def store_helper(config = DEFAULT_STORE_CONFIG)
    subject = helper(deep_dup(config))
    subject.define_singleton_method(:require) { |_name| false }
    key = play_key
    subject.define_singleton_method(:play_store_json_key) { key }
    subject.define_singleton_method(:asc_api_key) { { key_id: "STUBKEY123" } }
    subject
  end

  def deep_dup(value)
    case value
    when Hash then value.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
    when Array then value.map { |v| deep_dup(v) }
    else value
    end
  end

  # `build_error` fails the TestFlight half, `released_error` the App Store half,
  # `missing_app` makes the lookup answer nil the way Apple does for a bundle id
  # this key cannot see. The three are separate because the two halves of the iOS
  # report fail independently and must be reported independently.
  def install_appstore(builds: [], released: [], build_error: nil, released_error: nil, missing_app: false)
    version = Struct.new(:app_store_state, :version_string)
    app = Object.new
    app.define_singleton_method(:id) { "app-1" }
    app.define_singleton_method(:get_app_store_versions) do |limit:|
      raise released_error if released_error

      released.map { |v| version.new("READY_FOR_SALE", v) }
    end
    Spaceship::ConnectAPI::App.finder = missing_app ? ->(_id) { nil } : ->(_id) { app }
    Spaceship::ConnectAPI::Build.lister = lambda do |_app_id, _sort, _limit|
      raise build_error if build_error

      builds
    end
  end

  def internal_track(codes, name)
    [{ track: "internal", releases: [{ codes: codes, name: name }] }]
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  # Everything the lane would print, parsed back the way the CLI must parse it:
  # find the marker as a substring, take the rest of that line as JSON.
  def emitted_store_versions(subject, options = {})
    text = capture_stdout { subject.emit_store_versions_report(options) }
    marker = Harness::STORE_VERSIONS_MARKER
    lines = text.lines.select { |line| line.include?(marker) }
    assert_equal 1, lines.length, "expected exactly one marker line, got:\n#{text}"
    [JSON.parse(lines.last.split(marker, 2).last), text]
  end

  def test_store_versions_reports_both_stores_when_both_are_configured
    install_play_service(FakePlayService.new(track_codes: [38], bundle_codes: [37, 38],
                                             tracks: internal_track([38], "2.0.9 (38)")))
    install_appstore(builds: [TFBuild.new("2.1.0", "41", "PROCESSING"),
                              TFBuild.new("2.0.8", "40", "VALID")],
                     released: %w[2.0.8 2.0.2])

    report = store_helper.store_versions_report

    assert_equal "example_app", report["project"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, report["checkedAt"])

    android = report["android"]
    assert_equal "ok", android["status"]
    assert_equal "internal", android["track"]
    assert_equal 38, android["latestVersionCode"]
    assert_equal "2.0.9", android["latestVersionName"]
    assert_equal [{ "track" => "internal", "versionCode" => 38, "versionName" => "2.0.9" }], android["tracks"]

    ios = report["ios"]
    assert_equal "ok", ios["status"]
    assert_equal "2.0.8", ios["latestAppStoreVersion"]
    assert_equal([{ "version" => "2.1.0", "build" => 41, "state" => "PROCESSING" },
                  { "version" => "2.0.8", "build" => 40, "state" => "VALID" }], ios["builds"])
  end

  # Every platform object always carries both keys, whatever the status — a
  # client that has to branch on key existence gets this wrong at 2am.
  def test_store_versions_always_carries_status_and_detail
    install_play_service(FakePlayService.new)
    install_appstore

    %w[android ios].each do |platform|
      [DEFAULT_STORE_CONFIG,
       DEFAULT_STORE_CONFIG.merge("platforms" => ["android"]),
       DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"]),
       DEFAULT_STORE_CONFIG.merge("platforms" => [])].each do |config|
        state = store_helper(config).store_versions_report[platform]
        refute_nil state["status"], "#{platform} lost its status for #{config['platforms'].inspect}"
        refute_empty state["detail"].to_s, "#{platform} lost its detail for #{config['platforms'].inspect}"
      end
    end
  end

  def test_store_versions_reports_ios_as_unconfigured_for_an_android_only_project
    install_play_service(FakePlayService.new(bundle_codes: [12], tracks: internal_track([12], "1.0.0 (12)")))
    report = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report

    assert_equal "ok", report["android"]["status"]
    assert_equal "unconfigured", report["ios"]["status"]
    assert_includes report["ios"]["detail"], "does not list ios"
    assert_nil report["ios"]["latestAppStoreVersion"]
    assert_equal [], report["ios"]["builds"]
  end

  def test_store_versions_reports_android_as_unconfigured_for_an_ios_only_project
    install_appstore(builds: [TFBuild.new("1.0.0", "3", "VALID")])
    report = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"])).store_versions_report

    assert_equal "ok", report["ios"]["status"]
    assert_equal "unconfigured", report["android"]["status"]
    assert_includes report["android"]["detail"], "does not list android"
    assert_nil report["android"]["latestVersionCode"]
    assert_nil report["android"]["track"]
    assert_equal [], report["android"]["tracks"]
  end

  # `platforms` raises a user error on an empty list. The report has to survive
  # that: the desktop app calls this before it knows whether the project is even
  # onboarded, and a fastlane crash report is a worse answer than "not set up".
  def test_store_versions_survives_a_project_configured_for_neither_platform
    report = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => [])).store_versions_report

    assert_equal "unconfigured", report["android"]["status"]
    assert_equal "unconfigured", report["ios"]["status"]
    assert_includes report["android"]["detail"], "could not be read"
    assert_includes report["ios"]["detail"], "could not be read"
  end

  def test_store_versions_reports_no_credentials_when_the_play_key_is_missing
    install_appstore
    subject = store_helper
    subject.define_singleton_method(:play_store_json_key) do
      UI.user_error!("No Google Play service account key found.\nPut the JSON key in /Users/demo/.flutter-release/play")
    end

    android = subject.store_versions_report["android"]
    assert_equal "no_credentials", android["status"]
    assert_includes android["detail"], "fastlane android check_credentials"
    # The configured track is local knowledge, so it survives a missing key.
    assert_equal "internal", android["track"]
    assert_nil android["latestVersionCode"]
  end

  def test_store_versions_reports_no_credentials_when_the_app_store_key_is_missing
    install_play_service(FakePlayService.new)
    subject = store_helper
    subject.define_singleton_method(:asc_api_key) do
      UI.user_error!("App Store Connect API key is not configured.\nSet ASC_KEY_FILEPATH=/Users/demo/.flutter-release/asc/AuthKey_2X4B9QWERT.p8")
    end

    ios = subject.store_versions_report["ios"]
    assert_equal "no_credentials", ios["status"]
    assert_includes ios["detail"], "fastlane ios check_credentials"
    assert_equal [], ios["builds"]
  end

  def test_store_versions_reports_play_as_unavailable_when_the_call_raises
    install_play_service(FakePlayService.new(error: StandardError.new("getaddrinfo: nodename nor servname provided")))
    install_appstore

    report = store_helper.store_versions_report
    assert_equal "unavailable", report["android"]["status"]
    assert_includes report["android"]["detail"], "Could not read Google Play"
    assert_includes report["android"]["detail"], "getaddrinfo"
    assert_nil report["android"]["latestVersionCode"]
    # The other platform is unaffected: one dead store must not blank the report.
    assert_equal "ok", report["ios"]["status"]
  end

  def test_store_versions_reports_a_play_permission_failure_as_unavailable
    denied = Google::Apis::ClientError.new("Invalid request")
    denied.status_code = 403
    denied.body = %({"error":{"message":"The caller does not have permission"}})
    install_play_service(FakePlayService.new(error: denied))
    install_appstore

    android = store_helper.store_versions_report["android"]
    assert_equal "unavailable", android["status"]
    assert_includes android["detail"], "denied this service account access"
  end

  def test_store_versions_reports_app_store_connect_as_unavailable_when_the_call_raises
    install_play_service(FakePlayService.new)
    install_appstore(build_error: StandardError.new("socket hang up"))

    report = store_helper.store_versions_report
    assert_equal "unavailable", report["ios"]["status"]
    assert_includes report["ios"]["detail"], "Could not read App Store Connect"
    assert_includes report["ios"]["detail"], "socket hang up"
    assert_equal [], report["ios"]["builds"]
    assert_equal "ok", report["android"]["status"]
  end

  # A store error is the one place foreign text enters the payload, and store
  # errors are exactly where a service-account email or a key path shows up.
  def test_store_versions_never_emits_credential_material
    secrets = [
      "release-bot@my-project.iam.gserviceaccount.com",
      "/Users/demo/.flutter-release/asc/AuthKey_2X4B9QWERT.p8",
      "69a6de70-1234-47e3-e053-5b8c7c11a4d1",
      "2X4B9QWERT",
      "ya29.a0AfB0byABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    ]
    leak = "denied for #{secrets.join(' ')}"
    install_play_service(FakePlayService.new(error: StandardError.new(leak)))
    install_appstore(build_error: StandardError.new(leak))

    payload, text = emitted_store_versions(store_helper)
    json = JSON.generate(payload)

    secrets.each { |secret| refute_includes json, secret, "credential material reached the payload" }
    refute_match(/@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/, json, "an email address reached the payload")
    refute_includes json, "/Users/"
    refute_includes json, "BEGIN PRIVATE KEY"
    assert_includes json, "<redacted>"
    # And not in the human log lines either.
    secrets.each { |secret| refute_includes text, secret, "credential material reached stdout" }
    UI.messages.each do |_level, message|
      secrets.each { |secret| refute_includes message, secret, "credential material reached the fastlane log" }
    end
  end

  # Version numbers are never auto-incremented by this kit. The client computes
  # a suggestion and the user clicks it; a `next` field here would move that
  # decision into the machine.
  def test_store_versions_never_suggests_a_next_version
    install_play_service(FakePlayService.new(bundle_codes: [38], tracks: internal_track([38], "2.0.9 (38)")))
    install_appstore(builds: [TFBuild.new("2.1.0", "41", "VALID")], released: %w[2.0.8])

    payload, = emitted_store_versions(store_helper)
    json = JSON.generate(payload)
    refute_match(/"[^"]*(next|suggest|recommend|increment)[^"]*"\s*:/i, json,
                 "the report must carry facts only, no computed next version")
    assert_equal 39, payload["android"]["latestVersionCode"] + 1 # the client's job, not ours
  end

  def test_store_versions_emits_one_marker_line_the_cli_can_find
    install_play_service(FakePlayService.new(bundle_codes: [38], tracks: internal_track([38], "2.0.9 (38)")))
    install_appstore(builds: [TFBuild.new("2.1.0", "41", "PROCESSING")], released: %w[2.0.8])

    payload, text = emitted_store_versions(store_helper)
    line = text.lines.find { |l| l.include?(Harness::STORE_VERSIONS_MARKER) }

    assert line.start_with?("#{Harness::STORE_VERSIONS_MARKER} "), "marker must lead the line: #{line.inspect}"
    assert_equal 1, line.scan("\n").length, "the payload must be exactly one line"
    assert_equal %w[project checkedAt android ios], payload.keys
    assert_equal %w[status detail track latestVersionCode latestVersionName tracks], payload["android"].keys
    assert_equal %w[status detail latestAppStoreVersion builds], payload["ios"].keys
  end

  # The last line of fastlane's output is not the payload, and never was — this
  # is the parse the marker exists to prevent.
  def test_store_versions_marker_line_is_not_the_last_line_of_output
    install_play_service(FakePlayService.new)
    install_appstore
    text = capture_stdout do
      subject = store_helper
      subject.emit_store_versions_report({})
      $stdout.puts("[12:00:00]: fastlane.tools finished successfully")
    end
    refute text.lines.last.include?(Harness::STORE_VERSIONS_MARKER)
    assert text.lines.any? { |l| l.include?(Harness::STORE_VERSIONS_MARKER) }
  end

  def test_store_versions_reports_the_configured_track_first
    tracks = [
      { track: "beta", releases: [{ codes: [40], name: "2.1.0 (40)" }] },
      { track: "internal", releases: [{ codes: [38], name: "2.0.9 (38)" }] },
      { track: "alpha", releases: [{ codes: [39], name: "2.0.9 (39)" }] }
    ]
    install_play_service(FakePlayService.new(bundle_codes: [40], tracks: tracks))
    install_appstore

    android = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report["android"]
    assert_equal %w[internal alpha beta], android["tracks"].map { |t| t["track"] }
    assert_equal 40, android["latestVersionCode"]
    # The name has to belong to the code beside it, which here is beta's, not
    # the configured track's.
    assert_equal "2.1.0", android["latestVersionName"]
  end

  # Empty tracks are dropped rather than reported with a null code: a blank
  # entry reads like a failed read.
  def test_store_versions_omits_tracks_with_no_release
    tracks = [
      { track: "internal", releases: [{ codes: [38], name: "2.0.9 (38)" }] },
      { track: "beta", releases: [] }
    ]
    install_play_service(FakePlayService.new(bundle_codes: [38], tracks: tracks))
    android = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report["android"]
    assert_equal ["internal"], android["tracks"].map { |t| t["track"] }
  end

  # Play exposes no versionName anywhere, only the release's display name, so
  # an unparseable name has to be null rather than a guess.
  def test_store_versions_reports_a_null_version_name_when_play_has_no_parseable_one
    install_play_service(FakePlayService.new(bundle_codes: [38],
                                             tracks: [{ track: "internal",
                                                        releases: [{ codes: [38], name: "October hotfix" }] }]))
    android = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report["android"]
    assert_equal 38, android["latestVersionCode"]
    assert_nil android["latestVersionName"]
  end

  def test_store_versions_reports_no_version_code_as_null_rather_than_zero
    install_play_service(FakePlayService.new)
    android = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report["android"]

    assert_equal "ok", android["status"]
    assert_nil android["latestVersionCode"]
    assert_equal [], android["tracks"]
    assert_includes android["detail"], "no version code"
  end

  # A failure of the extra tracks listing must not lose the version codes the
  # release path already depended on.
  def test_store_versions_still_reports_codes_when_the_track_listing_fails
    install_play_service(FakePlayService.new(bundle_codes: [38], tracks: StandardError.new("tracks unavailable")))
    android = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report["android"]

    assert_equal "ok", android["status"]
    assert_equal 38, android["latestVersionCode"]
    assert_equal [], android["tracks"]
  end

  # The configured track is read directly by `play_status` (get_edit_track) and
  # comes back as `internal_codes`, so it is known even when the extra all-tracks
  # listing fails. Deriving it from that listing instead made a failed read print
  # "the configured track holds no release" — a fact nothing ever read, and one
  # that sends the user straight into a duplicate version code.
  def test_store_versions_reports_the_configured_track_it_read_when_the_track_listing_fails
    install_play_service(FakePlayService.new(track_codes: [38], bundle_codes: [38],
                                             tracks: StandardError.new("tracks unavailable")))
    android = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report["android"]

    assert_equal "ok", android["status"]
    refute_includes android["detail"], "holds no release"
    assert_includes android["detail"], "the configured 'internal' track is at 38"
    assert_equal [{ "track" => "internal", "versionCode" => 38, "versionName" => nil }], android["tracks"]
  end

  # The other half of the same rule: "holds no release" is only sayable because
  # get_edit_track answered, and it answered with nothing.
  def test_store_versions_says_the_configured_track_is_empty_only_from_a_read_that_succeeded
    install_play_service(FakePlayService.new(track_codes: [], bundle_codes: [38],
                                             tracks: [{ track: "beta", releases: [{ codes: [38], name: "2.0.9 (38)" }] }]))
    android = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"])).store_versions_report["android"]

    assert_equal "ok", android["status"]
    assert_includes android["detail"], "the configured 'internal' track holds no release"
    assert_equal ["beta"], android["tracks"].map { |t| t["track"] }
  end

  def test_store_versions_reports_a_play_timeout_as_unavailable
    install_appstore
    subject = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"]))
    subject.define_singleton_method(:play_status) { |_key, **_opts| raise Timeout::Error }

    android = subject.store_versions_report["android"]
    assert_equal "unavailable", android["status"]
    assert_equal "Google Play did not answer within 60 seconds.", android["detail"]
    # Local knowledge survives a store that never answered; store facts do not.
    assert_equal "internal", android["track"]
    assert_nil android["latestVersionCode"]
    assert_equal [], android["tracks"]
  end

  # `include_tracks:` defaults to off, so the release path makes exactly the
  # calls it made before this lane existed.
  def test_play_status_does_not_list_tracks_unless_asked
    service = install_play_service(FakePlayService.new(tracks: internal_track([38], "2.0.9 (38)")))
    status = play_helper.play_status(play_key)

    refute_includes service.calls.map(&:first), :list_edit_tracks
    assert_equal [], status[:tracks]
  end

  # Apple accepts a dotted CFBundleVersion. The contract wants a number or null,
  # and turning "1.2.3" into 1 would fabricate a build number in the one report
  # whose purpose is preventing a wrong one.
  def test_store_versions_reports_a_non_integer_build_number_as_null
    install_appstore(builds: [TFBuild.new("2.1.0", "1.2.3", "VALID")])
    ios = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"])).store_versions_report["ios"]

    assert_equal [{ "version" => "2.1.0", "build" => nil, "state" => "VALID" }], ios["builds"]
  end

  # `latest_testflight_build_number` only sees builds that finished processing,
  # so straight after an upload it reports the previous one. The report has to
  # show the build that just landed, with its state.
  def test_store_versions_includes_builds_that_are_still_processing
    install_appstore(builds: [TFBuild.new("2.1.0", "41", "PROCESSING"), TFBuild.new("2.1.0", "40", "VALID")])
    ios = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"])).store_versions_report["ios"]

    assert_equal 41, ios["builds"].first["build"]
    assert_equal "PROCESSING", ios["builds"].first["state"]
    assert_includes ios["detail"], "PROCESSING"
  end

  def test_store_versions_picks_the_highest_released_version_not_the_last_string
    install_appstore(builds: [], released: %w[2.0.9 2.0.10 1.9.9])
    ios = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"])).store_versions_report["ios"]

    assert_equal "2.0.10", ios["latestAppStoreVersion"]
    assert_includes ios["detail"], "no builds"
  end

  # The App Store half is read by `appstore_released_versions`, which is
  # best-effort and answers [] for any failure. Treating that [] as an answer
  # made a 503 read out as "nothing has been released on the App Store yet",
  # which is how a user picks a version number that is already taken.
  def test_store_versions_never_reports_an_unreadable_app_store_as_nothing_released
    install_play_service(FakePlayService.new)
    install_appstore(builds: [TFBuild.new("2.1.0", "41", "VALID")],
                     released_error: StandardError.new("503 backend error"))

    ios = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"])).store_versions_report["ios"]

    assert_equal "unavailable", ios["status"]
    refute_includes ios["detail"], "nothing has been released"
    assert_includes ios["detail"], "503 backend error"
    assert_nil ios["latestAppStoreVersion"]
    # The half that did answer is still reported: a partial answer beats none,
    # as long as the detail says which half is missing.
    assert_equal [{ "version" => "2.1.0", "build" => 41, "state" => "VALID" }], ios["builds"]
    assert_includes ios["detail"], "build 41"
  end

  # An app the key cannot see is not an app that has never shipped.
  def test_store_versions_never_reports_an_invisible_app_as_nothing_released
    install_appstore(missing_app: true)
    ios = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"])).store_versions_report["ios"]

    assert_equal "unavailable", ios["status"]
    refute_includes ios["detail"], "nothing has been released"
    assert_nil ios["latestAppStoreVersion"]
  end

  # And the inverse: the App Store half answering is not lost because TestFlight
  # failed. Each half stands on its own.
  def test_store_versions_keeps_the_app_store_half_when_testflight_fails
    install_appstore(released: %w[2.0.8], build_error: StandardError.new("socket hang up"))
    ios = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"])).store_versions_report["ios"]

    assert_equal "unavailable", ios["status"]
    assert_equal "2.0.8", ios["latestAppStoreVersion"]
    assert_equal [], ios["builds"]
    assert_includes ios["detail"], "socket hang up"
    assert_includes ios["detail"], "the latest App Store release is 2.0.8"
  end

  def test_store_versions_reports_an_app_store_connect_timeout_as_unavailable
    install_play_service(FakePlayService.new)
    subject = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"]))
    subject.define_singleton_method(:testflight_builds) { |_key, **_opts| raise Timeout::Error }

    ios = subject.store_versions_report["ios"]
    assert_equal "unavailable", ios["status"]
    assert_equal "App Store Connect did not answer within 60 seconds.", ios["detail"]
    assert_nil ios["latestAppStoreVersion"]
    assert_equal [], ios["builds"]
  end

  # The deadline belongs to the whole iOS section, so it can fall between the two
  # halves. The half that got in before it still counts.
  def test_store_versions_reports_a_deadline_that_falls_between_the_two_ios_reads
    subject = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["ios"]))
    subject.define_singleton_method(:testflight_builds) { |_key, **_opts| [TFBuild.new("2.1.0", "41", "VALID")] }
    subject.define_singleton_method(:appstore_released_versions!) { |_key| raise Timeout::Error }

    ios = subject.store_versions_report["ios"]
    assert_equal "unavailable", ios["status"]
    assert_equal 41, ios["builds"].first["build"]
    assert_nil ios["latestAppStoreVersion"]
    refute_includes ios["detail"], "nothing has been released"
    assert_includes ios["detail"], "60 seconds"
  end

  # --- store_versions_timeout ---------------------------------------------------

  def test_store_versions_timeout_defaults_to_the_documented_budget
    assert_equal Harness::STORE_VERSIONS_TIMEOUT_SECONDS, helper.store_versions_timeout({})
    assert_equal Harness::STORE_VERSIONS_TIMEOUT_SECONDS, helper.store_versions_timeout(nil)
  end

  def test_store_versions_timeout_prefers_the_option_over_the_environment
    with_env("FRK_STORE_VERSIONS_TIMEOUT" => "120") do
      assert_equal 5, helper.store_versions_timeout(timeout: "5")
    end
  end

  def test_store_versions_timeout_reads_the_environment_when_no_option_is_given
    with_env("FRK_STORE_VERSIONS_TIMEOUT" => "12") do
      assert_equal 12, helper.store_versions_timeout({})
    end
  end

  # A zero or negative budget would make Timeout.timeout mean "no deadline at
  # all", which is the one thing this number exists to prevent.
  def test_store_versions_timeout_falls_back_for_a_non_positive_or_unreadable_value
    ["0", "-3", "soon", ""].each do |raw|
      with_env("FRK_STORE_VERSIONS_TIMEOUT" => raw) do
        assert_equal Harness::STORE_VERSIONS_TIMEOUT_SECONDS, helper.store_versions_timeout({}),
                     "#{raw.inspect} must fall back to the default budget"
      end
    end
  end

  # The option has to survive all the way into the sentence the user reads.
  def test_store_versions_reports_the_budget_it_was_given
    install_appstore
    subject = store_helper(DEFAULT_STORE_CONFIG.merge("platforms" => ["android"]))
    subject.define_singleton_method(:play_status) { |_key, **_opts| raise Timeout::Error }

    android = subject.store_versions_report(timeout: "5")["android"]
    assert_equal "Google Play did not answer within 5 seconds.", android["detail"]
  end

  # --- store_versions_fallback_report -------------------------------------------

  def test_store_versions_fallback_report_answers_both_platforms
    report = helper.store_versions_fallback_report(StandardError.new("release_kit.yml is unreadable"))

    assert_equal %w[project checkedAt android ios], report.keys
    assert_equal %w[status detail track latestVersionCode latestVersionName tracks], report["android"].keys
    assert_equal %w[status detail latestAppStoreVersion builds], report["ios"].keys
    assert_equal %w[unconfigured unconfigured], [report["android"]["status"], report["ios"]["status"]]
    assert_includes report["android"]["detail"], "release setup could not be read"
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, report["checkedAt"])
    refute_empty report["project"].to_s
  end

  # The error it quotes came from outside, so it goes through the same redaction
  # as every other foreign string.
  def test_store_versions_fallback_report_redacts_the_error_it_quotes
    error = StandardError.new("could not read /Users/demo/.flutter-release/play/key.json")
    report = helper.store_versions_fallback_report(error)

    refute_includes report["android"]["detail"], "/Users/demo"
    assert_includes report["android"]["detail"], "<redacted>"
  end

  # --- emit_store_versions_report -----------------------------------------------

  # The never-raises guarantee is about the marker line reaching stdout, so it
  # has to cover everything between building the report and printing it — the
  # two log lines included. A client is blocked on that line.
  def test_emit_store_versions_report_emits_the_marker_even_when_the_log_lines_raise
    subject = store_helper
    subject.define_singleton_method(:store_versions_report) { |_options| { "project" => "demo" } }

    payload, = emitted_store_versions(subject)
    assert_equal "demo", payload["project"]
  end

  def test_emit_store_versions_report_emits_a_readable_marker_when_the_report_will_not_serialise
    subject = store_helper
    # Invalid UTF-8 out of a store error is the realistic way JSON.generate
    # refuses a report this file built.
    malformed = "\xC3".dup.force_encoding("UTF-8")
    subject.define_singleton_method(:store_versions_report) do |_options|
      {
        "project" => malformed,
        "checkedAt" => "2026-08-08T09:41:07.412Z",
        "android" => { "status" => "ok", "detail" => "fine" },
        "ios" => { "status" => "ok", "detail" => "fine" }
      }
    end

    payload, = emitted_store_versions(subject)
    assert_equal "unavailable", payload["android"]["status"]
    assert_equal "unavailable", payload["ios"]["status"]
    refute_empty payload["ios"]["detail"].to_s
  end

  def test_store_versions_reports_a_missing_release_kit_yml_without_raising
    subject = disk_helper # no release_kit.yml on disk at all
    report = nil
    capture_stdout { report = subject.emit_store_versions_report({}) }

    assert_equal "unconfigured", report["android"]["status"]
    assert_equal "unconfigured", report["ios"]["status"]
    refute_empty report["project"].to_s
  end

  # --- upload_to_testflight_with_retry ----------------------------------------

  # Drives the retry loop with every Apple-facing call stubbed. Each entry in
  # `uploads` is one attempt's outcome:
  #   :ok                    the upload returns normally
  #   an Exception           it raises straight away
  #   [:stall, exception]    it blocks until the watchdog cancels the transfer,
  #                          which is what sets the loop's `timed_out` flag, and
  #                          only then raises
  # `timeout_minutes` is deliberately fractional so the watchdog fires in
  # milliseconds; the stall handshake makes the ordering deterministic rather
  # than time-dependent.
  def testflight_helper(uploads, attempts: uploads.length, timeout_minutes: 0.005, has_build: false)
    subject = helper("name" => "demo", "platforms" => ["ios"], "ios" => { "bundle_id" => "com.demo.app" })
    queue   = uploads.dup
    killed  = Queue.new
    checks  = []

    subject.define_singleton_method(:ios_upload_attempts) { attempts }
    subject.define_singleton_method(:ios_upload_timeout_minutes) { timeout_minutes }
    # `|*|`, not `||`: kill_transporter! is handed the pre-upload PID snapshot,
    # and a define_method block enforces arity.
    subject.define_singleton_method(:kill_transporter!) { |*| killed << true }
    subject.define_singleton_method(:killed) { killed }
    # The retry loop takes a PID snapshot before the first attempt. Stubbed so
    # the retry tests never shell out; `pgrep` itself is covered separately.
    subject.define_singleton_method(:transporter_pids) { [] }
    subject.define_singleton_method(:checks) { checks }
    subject.define_singleton_method(:testflight_has_build?) do |_api_key, _version, _number, **opts|
      checks << opts
      has_build
    end
    subject.define_singleton_method(:upload_to_testflight) do |**_args|
      outcome = queue.shift
      case outcome
      when :ok   then nil
      when Array then killed.pop && raise(outcome[1])
      else raise outcome
      end
    end
    subject
  end

  def run_testflight_retry(subject)
    subject.upload_to_testflight_with_retry(
      api_key: {}, ipa: "build/app.ipa", version: "1.2.3", number: "7",
      wait: false, changelog: nil
    )
  end

  def test_testflight_retry_returns_as_soon_as_an_upload_succeeds
    subject = testflight_helper([:ok])
    assert_nil run_testflight_retry(subject)
    assert_empty subject.checks, "a successful upload must not poll App Store Connect"
    assert UI.messages.include?([:success, "Uploaded 1.2.3 (7) to TestFlight in 0s"]),
           UI.messages.inspect
  end

  # The long poll after a plain failure: 20 checks at 30s. Pinned because it is a
  # deliberate response to an observed 465-second App Store Connect lag, not an
  # arbitrary number.
  def test_testflight_retry_accepts_a_build_that_landed_despite_the_error
    subject = testflight_helper([StandardError.new("Connection reset by peer")], has_build: true)
    assert_nil run_testflight_retry(subject)
    assert_equal [{ attempts: 20, delay: 30 }], subject.checks
  end

  # The watchdog path uses the short poll: the bytes either arrived before the
  # cancel or they did not.
  def test_testflight_retry_accepts_a_build_that_landed_before_the_cancel
    subject = testflight_helper([[:stall, StandardError.new("The request timed out.")]], has_build: true)
    assert_nil run_testflight_retry(subject)
    assert_equal [{ attempts: 2, delay: 20 }], subject.checks
  end

  # A cancelled attempt used to print only "exceeded N min — cancelling"; the
  # exception that came back was dropped on the floor, so the one line naming the
  # real problem never reached the user.
  def test_testflight_retry_reports_why_a_cancelled_attempt_failed
    subject = testflight_helper(
      [[:stall, StandardError.new("NSURLErrorDomain -1005 the network connection was lost")]],
      attempts: 1
    )
    assert_raises(FastlaneUIError) { run_testflight_retry(subject) }
    assert ui_important.any? { |text| text.include?("NSURLErrorDomain -1005 the network connection was lost") },
           "the cancelled attempt never said why it failed: #{ui_important.inspect}"
    assert_equal [{ attempts: 2, delay: 20 }], subject.checks
  end

  # A recognised App Store Connect rejection is final on the plain-failure path.
  def test_testflight_retry_treats_a_rejection_as_final
    rejection = "ERROR ITMS-4000: Invalid Pre-Release Train. The train version '1.4.0' is closed."
    subject = testflight_helper([StandardError.new(rejection)], attempts: 3)

    error = assert_raises(FastlaneUIError) { run_testflight_retry(subject) }
    assert_includes error.message, "the version train 1.4.0 is CLOSED"
    assert_empty subject.checks, "a recognised rejection must not poll App Store Connect"
  end

  # ...and just as final when the watchdog happened to fire first. Apple's
  # refusal does not become retryable because our own timer expired: the check
  # has to run before the timed_out branch, not inside its else.
  def test_testflight_retry_treats_a_rejection_as_final_even_after_a_cancel
    rejection = "ERROR ITMS-4000: Invalid Pre-Release Train. The train version '1.4.0' is closed."
    subject = testflight_helper(
      [[:stall, StandardError.new(rejection)], [:stall, StandardError.new(rejection)]]
    )

    error = assert_raises(FastlaneUIError) { run_testflight_retry(subject) }
    assert_includes error.message, "the version train 1.4.0 is CLOSED"
    assert_empty subject.checks, "a recognised rejection must not poll App Store Connect"
  end

  # Every attempt failed for an unrecognised reason. The give-up message used to
  # blame Apple's transport and show none of the exceptions, so a revoked key or
  # an invalid binary read as "stalled again".
  def test_testflight_retry_reports_the_last_error_after_giving_up
    subject = testflight_helper([
      StandardError.new("Your Apple ID has been revoked."),
      StandardError.new("Your Apple ID has been revoked.")
    ])

    error = assert_raises(FastlaneUIError) { run_testflight_retry(subject) }
    assert_includes error.message, "1.2.3 (7) did not reach TestFlight after 2 attempts"
    assert_includes error.message, "Your Apple ID has been revoked."
    assert_includes error.message, "fastlane ios upload_only"
    assert_equal [{ attempts: 20, delay: 30 }, { attempts: 20, delay: 30 }], subject.checks
  end

  # The snapshot is what makes recovery safe for a second release running on the
  # same machine, so it has to be taken once, before anything of ours is running,
  # and handed to every cancellation.
  def test_testflight_retry_snapshots_running_uploads_once_before_the_first_attempt
    subject = testflight_helper([[:stall, StandardError.new("timed out")],
                                 [:stall, StandardError.new("timed out")]])
    scans = []
    snapshots = []
    subject.define_singleton_method(:transporter_pids) { scans << :scan; [111] }
    subject.define_singleton_method(:kill_transporter!) do |preexisting|
      snapshots << preexisting
      killed << true
    end

    assert_raises(FastlaneUIError) { run_testflight_retry(subject) }
    assert_equal [:scan], scans, "the snapshot must be taken once, not per attempt"
    assert_equal [[111], [111]], snapshots,
                 "every cancellation must be told which PIDs were already running"
  end

  # The watchdog fires, kill_transporter! sends SIGTERM, and SIGTERM makes the
  # blocked upload raise within milliseconds — so the main thread reaches
  # `watchdog.kill` while the cancellation is still inside its SIGTERM grace
  # period. Unguarded, Thread#kill tore the watchdog down mid-cancellation and
  # the SIGKILL escalation never ran at all. A mutex makes the main thread wait.
  def test_testflight_retry_lets_a_cancellation_finish_before_stopping_the_watchdog
    subject = testflight_helper([[:stall, StandardError.new("The request timed out.")]],
                                attempts: 1, has_build: true)
    finished = Queue.new
    subject.define_singleton_method(:kill_transporter!) do |*|
      killed << true   # unblocks the stalled upload; the main thread races us
      sleep(0.1)       # stands in for the five-second SIGTERM grace period
      finished << :complete
    end

    assert_nil run_testflight_retry(subject)
    assert_equal 1, finished.size,
                 "the watchdog was torn down mid-cancellation, so SIGKILL escalation never ran"
  end

  # --- kill_transporter! ------------------------------------------------------

  # Drives kill_transporter! with every process primitive stubbed. `scans` is the
  # queue of results `transporter_pids` returns, one per call: the first picks
  # the targets, the second is the post-SIGTERM liveness re-check.
  def kill_helper(scans, on_signal: nil)
    subject = helper("name" => "demo", "platforms" => ["ios"], "ios" => { "bundle_id" => "com.demo.app" })
    queue = scans.dup
    sent  = []
    subject.define_singleton_method(:sent) { sent }
    subject.define_singleton_method(:sleep) { |_seconds| nil }
    subject.define_singleton_method(:transporter_pids) { queue.shift || [] }
    subject.define_singleton_method(:process_command_line) { |pid| "iTMSTransporter -m upload ##{pid}" }
    subject.define_singleton_method(:kill_process) do |signal, pid|
      sent << [signal, pid]
      on_signal.call(signal, pid) if on_signal
      1
    end
    subject
  end

  # Empty pgrep output: nothing of ours is running, so nothing is signalled.
  def test_kill_transporter_signals_nothing_when_no_upload_is_running
    subject = kill_helper([[]])
    subject.kill_transporter!([])
    assert_empty subject.sent
  end

  # The defect README.md line 219 admits to: pattern-killing `altool` took out a
  # concurrent release's upload as well. A PID present before we started is
  # somebody else's and must survive.
  def test_kill_transporter_leaves_a_process_that_predates_the_upload_alone
    subject = kill_helper([[111]])
    subject.kill_transporter!([111])
    assert_empty subject.sent, "a pre-existing altool belongs to another release"
    assert ui_important.any? { |t| t.include?("No upload process of this run is left to cancel") },
           ui_important.inspect
  end

  # Both present: one pre-existing, one ours. Only ours is signalled.
  def test_kill_transporter_signals_only_the_pid_that_appeared_after_the_snapshot
    subject = kill_helper([[111, 222], [111]])
    subject.kill_transporter!([111])
    assert_equal [["TERM", 222]], subject.sent
    refute subject.sent.any? { |(_signal, pid)| pid == 111 }
  end

  # A PID that appeared after the snapshot with an empty snapshot: the plain
  # single-release case.
  def test_kill_transporter_terminates_a_new_pid_and_stops_when_it_exits
    subject = kill_helper([[222], []])
    subject.kill_transporter!([])
    assert_equal [["TERM", 222]], subject.sent, "no escalation once the process is gone"
  end

  # Escalation. The old code only ever re-checked `pgrep -x altool`, so a Java
  # iTMSTransporter that ignored SIGTERM was never escalated at all.
  def test_kill_transporter_escalates_to_sigkill_when_the_process_survives
    subject = kill_helper([[222], [222]])
    subject.kill_transporter!([])
    assert_equal [["TERM", 222], ["KILL", 222]], subject.sent
    assert ui_important.any? { |t| t.include?("222 did not exit after SIGTERM") }, ui_important.inspect
  end

  # A PID that exits between the scan and the signal is the outcome we wanted,
  # not an error, and must not be escalated even though a stale scan still lists
  # it.
  def test_kill_transporter_tolerates_a_pid_that_exits_before_the_signal_lands
    subject = kill_helper([[222], [222]], on_signal: ->(_signal, _pid) { raise Errno::ESRCH })
    subject.kill_transporter!([])
    assert_equal [["TERM", 222]], subject.sent
  end

  # Every PID is named with its command line before it is signalled, so a wrong
  # kill is visible in the log rather than inferred afterwards.
  def test_kill_transporter_logs_each_pid_and_its_command_line_before_signalling
    subject = kill_helper([[222], []])
    subject.kill_transporter!([])
    assert ui_important.any? { |t| t.include?("Cancelling upload process 222: iTMSTransporter -m upload #222") },
           ui_important.inspect
  end

  # The root cause of the whole rewrite: no part of cancellation may go through
  # fastlane's `sh`, which wraps the command in `/bin/sh -c "<command>"` and so
  # creates a process whose own argv contains the pattern being matched.
  def test_kill_transporter_never_shells_out
    subject = kill_helper([[222], [222]])
    subject.define_singleton_method(:sh) { |*| raise "kill_transporter! must not shell out" }
    subject.kill_transporter!([])
    assert_equal [["TERM", 222], ["KILL", 222]], subject.sent
  end

  # --- pgrep plumbing ---------------------------------------------------------

  # pgrep writes usage text to stderr on a bad flag, but a future typo must not
  # be able to turn a diagnostic line into a kill target.
  def test_parse_pid_list_keeps_only_bare_decimal_lines
    subject = helper
    assert_equal [], subject.parse_pid_list("")
    assert_equal [], subject.parse_pid_list(nil)
    assert_equal [42], subject.parse_pid_list("42\n")
    assert_equal [42, 7], subject.parse_pid_list("  42 \n\n7\n")
    assert_equal [42], subject.parse_pid_list("42\n42\n"), "duplicates collapse"
    assert_equal [], subject.parse_pid_list("pgrep: illegal option -- q\nusage: pgrep ...\n")
    assert_equal [], subject.parse_pid_list("12a\n-3\n1.5\n")
  end

  # The transporter is matched on the full command line and altool on its exact
  # name — Apple ships a shell wrapper that execs the JVM, so narrowing the
  # transporter pattern would leave the wrapper holding the network.
  def test_transporter_pids_scans_both_the_transporter_and_altool
    subject = helper
    calls = []
    subject.define_singleton_method(:pgrep_pids) do |flag, pattern|
      calls << [flag, pattern]
      flag == "-f" ? [1, 2] : [2, 3]
    end
    assert_equal [1, 2, 3], subject.transporter_pids
    assert_equal [["-f", "iTMSTransporter"], ["-x", "altool"]], calls
  end

  # pgrep_pids execs pgrep through an IO.popen ARGUMENT ARRAY, so no `/bin/sh -c`
  # wrapper exists for the pattern to match. Run against a real decoy process to
  # prove the array form works at all, and against a token nothing can be running
  # under to prove a miss is an empty list rather than an exception.
  def test_pgrep_pids_finds_a_real_process_without_a_shell
    subject = helper
    token = "frk-pgrep-probe-#{Process.pid}"
    assert_equal [], subject.pgrep_pids("-f", token)

    # A Ruby child, not a shell one: `/bin/sh -c "sleep 30"` execs sleep straight
    # away and the token disappears from the command line with it.
    pid = spawn(RbConfig.ruby, "-e", "sleep 30", token, out: File::NULL, err: File::NULL)
    begin
      found = nil
      20.times do
        found = subject.pgrep_pids("-f", token)
        break unless found.empty?
        sleep(0.05)
      end
      assert_includes found, pid
    ensure
      Process.kill("KILL", pid)
      Process.wait(pid)
    end
  end
end
