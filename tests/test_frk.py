import argparse
import ast
import atexit
import contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


FRK_PATH = Path(__file__).resolve().parents[1] / "bin" / "frk"


class ParserBuilt(Exception):
    """Raised in place of parse_args so main() hands back its built parser."""


class FakeChild:
    """Stands in for a fastlane subprocess.Popen without starting one.

    `hangs` makes communicate() time out until something clears it, which is how
    the process-group kill in capture_fastlane is observed without a real child.
    """

    def __init__(self, output="", returncode=0, hangs=False):
        self.output = output
        self.returncode = returncode
        self.hangs = hangs
        self.pid = 4242
        self.timeouts = []
        self.finished = False

    def communicate(self, timeout=None):
        self.timeouts.append(timeout)
        if self.hangs:
            raise subprocess.TimeoutExpired("fastlane", timeout)
        self.finished = True
        return self.output, None

    def poll(self):
        return self.returncode if self.finished else None

    def wait(self, timeout=None):
        if self.hangs:
            raise subprocess.TimeoutExpired("fastlane", timeout)
        self.finished = True
        return self.returncode

# bin/frk derives every vault path from FLUTTER_RELEASE_HOME on each call, so
# pointing the variable at a throwaway directory for the whole test process puts
# the developer's real ~/.flutter-release out of reach by construction — not
# only for the paths this file knows about, and not only inside setUp. setUp
# narrows it further to a per-test directory.
_SANDBOX_HOME = tempfile.TemporaryDirectory(prefix="frk-test-home-")
atexit.register(_SANDBOX_HOME.cleanup)
os.environ["FLUTTER_RELEASE_HOME"] = _SANDBOX_HOME.name

SPEC = importlib.util.spec_from_loader("frk", SourceFileLoader("frk", str(FRK_PATH)))
frk = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(frk)


class FrkTestCase(unittest.TestCase):
    def setUp(self):
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(contextlib.redirect_stdout(self.stdout))
        stack.enter_context(contextlib.redirect_stderr(self.stderr))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.release_home = self.root / "release-home"
        stack.enter_context(
            patch.dict(os.environ, {"FLUTTER_RELEASE_HOME": str(self.release_home)})
        )
        frk.distribution_identities.cache = None
        frk.distribution_identities.unavailable = None
        frk.git_check_timed_out.flag = False
        frk.find_keytool.cache = None

    def make_android_app(self, name="sample", package="org.example.realapp"):
        app = self.root / name
        (app / "android" / "app").mkdir(parents=True)
        (app / "pubspec.yaml").write_text(
            "name: sample\n"
            "version: 1.2.3+4\n"
            "dependencies:\n"
            "  flutter:\n"
            "    sdk: flutter\n"
            "flutter:\n"
            "  uses-material-design: true\n"
        )
        (app / "android" / "app" / "build.gradle.kts").write_text(
            f'android {{ defaultConfig {{ applicationId = "{package}" }} }}\n'
        )
        (app / "fastlane").mkdir()
        (app / "fastlane" / "Fastfile").write_text("import kit_fastfile\n")
        (app / frk.CONFIG_NAME).write_text(
            f"name: {name}\nplatforms: [android]\nandroid:\n  package_name: {package}\n"
        )
        return app

    def make_unonboarded_app(self, name, android_package=None, ios_bundle=None, ios_team=None):
        app = self.root / name
        app.mkdir()
        (app / "pubspec.yaml").write_text(
            f"name: {name}\n"
            "version: 1.0.0+1\n"
            "dependencies:\n"
            "  flutter:\n"
            "    sdk: flutter\n"
            "flutter:\n"
            "  uses-material-design: true\n"
        )
        if android_package:
            (app / "android" / "app").mkdir(parents=True)
            (app / "android" / "app" / "build.gradle.kts").write_text(
                f'android {{ defaultConfig {{ applicationId = "{android_package}" }} }}\n'
            )
        if ios_bundle or ios_team:
            project = app / "ios" / "Runner.xcodeproj"
            project.mkdir(parents=True)
            (project / "project.pbxproj").write_text(
                f"PRODUCT_BUNDLE_IDENTIFIER = {ios_bundle or 'com.example.placeholder'};\n"
                f"DEVELOPMENT_TEAM = {ios_team or ''};\n"
            )
        return app

    def onboard_args(self, app, **overrides):
        values = {
            "app_dir": str(app),
            "name": None,
            "platforms": None,
            "android_package": None,
            "ios_bundle_id": None,
            "ios_team_id": None,
            "track": "internal",
            "force": False,
            "dry_run": False,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def api_run_args(self, action, app_dir=None, **overrides):
        values = {
            "action": action,
            "app_dir": app_dir,
            "platform": None,
            "build_name": None,
            "build_number": None,
            "skip_tests": False,
            "skip_build": False,
            "name": None,
            "platforms": None,
            "android_package": None,
            "ios_bundle_id": None,
            "ios_team_id": None,
            "track": None,
            "properties": None,
            "keystore": None,
            "force": False,
            "link": False,
            "dry_run": False,
        }
        values.update(overrides)
        return argparse.Namespace(**values)

    def test_vault_paths_are_read_from_the_environment_on_every_call(self):
        # One accessor computes the vault location and everything else derives
        # from it, so redirecting the variable moves the whole vault — no list of
        # derived paths to keep in step.
        elsewhere = self.root / "other-home"
        with patch.dict(os.environ, {"FLUTTER_RELEASE_HOME": str(elsewhere)}):
            self.assertEqual(elsewhere, frk.credentials_dir())
            self.assertEqual(elsewhere / "projects.json", frk.registry_path())
            self.assertEqual(elsewhere / "signing", frk.signing_dir())

        with patch.dict(os.environ):
            os.environ.pop("FLUTTER_RELEASE_HOME", None)
            self.assertEqual(Path.home() / ".flutter-release", frk.credentials_dir())

    def test_registry_contains_only_explicitly_registered_apps(self):
        managed = self.make_android_app("managed")
        self.make_android_app("unmanaged")

        frk.register_project(managed)

        projects = frk.managed_projects()
        self.assertEqual(1, len(projects))
        self.assertEqual(str(managed.resolve()), projects[0]["path"])
        self.assertEqual(["android"], projects[0]["platforms"])
        self.assertEqual(0o600, frk.registry_path().stat().st_mode & 0o777)

    def test_setup_is_safe_and_idempotent(self):
        bin_dir = self.root / "bin"
        args = argparse.Namespace(bin_dir=str(bin_dir))

        with (
            patch.dict(os.environ, {"PATH": str(bin_dir)}),
            patch.object(frk.shutil, "which", return_value="/usr/local/bin/tool"),
        ):
            self.assertEqual(0, frk.cmd_setup(args))
            self.assertEqual(0, frk.cmd_setup(args))

        command = bin_dir / "frk"
        self.assertTrue(command.is_symlink())
        self.assertEqual(FRK_PATH.resolve(), command.resolve())
        self.assertEqual(0o700, self.release_home.stat().st_mode & 0o777)
        self.assertEqual(0o600, (self.release_home / "credentials.env").stat().st_mode & 0o777)
        self.assertEqual(0o600, frk.registry_path().stat().st_mode & 0o777)

        original = (self.release_home / "credentials.env").read_text()
        (self.release_home / "credentials.env").write_text(original + "SUPPLY_JSON_KEY=custom.json\n")
        with patch.dict(os.environ, {"PATH": str(bin_dir)}):
            self.assertEqual(0, frk.cmd_setup(args))
        self.assertIn("SUPPLY_JSON_KEY=custom.json", (self.release_home / "credentials.env").read_text())

        occupied_bin = self.root / "occupied-bin"
        occupied_bin.mkdir()
        occupied_command = occupied_bin / "frk"
        occupied_command.write_text("unrelated command\n")
        with patch.dict(os.environ, {"PATH": str(occupied_bin)}):
            self.assertEqual(1, frk.cmd_setup(argparse.Namespace(bin_dir=str(occupied_bin))))
        self.assertEqual("unrelated command\n", occupied_command.read_text())

    def test_store_credentials_are_validated_copied_privately_and_reported_without_secrets(self):
        play_source = self.root / "google-service-account.json"
        play_source.write_text(json.dumps({
            "type": "service_account",
            "project_id": "release-project",
            "private_key_id": "private-id",
            "private_key": "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n",
            "client_email": "releases@example.iam.gserviceaccount.com",
        }))
        asc_source = self.root / "AuthKey_ABCDEFGHIJ.p8"
        asc_source.write_text(
            "-----BEGIN PRIVATE KEY-----\napp-store-secret\n-----END PRIVATE KEY-----\n"
        )

        play = frk.configure_play_credentials(str(play_source), force=False)
        asc = frk.configure_asc_credentials(
            str(asc_source),
            "ABCDEFGHIJ",
            "12345678-1234-1234-1234-123456789abc",
            force=False,
        )
        # Re-selecting the same source is idempotent and does not require force.
        frk.configure_play_credentials(str(play_source), force=False)

        self.assertTrue(play["googlePlay"]["configured"])
        self.assertTrue(asc["appStoreConnect"]["configured"])
        self.assertTrue(asc["configuredAny"])
        self.assertTrue(play_source.is_file())
        self.assertTrue(asc_source.is_file())
        self.assertEqual(
            0o600,
            (self.release_home / "play" / "service-account.json").stat().st_mode & 0o777,
        )
        self.assertEqual(
            0o600,
            (self.release_home / "asc" / "AuthKey_ABCDEFGHIJ.p8").stat().st_mode & 0o777,
        )
        env = (self.release_home / "credentials.env").read_text()
        self.assertIn("SUPPLY_JSON_KEY=play/service-account.json", env)
        self.assertIn("ASC_KEY_ID=ABCDEFGHIJ", env)
        self.assertNotIn("app-store-secret", json.dumps(asc))
        self.assertNotIn("BEGIN PRIVATE KEY", json.dumps(play))

    def test_invalid_store_credentials_are_rejected_before_the_vault_changes(self):
        invalid_play = self.root / "not-a-service-account.json"
        invalid_play.write_text('{"type":"authorized_user"}')
        invalid_p8 = self.root / "not-a-key.p8"
        invalid_p8.write_text("not a private key")

        with self.assertRaisesRegex(ValueError, "service-account"):
            frk.configure_play_credentials(str(invalid_play), force=False)
        with self.assertRaisesRegex(ValueError, "private key"):
            frk.configure_asc_credentials(
                str(invalid_p8),
                "ABCDEFGHIJ",
                "12345678-1234-1234-1234-123456789abc",
                force=False,
            )

        self.assertFalse((self.release_home / "credentials.env").exists())

    def test_managed_app_can_be_resolved_by_name_from_any_directory(self):
        app = self.make_android_app("portable")
        frk.register_project(app)

        self.assertEqual(app.resolve(), frk.resolve_app("portable"))

    def test_current_and_registered_names_resolve_without_rewriting_the_registry(self):
        app = self.make_android_app("original")
        frk.register_project(app)
        registry = frk.registry_path().read_bytes()
        config = app / frk.CONFIG_NAME
        config.write_text(config.read_text().replace("name: original", "name: renamed"))

        for name in ("original", "renamed"):
            with self.subTest(name=name):
                self.assertEqual(app.resolve(), frk.resolve_app(name))
                self.assertEqual(str(app.resolve()), frk.api_find_project(name)["path"])
        self.assertEqual(registry, frk.registry_path().read_bytes())

    def test_ambiguous_current_names_require_an_explicit_path(self):
        first = self.make_android_app("first")
        second = self.make_android_app("second")
        for app in (first, second):
            frk.register_project(app)
        config = first / frk.CONFIG_NAME
        config.write_text(config.read_text().replace("name: first", "name: second"))

        for resolve in (frk.resolve_app, frk.api_find_project):
            with self.subTest(resolve=resolve.__name__):
                with self.assertRaises(SystemExit):
                    resolve("second")
        for app in (first, second):
            self.assertEqual(app.resolve(), frk.resolve_app(str(app)))
            self.assertEqual(str(app.resolve()), frk.api_find_project(str(app))["path"])

    def test_api_resolves_registered_paths_even_when_the_directory_is_missing(self):
        app = self.make_android_app("missing")
        frk.register_project(app)
        shutil.rmtree(app)
        self.assertEqual(str(app.resolve()), frk.api_find_project(str(app))["path"])

    def test_api_does_not_resolve_an_unregistered_existing_path_as_another_apps_name(self):
        app = self.make_android_app("managed")
        frk.register_project(app)
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / "managed").mkdir()
        process = subprocess.run(
            [sys.executable, str(FRK_PATH), "api", "project", "managed"],
            cwd=elsewhere, capture_output=True, text=True, timeout=10,
        )
        self.assertNotEqual(0, process.returncode)
        self.assertEqual("project_not_found", json.loads(process.stdout)["error"]["code"])

    def test_forget_removes_only_the_registry_entry_and_preserves_the_project(self):
        app = self.make_android_app("removable")
        marker = app / "keep-me.txt"
        marker.write_text("project data")
        frk.register_project(app)

        self.assertEqual(0, frk.cmd_forget(argparse.Namespace(app_dir="removable")))

        self.assertEqual([], frk.managed_projects())
        self.assertTrue(app.is_dir())
        self.assertEqual("project data", marker.read_text())
        self.assertTrue((app / frk.CONFIG_NAME).is_file())
        self.assertTrue((app / "fastlane" / "Fastfile").is_file())

    def test_registry_rejects_two_existing_projects_with_the_same_name(self):
        first = self.make_android_app("first")
        (first / frk.CONFIG_NAME).write_text(
            "name: shared_name\n"
            "platforms: [android]\n"
            "android:\n"
            "  package_name: org.example.first\n"
        )
        second = self.make_unonboarded_app("second", android_package="org.example.second")

        frk.register_project(first)
        with self.assertRaises(SystemExit):
            frk.cmd_onboard(self.onboard_args(second, name="shared_name"))

        self.assertEqual(1, len(frk.managed_projects()))
        self.assertEqual(str(first.resolve()), frk.managed_projects()[0]["path"])
        self.assertFalse((second / "fastlane").exists())

    def test_config_name_round_trips_characters_that_need_yaml_quoting(self):
        facts = {
            "name": "My # App: فارسی",
            "android_package": "org.example.app",
            "firebase_android_app_id": None,
        }
        app = self.root / "quoted"
        (app / "fastlane").mkdir(parents=True)
        (app / frk.CONFIG_NAME).write_text(frk.render_config(facts, ["android"], "internal"))

        self.assertEqual("My # App: فارسی", frk.config_summary(app)[0])

    def test_blank_line_does_not_let_a_top_level_key_shadow_a_platform_setting(self):
        # package_name is the Play upload identity, so a nested lookup that walks
        # past a blank line into a top-level key uploads under the wrong package.
        app = self.root / "shadowed"
        (app / "fastlane").mkdir(parents=True)
        (app / frk.CONFIG_NAME).write_text(
            "name: shadowed\n"
            "platforms: [android]\n"
            "\n"
            "package_name: org.example.wrong\n"
            "\n"
            "android:\n"
            "  package_name: org.example.real\n"
            "\n"
            "ios:\n"
            "  bundle_id:\n"
            "  team_id: A1B2C3D4E5\n"
        )

        self.assertEqual("org.example.real", frk.config_setting(app, "package_name"))
        # An empty value is empty; it must not capture the next line's value.
        self.assertEqual("", frk.config_setting(app, "bundle_id"))
        self.assertEqual("A1B2C3D4E5", frk.config_setting(app, "team_id"))

    # ----------------------------------------------------------------- #
    # extra_build_args — read/write patcher
    # ----------------------------------------------------------------- #
    EXTRA_ARGS_SAMPLE = (
        "# Flutter Release Kit — per-app configuration.\n"
        "#\n"
        "# Committed on purpose: these are public identifiers, not secrets.\n"
        "\n"
        'name: "demo"\n'
        "\n"
        "platforms: [android, ios]\n"
        "\n"
        "obfuscate: true\n"
        "\n"
        "# extra_build_args:\n"
        '#   - "--dart-define=KEY=value"\n'
        "\n"
        "android:\n"
        "  package_name: org.example.app\n"
        "\n"
        "  track: internal\n"
        "\n"
        "  # play_json_key: play/other-account.json\n"
        "\n"
        "ios:\n"
        "  bundle_id: org.example.app\n"
        "  team_id: ABCDE12345\n"
    )

    def write_extra_args_sample(self, name="argsapp", text=None):
        app = self.root / name
        (app / "fastlane").mkdir(parents=True)
        (app / frk.CONFIG_NAME).write_text(text if text is not None else self.EXTRA_ARGS_SAMPLE)
        return app

    def test_extra_build_args_are_empty_on_a_pristine_config(self):
        app = self.write_extra_args_sample()
        self.assertEqual([], frk.platform_extra_build_args(app, "android"))
        self.assertEqual([], frk.platform_extra_build_args(app, "ios"))
        self.assertEqual([], frk.shared_extra_build_args(app))

    def test_the_commented_out_example_is_not_read_as_active(self):
        # "#   - ..." must never be mistaken for a real list item.
        app = self.write_extra_args_sample()
        self.assertEqual([], frk.shared_extra_build_args(app))

    def test_set_inserts_a_new_block_and_leaves_the_other_platform_untouched(self):
        app = self.write_extra_args_sample()
        before = (app / frk.CONFIG_NAME).read_text()

        frk.set_platform_extra_build_args(app, "android", ["--dart-define=A=1", "--dart-define=B=2"])

        self.assertEqual(
            ["--dart-define=A=1", "--dart-define=B=2"],
            frk.platform_extra_build_args(app, "android"),
        )
        self.assertEqual([], frk.platform_extra_build_args(app, "ios"))
        after = (app / frk.CONFIG_NAME).read_text()
        self.assertEqual(before[before.index("ios:") :], after[after.index("ios:") :])

    def test_set_is_idempotent(self):
        app = self.write_extra_args_sample()
        frk.set_platform_extra_build_args(app, "android", ["--x", "--y"])
        once = (app / frk.CONFIG_NAME).read_text()

        frk.set_platform_extra_build_args(app, "android", ["--x", "--y"])

        self.assertEqual(once, (app / frk.CONFIG_NAME).read_text())

    def test_set_replaces_an_existing_list(self):
        app = self.write_extra_args_sample()
        frk.set_platform_extra_build_args(app, "android", ["--old"])

        frk.set_platform_extra_build_args(app, "android", ["--new-one", "--new-two"])

        self.assertEqual(["--new-one", "--new-two"], frk.platform_extra_build_args(app, "android"))

    def test_set_with_an_empty_list_clears_an_existing_block_without_a_double_blank_line(self):
        app = self.write_extra_args_sample()
        frk.set_platform_extra_build_args(app, "android", ["--temp"])

        frk.set_platform_extra_build_args(app, "android", [])

        self.assertEqual([], frk.platform_extra_build_args(app, "android"))
        text = (app / frk.CONFIG_NAME).read_text()
        self.assertNotIn("\n\n\n", text)
        self.assertNotIn("extra_build_args", text.split("android:")[1].split("ios:")[0])

    def test_set_with_an_empty_list_and_nothing_to_clear_does_not_touch_the_file(self):
        app = self.write_extra_args_sample()
        path = app / frk.CONFIG_NAME
        before_bytes = path.read_bytes()
        before_mtime = path.stat().st_mtime_ns

        frk.set_platform_extra_build_args(app, "ios", [])

        self.assertEqual(before_bytes, path.read_bytes())
        self.assertEqual(before_mtime, path.stat().st_mtime_ns)

    def test_set_round_trips_quotes_unicode_backslashes_and_embedded_newlines(self):
        app = self.write_extra_args_sample()
        tricky = ['--dart-define=NAME="quoted value"', "--flag-با-فارسی", "back\\slash", "has\nnewline"]

        frk.set_platform_extra_build_args(app, "ios", tricky)

        self.assertEqual(tricky, frk.platform_extra_build_args(app, "ios"))

    def test_set_on_the_last_section_preserves_exactly_one_trailing_newline(self):
        app = self.write_extra_args_sample()

        frk.set_platform_extra_build_args(app, "ios", ["--x"])

        text = (app / frk.CONFIG_NAME).read_text()
        self.assertTrue(text.endswith("\n"))
        self.assertFalse(text.endswith("\n\n"))

    def test_set_dies_for_a_platform_with_no_section_at_all(self):
        app = self.write_extra_args_sample(text=self.EXTRA_ARGS_SAMPLE.replace("platforms: [android, ios]", "platforms: [android]").split("ios:")[0])

        with self.assertRaises(SystemExit):
            frk.set_platform_extra_build_args(app, "ios", ["--x"])

    def test_shared_and_platform_lists_are_read_independently(self):
        app = self.write_extra_args_sample(
            text=self.EXTRA_ARGS_SAMPLE.replace(
                '# extra_build_args:\n#   - "--dart-define=KEY=value"',
                'extra_build_args:\n  - "--dart-define=SHARED=1"',
            )
        )
        frk.set_platform_extra_build_args(app, "android", ["--dart-define=A=1"])

        self.assertEqual(["--dart-define=SHARED=1"], frk.shared_extra_build_args(app))
        self.assertEqual(["--dart-define=A=1"], frk.platform_extra_build_args(app, "android"))
        self.assertEqual([], frk.platform_extra_build_args(app, "ios"))

    def test_the_patcher_round_trips_a_real_user_config_shape(self):
        # A shape actually seen in the wild: firebase_app_id present, no
        # top-level extra_build_args comment block at all (an older onboarding
        # generated it), Android section not the last one before EOF.
        app = self.write_extra_args_sample(
            text=(
                'name: sample_app\n'
                "platforms: [android, ios]\n"
                "obfuscate: true\n"
                "\n"
                "android:\n"
                "  package_name: com.example.sample_app\n"
                "  track: internal\n"
                '  firebase_app_id: "1:000000000000:android:0000000000000000000000"\n'
                "\n"
                "ios:\n"
                "  bundle_id: com.example.sample_app\n"
                "  team_id: ABCDE12345\n"
            )
        )
        before = (app / frk.CONFIG_NAME).read_text()

        frk.set_platform_extra_build_args(app, "android", ["--dart-define=USE_NEXT_GEN_SDK=true"])

        self.assertEqual(
            ["--dart-define=USE_NEXT_GEN_SDK=true"], frk.platform_extra_build_args(app, "android")
        )
        after = (app / frk.CONFIG_NAME).read_text()
        self.assertEqual(before[before.index("ios:") :], after[after.index("ios:") :])
        self.assertIn('firebase_app_id: "1:000000000000:android:0000000000000000000000"', after)

    def test_commented_lists_replace_all_items_and_preserve_other_settings(self):
        app = self.write_extra_args_sample(text=self.EXTRA_ARGS_SAMPLE.replace(
            "android:\n", "android: # Android options\n"
        ).replace("  track: internal", '  extra_build_args: # flags\n'
                  '    - "--old-a"\n\n    # keep this explanation\n'
                  '    - "--old-b" # second flag\n  track: internal'))
        self.assertEqual(["--old-a", "--old-b"], frk.platform_extra_build_args(app, "android"))
        frk.set_platform_extra_build_args(app, "android", ["--new"])
        self.assertEqual(["--new"], frk.platform_extra_build_args(app, "android"))
        text = (app / frk.CONFIG_NAME).read_text()
        self.assertNotIn("--old", text)
        self.assertIn("# keep this explanation", text)
        self.assertIn("# second flag", text)
        self.assertIn("extra_build_args: # flags", text)
        self.assertIn("  track: internal", text)
        self.assertEqual(self.EXTRA_ARGS_SAMPLE.split("ios:")[1], text.split("ios:")[1])

    def test_inline_lists_are_replaced_without_duplicate_keys(self):
        app = self.write_extra_args_sample(text=self.EXTRA_ARGS_SAMPLE.replace(
            "  track: internal", '  extra_build_args: ["--value=a # b"] # keep\n  track: internal'))
        self.assertEqual(["--value=a # b"], frk.platform_extra_build_args(app, "android"))
        frk.set_platform_extra_build_args(app, "android", ["--next"])
        self.assertEqual(["--next"], frk.platform_extra_build_args(app, "android"))
        self.assertEqual(1, (app / frk.CONFIG_NAME).read_text().count("  extra_build_args:"))
        self.assertIn("extra_build_args: # keep", (app / frk.CONFIG_NAME).read_text())

    def test_unsupported_and_duplicate_yaml_is_never_rewritten(self):
        shapes = [
            "  extra_build_args: [--flavor, demo]",
            "  extra_build_args: *shared",
            '  extra_build_args:\n    - "--a"\n  extra_build_args:\n    - "--b"',
            '  extra_build_args:\n    - |\n      --multiline',
            '  extra_build_args:\n    - "--a"\n      - "--nested"',
            '  extra_build_args:\n  -',
            '  extra_build_args:\n    - - "--nested"',
        ]
        for index, shape in enumerate(shapes):
            with self.subTest(shape=shape):
                app = self.write_extra_args_sample(name=f"unsafe{index}", text=self.EXTRA_ARGS_SAMPLE.replace(
                    "  track: internal", shape + "\n  track: internal"))
                path = app / frk.CONFIG_NAME
                original = path.read_bytes()
                with self.assertRaises(SystemExit):
                    frk.set_platform_extra_build_args(app, "android", ["--new"])
                self.assertEqual(original, path.read_bytes())

    def test_config_edits_preserve_crlf_no_final_newline_permissions_and_symlink(self):
        app = self.write_extra_args_sample()
        path = app / frk.CONFIG_NAME
        target = self.root / "linked-config.yml"
        text = self.EXTRA_ARGS_SAMPLE.rstrip("\n").replace("\n", "\r\n")
        target.write_bytes(text.encode())
        target.chmod(0o640)
        path.unlink()
        path.symlink_to(target)
        frk.set_android_track(app, "beta")
        self.assertTrue(path.is_symlink())
        self.assertEqual(text.replace("track: internal", "track: beta").encode(), target.read_bytes())
        frk.set_platform_extra_build_args(app, "ios", ["--x"])
        updated = target.read_bytes()
        self.assertNotIn(b"\n", updated.replace(b"\r\n", b""))
        self.assertFalse(updated.endswith(b"\n"))
        self.assertEqual(0o640, stat.S_IMODE(target.stat().st_mode))

    def test_track_edit_preserves_comment_and_ignores_nested_track(self):
        app = self.write_extra_args_sample(text=self.EXTRA_ARGS_SAMPLE.replace(
            "  track: internal", '  custom:\n    track: nested\n  track: "internal" # testing only'))
        path = app / frk.CONFIG_NAME
        before = path.read_bytes()
        stamp = path.stat().st_mtime_ns
        frk.set_android_track(app, "internal")
        self.assertEqual(before, path.read_bytes())
        self.assertEqual(stamp, path.stat().st_mtime_ns)
        frk.set_android_track(app, "beta")
        self.assertEqual(before.replace(b'"internal"', b'beta'), path.read_bytes())

    def test_shared_flags_can_follow_platform_sections(self):
        app = self.write_extra_args_sample(text=self.EXTRA_ARGS_SAMPLE + 'extra_build_args:\n  - "--shared"\n')
        self.assertEqual(["--shared"], frk.shared_extra_build_args(app))
        self.assertEqual([], frk.platform_extra_build_args(app, "ios"))

    def test_quoted_keys_and_nonstandard_indentation_do_not_create_duplicate_settings(self):
        app = self.write_extra_args_sample(text=(
            'android: # platform\n'
            '    "track" : internal # keep\n'
            '    "extra_build_args" :\n'
            '    - "--old"\n'
            'ios:\n    bundle_id: org.example.app\n'
        ))
        frk.set_android_track(app, "alpha")
        frk.set_platform_extra_build_args(app, "android", ["--new"])
        text = (app / frk.CONFIG_NAME).read_text()
        self.assertEqual(1, text.count("track"))
        self.assertEqual(1, text.count("extra_build_args"))
        self.assertIn("    track: alpha # keep", text)
        self.assertEqual(["--new"], frk.platform_extra_build_args(app, "android"))

    def test_concurrent_config_edits_keep_both_platforms_and_track(self):
        app = self.write_extra_args_sample()
        script = """
import importlib.util, sys, time
from importlib.machinery import SourceFileLoader
from pathlib import Path
spec = importlib.util.spec_from_loader('frk', SourceFileLoader('frk', sys.argv[1]))
frk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frk)
original = frk.read_editable_config
def slow_read(path):
    result = original(path)
    time.sleep(0.1)
    return result
frk.read_editable_config = slow_read
app = Path(sys.argv[2])
if sys.argv[3] == 'track':
    frk.set_android_track(app, 'beta')
else:
    frk.set_platform_extra_build_args(app, sys.argv[3], ['--' + sys.argv[3]])
"""
        children = [subprocess.Popen([sys.executable, "-c", script, str(FRK_PATH), str(app), field],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    for field in ("track", "android", "ios")]
        try:
            for child in children:
                _, error = child.communicate(timeout=15)
                self.assertEqual(0, child.returncode, error.decode())
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait()
        self.assertEqual("beta", frk.config_setting(app, "track"))
        self.assertEqual(["--android"], frk.platform_extra_build_args(app, "android"))
        self.assertEqual(["--ios"], frk.platform_extra_build_args(app, "ios"))

    def test_failed_atomic_edit_keeps_original_and_removes_temporary_file(self):
        app = self.write_extra_args_sample()
        path = app / frk.CONFIG_NAME
        before = path.read_bytes()
        with patch.object(frk.os, "replace", side_effect=OSError("simulated failure")):
            with self.assertRaises(OSError):
                frk.set_android_track(app, "beta")
        self.assertEqual(before, path.read_bytes())
        self.assertEqual([], list(path.parent.glob(".*.tmp-*")))

    def test_registering_again_preserves_metadata_and_is_a_noop(self):
        app = self.make_android_app()
        frk.register_project(app)
        data = frk.load_registry()
        data["projects"][0].update(added_at="2020-01-01T00:00:00Z", custom="preserved")
        frk.save_registry(data)
        before = frk.registry_path().read_bytes()
        stamp = frk.registry_path().stat().st_mtime_ns
        frk.register_project(app)
        self.assertEqual(before, frk.registry_path().read_bytes())
        self.assertEqual(stamp, frk.registry_path().stat().st_mtime_ns)

    def test_concurrent_registration_keeps_every_project(self):
        apps = [self.make_android_app(name=f"concurrent{i}") for i in range(4)]
        script = """
import importlib.util, sys, time
from importlib.machinery import SourceFileLoader
from pathlib import Path
spec = importlib.util.spec_from_loader('frk', SourceFileLoader('frk', sys.argv[1]))
frk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frk)
original = frk.load_registry
def slow_read():
    data = original()
    time.sleep(0.1)
    return data
frk.load_registry = slow_read
frk.register_project(Path(sys.argv[2]))
"""
        children = [subprocess.Popen([sys.executable, "-c", script, str(FRK_PATH), str(app)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE) for app in apps]
        try:
            for child in children:
                _, error = child.communicate(timeout=15)
                self.assertEqual(0, child.returncode, error.decode())
        finally:
            for child in children:
                if child.poll() is None:
                    child.kill()
                child.wait()
        self.assertEqual({str(app.resolve()) for app in apps}, {p["path"] for p in frk.managed_projects()})
        self.assertEqual(0o600, stat.S_IMODE(frk.registry_path().stat().st_mode))

    # ----------------------------------------------------------------- #
    # extra_build_args — human CLI
    # ----------------------------------------------------------------- #
    def onboard_dual_platform_app(self, name, android_package, ios_bundle, ios_team):
        app = self.make_unonboarded_app(
            name, android_package=android_package, ios_bundle=ios_bundle, ios_team=ios_team
        )
        self.assertEqual(0, frk.cmd_onboard(self.onboard_args(app)))
        return app

    def test_build_args_show_reports_none_configured_for_a_pristine_app(self):
        app = self.onboard_dual_platform_app("bashow", "org.example.bashow", "org.example.bashow.ios", "ABCDE12345")

        self.assertEqual(0, frk.cmd_build_args_show(argparse.Namespace(app_dir=str(app))))

        output = self.stdout.getvalue()
        self.assertIn("(none)", output)

    def test_build_args_set_writes_and_show_reflects_it(self):
        app = self.onboard_dual_platform_app("baset", "org.example.baset", "org.example.baset.ios", "ABCDE12345")

        exit_code = frk.cmd_build_args_set(
            argparse.Namespace(app_dir=str(app), platform="android", arg=["--dart-define=A=1"])
        )
        self.assertEqual(0, exit_code)
        self.assertEqual(["--dart-define=A=1"], frk.platform_extra_build_args(app, "android"))
        self.assertEqual([], frk.platform_extra_build_args(app, "ios"))

        self.reset_stdout()
        frk.cmd_build_args_show(argparse.Namespace(app_dir=str(app)))
        self.assertIn("--dart-define=A=1", self.stdout.getvalue())

    def test_build_args_set_dies_for_a_platform_the_app_does_not_ship(self):
        app = self.make_unonboarded_app("baandroidonly", android_package="org.example.baandroidonly")
        self.assertEqual(0, frk.cmd_onboard(self.onboard_args(app)))

        with self.assertRaises(SystemExit):
            frk.cmd_build_args_set(argparse.Namespace(app_dir=str(app), platform="ios", arg=["--x"]))

    # ----------------------------------------------------------------- #
    # extra_build_args — machine API
    # ----------------------------------------------------------------- #
    def test_api_build_args_reports_shared_own_and_effective_per_platform(self):
        app = self.onboard_dual_platform_app("baapi", "org.example.baapi", "org.example.baapi.ios", "ABCDE12345")
        frk.set_platform_extra_build_args(app, "android", ["--dart-define=A=1"])

        self.reset_stdout()
        self.assertEqual(0, frk.cmd_api_build_args(argparse.Namespace(app_dir="baapi")))

        doc = json.loads(self.stdout.getvalue())
        self.assertEqual(
            {"protocolVersion", "cliVersion", "shared", "android", "ios"}, set(doc)
        )
        self.assertEqual([], doc["shared"])
        self.assertEqual(
            {"configured": True, "own": ["--dart-define=A=1"], "effective": ["--dart-define=A=1"]},
            doc["android"],
        )
        self.assertEqual({"configured": True, "own": [], "effective": []}, doc["ios"])

    def test_api_build_args_reports_project_not_found(self):
        exit_code = frk.cmd_api_build_args(argparse.Namespace(app_dir="does-not-exist"))

        self.assertEqual(1, exit_code)
        self.assertEqual("project_not_found", json.loads(self.stdout.getvalue())["error"]["code"])

    def test_api_set_build_args_writes_and_returns_the_updated_document(self):
        app = self.onboard_dual_platform_app("basetapi", "org.example.basetapi", "org.example.basetapi.ios", "ABCDE12345")

        self.reset_stdout()
        exit_code = frk.cmd_api_set_build_args(
            argparse.Namespace(app_dir="basetapi", platform="ios", arg=["--dart-define=I=1", "--dart-define=I=2"])
        )

        self.assertEqual(0, exit_code)
        doc = json.loads(self.stdout.getvalue())
        self.assertEqual(["--dart-define=I=1", "--dart-define=I=2"], doc["ios"]["own"])
        self.assertEqual([], doc["android"]["own"])
        # Persisted, not just echoed.
        self.assertEqual(["--dart-define=I=1", "--dart-define=I=2"], frk.platform_extra_build_args(app, "ios"))

    def test_api_set_build_args_reports_invalid_platform(self):
        self.onboard_dual_platform_app("baandroidonlyapi", "org.example.baandroidonlyapi", None, None)
        app = self.root / "baandroidonlyapi"
        self.assertTrue(frk.is_registered(app))

        self.reset_stdout()
        exit_code = frk.cmd_api_set_build_args(
            argparse.Namespace(app_dir="baandroidonlyapi", platform="ios", arg=["--x"])
        )

        self.assertEqual(1, exit_code)
        error = json.loads(self.stdout.getvalue())["error"]
        self.assertEqual("invalid_platform", error["code"])
        # Nothing was written for the platform that was rejected.
        self.assertEqual([], frk.platform_extra_build_args(app, "ios"))

    def test_api_set_build_args_with_no_arg_clears_the_platforms_own_list(self):
        app = self.onboard_dual_platform_app("baclearapi", "org.example.baclearapi", "org.example.baclearapi.ios", "ABCDE12345")
        frk.set_platform_extra_build_args(app, "android", ["--temp"])

        self.reset_stdout()
        exit_code = frk.cmd_api_set_build_args(
            argparse.Namespace(app_dir="baclearapi", platform="android", arg=[])
        )

        self.assertEqual(0, exit_code)
        self.assertEqual([], json.loads(self.stdout.getvalue())["android"]["own"])
        self.assertEqual([], frk.platform_extra_build_args(app, "android"))

    # ----------------------------------------------------------------- #
    # android.track — pure patcher
    # ----------------------------------------------------------------- #
    def test_set_android_track_replaces_the_scalar_and_leaves_everything_else_untouched(self):
        app = self.write_extra_args_sample()
        before = (app / frk.CONFIG_NAME).read_text()

        frk.set_android_track(app, "beta")

        after = (app / frk.CONFIG_NAME).read_text()
        self.assertIn("  track: beta", after)
        self.assertNotIn("track: internal", after)
        self.assertEqual(before[before.index("ios:") :], after[after.index("ios:") :])

    def test_set_android_track_is_idempotent(self):
        app = self.write_extra_args_sample()
        frk.set_android_track(app, "alpha")
        once = (app / frk.CONFIG_NAME).read_text()
        once_mtime = (app / frk.CONFIG_NAME).stat().st_mtime_ns

        frk.set_android_track(app, "alpha")

        self.assertEqual(once, (app / frk.CONFIG_NAME).read_text())
        self.assertEqual(once_mtime, (app / frk.CONFIG_NAME).stat().st_mtime_ns)

    def test_set_android_track_dies_without_an_android_section(self):
        app = self.write_extra_args_sample(
            text=self.EXTRA_ARGS_SAMPLE.replace("platforms: [android, ios]", "platforms: [ios]").split("android:")[0]
            + 'ios:\n  bundle_id: org.example.app\n  team_id: ABCDE12345\n'
        )
        with self.assertRaises(SystemExit):
            frk.set_android_track(app, "beta")

    def test_set_android_track_inserts_a_line_when_the_config_has_none(self):
        # A config hand-edited to drop the track key entirely — not what onboarding
        # writes, but the setter has to leave the file sane either way.
        app = self.write_extra_args_sample(
            text=self.EXTRA_ARGS_SAMPLE.replace("  track: internal\n\n", "")
        )
        self.assertNotIn("track:", (app / frk.CONFIG_NAME).read_text())

        frk.set_android_track(app, "alpha")

        self.assertEqual("alpha", frk.config_setting(app, "track"))

    # ----------------------------------------------------------------- #
    # android.track — human CLI
    # ----------------------------------------------------------------- #
    def test_track_show_reports_the_configured_track(self):
        app = self.onboard_dual_platform_app("trshow", "org.example.trshow", "org.example.trshow.ios", "ABCDE12345")

        self.assertEqual(0, frk.cmd_track_show(argparse.Namespace(app_dir=str(app))))
        self.assertIn("internal", self.stdout.getvalue())

    def test_track_set_writes_and_show_reflects_it(self):
        app = self.onboard_dual_platform_app("trset", "org.example.trset", "org.example.trset.ios", "ABCDE12345")

        exit_code = frk.cmd_track_set(argparse.Namespace(app_dir=str(app), track="beta"))
        self.assertEqual(0, exit_code)
        self.assertEqual("beta", frk.config_setting(app, "track"))

        self.reset_stdout()
        frk.cmd_track_show(argparse.Namespace(app_dir=str(app)))
        self.assertIn("beta", self.stdout.getvalue())

    def test_track_set_dies_for_an_ios_only_app(self):
        app = self.onboard_dual_platform_app("trios", None, "org.example.trios.ios", "ABCDE12345")

        with self.assertRaises(SystemExit):
            frk.cmd_track_set(argparse.Namespace(app_dir=str(app), track="beta"))

    # ----------------------------------------------------------------- #
    # android.track — machine API
    # ----------------------------------------------------------------- #
    def test_api_set_track_writes_and_returns_the_updated_project_record(self):
        app = self.onboard_dual_platform_app("trapiset", "org.example.trapiset", "org.example.trapiset.ios", "ABCDE12345")

        self.reset_stdout()
        exit_code = frk.cmd_api_set_track(argparse.Namespace(app_dir="trapiset", track="alpha"))

        self.assertEqual(0, exit_code)
        doc = json.loads(self.stdout.getvalue())
        self.assertEqual({"protocolVersion", "cliVersion", "project"}, set(doc))
        self.assertEqual("alpha", doc["project"]["android"]["track"])
        # Persisted, not just echoed.
        self.assertEqual("alpha", frk.config_setting(app, "track"))

    def test_api_set_track_reports_invalid_platform_for_an_ios_only_app(self):
        self.onboard_dual_platform_app("trapiiosonly", None, "org.example.trapiiosonly.ios", "ABCDE12345")

        self.reset_stdout()
        exit_code = frk.cmd_api_set_track(argparse.Namespace(app_dir="trapiiosonly", track="beta"))

        self.assertEqual(1, exit_code)
        self.assertEqual("invalid_platform", json.loads(self.stdout.getvalue())["error"]["code"])

    def test_api_set_track_reports_project_not_found(self):
        self.reset_stdout()
        exit_code = frk.cmd_api_set_track(argparse.Namespace(app_dir="does-not-exist", track="beta"))

        self.assertEqual(1, exit_code)
        self.assertEqual("project_not_found", json.loads(self.stdout.getvalue())["error"]["code"])

    def test_quoted_config_name_with_a_trailing_comment_matches_ruby_yaml(self):
        # fastlane/Fastfile reads the same line with YAML.load_file, which keeps
        # the quoted scalar and drops the comment. Python must not disagree about
        # the project's identity and silently fall back to the directory name.
        for index, quoted in enumerate(('"My App"', "'My App'")):
            app = self.root / f"commented{index}"
            (app / "fastlane").mkdir(parents=True)
            (app / frk.CONFIG_NAME).write_text(
                f"name: {quoted} # the store listing name\nplatforms: [android]\n"
            )

            self.assertEqual("My App", frk.config_summary(app)[0])

    def test_unregistered_copy_cannot_run_release_commands(self):
        app = self.make_android_app("copied")

        with self.assertRaises(SystemExit):
            frk.require_managed_app(str(app))

    def test_registered_project_with_copied_identity_is_rejected(self):
        app = self.make_android_app("identity", package="org.example.actual")
        (app / frk.CONFIG_NAME).write_text(
            "name: identity\nplatforms: [android]\nandroid:\n  package_name: org.example.someone_else\n"
        )
        frk.register_project(app)

        with self.assertRaises(SystemExit):
            frk.require_managed_app(str(app))

    def test_onboarding_autodetects_android_ios_and_dual_platform_apps(self):
        android = self.make_unonboarded_app("android_only", android_package="org.example.android")
        ios = self.make_unonboarded_app(
            "ios_only", ios_bundle="org.example.ios", ios_team="A1B2C3D4E5"
        )
        both = self.make_unonboarded_app(
            "both",
            android_package="org.example.both",
            ios_bundle="org.example.both.ios",
            ios_team="A1B2C3D4E5",
        )

        for app, expected in ((android, ["android"]), (ios, ["ios"]), (both, ["android", "ios"])):
            self.assertEqual(0, frk.cmd_onboard(self.onboard_args(app)))
            self.assertEqual(expected, frk.config_summary(app)[1])
            self.assertTrue(frk.is_registered(app))

        generated_fastfile = (both / "fastlane" / "Fastfile").read_text()
        self.assertIn('ENV["FLUTTER_RELEASE_KIT"] || "~/.flutter-release-kit"', generated_fastfile)
        export_options = (both / "ios" / "ExportOptions.plist").read_text()
        self.assertIn("<string>manual</string>", export_options)
        self.assertIn("<key>org.example.both.ios</key>", export_options)
        self.assertIn("<string>org.example.both.ios AppStore</string>", export_options)

    def test_onboarding_rejects_placeholder_identifiers_even_when_forced(self):
        app = self.make_unonboarded_app("placeholder", android_package="com.example.placeholder")

        with self.assertRaises(SystemExit):
            frk.cmd_onboard(self.onboard_args(app, platforms="android"))
        self.assertFalse(frk.managed_projects())

    def test_android_only_onboarding_prints_sequential_frk_next_steps(self):
        app = self.make_unonboarded_app("steps", android_package="org.example.steps")

        self.assertEqual(0, frk.cmd_onboard(self.onboard_args(app)))

        output = self.stdout.getvalue()
        self.assertIn("1. Grant the Play service account", output)
        self.assertIn("2. Validate everything", output)
        self.assertIn("&& frk doctor", output)
        self.assertNotIn("3. Validate everything", output)

    def test_android_namespace_is_not_mistaken_for_play_application_id(self):
        app = self.make_unonboarded_app("dynamic", android_package="org.example.temporary")
        gradle = app / "android" / "app" / "build.gradle.kts"
        gradle.write_text('android { namespace = "org.example.namespace" }\n')

        with self.assertRaises(SystemExit):
            frk.cmd_onboard(self.onboard_args(app))

        args = self.onboard_args(
            app,
            platforms="android",
            android_package="org.example.actual",
        )
        self.assertEqual(0, frk.cmd_onboard(args))
        self.assertIn("package_name: org.example.actual", (app / frk.CONFIG_NAME).read_text())

    def test_existing_gitignore_marker_does_not_block_new_secret_rules(self):
        app = self.root / "ignore-update"
        app.mkdir()
        gitignore = app / ".gitignore"
        gitignore.write_text("# Flutter Release Kit — secrets. NEVER commit anything below.\n*.jks\n")

        result = frk.append_gitignore(app, dry=False)

        self.assertTrue(result.startswith("added "))
        self.assertIn("android/key.properties", gitignore.read_text())

    def test_key_properties_are_decoded_like_java_properties(self):
        properties = self.root / "key.properties"
        properties.write_text(
            "storeFile=../keys/upload.jks\n"
            "storePassword=store\\ secret=#value\n"
            "keyAlias=up\\u006coad\n"
            "keyPassword=literal\\\\backslash\n"
        )

        values = frk.read_properties(properties)

        self.assertEqual("store secret=#value", values["storePassword"])
        self.assertEqual("upload", values["keyAlias"])
        self.assertEqual("literal\\backslash", values["keyPassword"])

    def test_comment_ending_in_a_backslash_does_not_swallow_the_next_property(self):
        # java.util.Properties decides "comment" on the physical line, before any
        # line continuation, so a Windows path in a comment stays a comment.
        properties = self.root / "key.properties"
        properties.write_text(
            "# keystore lives under C:\\\n"
            "storeFile=/keys/upload.jks\n"
            "! legacy note \\\n"
            "storePassword=store-secret\n"
            "keyAlias=upload\n"
            "keyPassword=key-secret\n"
        )

        values = frk.read_properties(properties)

        self.assertEqual("/keys/upload.jks", values["storeFile"])
        self.assertEqual("store-secret", values["storePassword"])
        self.assertEqual(
            ["storeFile", "storePassword", "keyAlias", "keyPassword"], list(values)
        )

    def test_relative_keystore_path_matches_gradle_file_resolution(self):
        app = self.make_android_app("relative_store")
        properties = app / "android" / "key.properties"
        values = {"storeFile": "upload.jks"}
        gradle = app / "android" / "app" / "build.gradle.kts"

        gradle.write_text('storeFile = file(keystoreProperties["storeFile"] as String)\n')
        self.assertEqual(
            (app / "android" / "app" / "upload.jks").resolve(),
            frk.resolve_store_file(properties, values, app),
        )

        gradle.write_text('storeFile = rootProject.file(keystoreProperties["storeFile"] as String)\n')
        self.assertEqual(
            (app / "android" / "upload.jks").resolve(),
            frk.resolve_store_file(properties, values, app),
        )

    def test_signing_import_preserves_source_and_link_is_reversible(self):
        app = self.make_android_app(package="org.example.shipped")
        frk.register_project(app)
        source_dir = self.root / "old-signing"
        source_dir.mkdir()
        store = source_dir / "original.jks"
        store.write_bytes(b"fake-keystore-for-copy-test")
        source = source_dir / "key.properties"
        source.write_text(
            "storeFile=original.jks\n"
            "storePassword=store secret=#value\n"
            "keyAlias=upload\n"
            "keyPassword=key\\secret\n"
        )
        project_props = app / "android" / "key.properties"
        project_props.write_text("storeFile=../../old-signing/original.jks\n")

        import_args = argparse.Namespace(
            app_dir=str(app), properties=str(source), keystore=None,
            force=False, link=False, dry_run=False
        )
        with patch.object(frk, "validate_keystore_file", return_value="AA:BB"):
            self.assertEqual(0, frk.cmd_signing_import(import_args))
        self.assertTrue(source.is_file(), "the source must never be deleted")
        vault = frk.signing_dir() / "org.example.shipped"
        self.assertEqual(store.read_bytes(), (vault / "upload-keystore.jks").read_bytes())
        self.assertEqual(0o600, (vault / "key.properties").stat().st_mode & 0o777)
        central_text = (vault / "key.properties").read_text()
        self.assertIn("storePassword=store secret=#value", central_text)
        self.assertIn("keyPassword=key\\secret", central_text)

        self.assertEqual(0, frk.cmd_signing_link(argparse.Namespace(app_dir=str(app))))
        self.assertTrue(project_props.is_symlink())
        self.assertEqual((vault / "key.properties").resolve(), project_props.resolve())
        self.assertTrue(any((vault / "backups").iterdir()))

    def test_signing_import_normalises_colon_separated_properties(self):
        # read_properties accepts `=`, `:` and bare whitespace, and keytool has
        # already validated the keystore by the time the file is rewritten — so a
        # `:`-separated file must not die, and must land as `=` because the
        # shared Fastfile's preflight only reads `key=value`.
        app = self.make_android_app(package="org.example.colon")
        frk.register_project(app)
        source_dir = self.root / "colon-signing"
        source_dir.mkdir()
        store = source_dir / "original.jks"
        store.write_bytes(b"fake-keystore-for-colon-test")
        source = source_dir / "key.properties"
        source.write_text(
            "storeFile:original.jks\n"
            "storePassword : store-secret\n"
            "keyAlias upload\n"
            "keyPassword = key-secret\n"
        )
        args = argparse.Namespace(
            app_dir=str(app), properties=str(source), keystore=None,
            force=False, link=False, dry_run=False,
        )

        with patch.object(frk, "validate_keystore_file", return_value="AA:BB"):
            self.assertEqual(0, frk.cmd_signing_import(args))

        vault = frk.signing_dir() / "org.example.colon"
        self.assertEqual(
            f"storeFile={(vault / 'upload-keystore.jks').as_posix()}\n"
            "storePassword=store-secret\n"
            "keyAlias=upload\n"
            # Already an `=`, so Fastlane's preflight accepts it as written and
            # the line is left byte-for-byte alone.
            "keyPassword = key-secret\n",
            (vault / "key.properties").read_text(),
        )

    def test_selected_keystore_uses_existing_properties_and_links_atomically(self):
        app = self.make_android_app(package="org.example.selected")
        frk.register_project(app)
        chosen = self.root / "backup" / "upload-key.jks"
        chosen.parent.mkdir()
        chosen.write_bytes(b"selected-keystore")
        project_props = app / "android" / "key.properties"
        project_props.write_text(
            "storeFile=missing.jks\n"
            "storePassword=store-secret\n"
            "keyAlias=upload\n"
            "keyPassword=key-secret\n"
        )
        args = argparse.Namespace(
            app_dir=str(app), properties=None, keystore=str(chosen),
            force=False, link=True, dry_run=False,
        )

        with patch.object(frk, "validate_keystore_file", return_value="11:22"):
            self.assertEqual(0, frk.cmd_signing_import(args))

        vault_props = frk.signing_dir() / "org.example.selected" / "key.properties"
        self.assertTrue(project_props.is_symlink())
        self.assertEqual(vault_props.resolve(), project_props.resolve())
        self.assertNotIn("store-secret", self.stdout.getvalue())
        self.assertNotIn("key-secret", self.stdout.getvalue())

    def test_keystore_validation_keeps_password_out_of_process_arguments(self):
        keytool_result = types.SimpleNamespace(
            returncode=0,
            stdout="Certificate fingerprints:\n SHA256: AA:BB:CC\n",
            stderr="",
        )
        java_result = types.SimpleNamespace(returncode=0, stdout="FRK_KEY_OK\n", stderr="")
        properties = {
            "storePassword": "never-in-argv",
            "keyAlias": "upload",
            "keyPassword": "also-private",
        }
        fake_bin = self.root / "jdk" / "bin"
        fake_bin.mkdir(parents=True)
        keytool = fake_bin / "keytool"
        java = fake_bin / "java"
        keytool.touch(mode=0o700)
        java.touch(mode=0o700)

        with (
            patch.object(frk, "find_keytool", return_value=str(keytool)),
            patch.object(frk.subprocess, "run", side_effect=[keytool_result, java_result]) as run,
        ):
            fingerprint = frk.validate_keystore_file(self.root / "key.jks", properties)

        self.assertEqual("AA:BB:CC", fingerprint)
        self.assertEqual(2, run.call_count)
        for call in run.call_args_list:
            command = call.args[0]
            self.assertNotIn("never-in-argv", command)
            self.assertNotIn("also-private", command)
            self.assertEqual("never-in-argv", call.kwargs["env"]["FRK_STORE_PASSWORD"])
        self.assertEqual("also-private", run.call_args_list[1].kwargs["env"]["FRK_KEY_PASSWORD"])

    def test_a_committed_keystore_whose_name_starts_with_a_dash_is_reported_tracked(self):
        # The Git exposure check is a security guard: a filename Git reads as an
        # option must not be able to make it answer "not tracked".
        if not frk.shutil.which("git"):
            self.skipTest("git is not installed")
        repo = self.root / "dashrepo"
        repo.mkdir()
        frk.subprocess.run(["git", "init", "-q", str(repo)], check=True,
                           stdout=frk.subprocess.DEVNULL, stderr=frk.subprocess.DEVNULL)
        tracked = repo / "-upload.jks"
        tracked.write_bytes(b"keystore")
        untracked = repo / "-spare.jks"
        untracked.write_bytes(b"keystore")
        frk.subprocess.run(["git", "-C", str(repo), "add", "--", "-upload.jks"],
                           check=True, stdout=frk.subprocess.DEVNULL, stderr=frk.subprocess.DEVNULL)

        self.assertTrue(frk.git_tracks(repo, "-upload.jks"))
        self.assertTrue(frk.git_tracks_path(tracked))
        # And the separator does not turn every dashed path into a hit.
        self.assertFalse(frk.git_tracks(repo, "-spare.jks"))
        self.assertFalse(frk.git_tracks_path(untracked))

    def test_profile_validation_checks_identity_expiry_and_local_certificate(self):
        profile_path = self.root / "profile.mobileprovision"
        profile_path.touch()
        certificate = b"distribution-certificate"
        fingerprint = frk.hashlib.sha1(certificate).hexdigest().upper()
        profile = {
            "Name": "Example AppStore",
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=90),
            "TeamIdentifier": ["ABCDE12345"],
            "Entitlements": {
                "com.apple.developer.team-identifier": "ABCDE12345",
                "application-identifier": "ABCDE12345.org.example.app",
            },
            "DeveloperCertificates": [certificate],
        }

        with patch.object(frk, "decode_provisioning_profile", return_value=(profile, None)):
            record = frk.provisioning_profile_record(
                profile_path,
                "org.example.app",
                "ABCDE12345",
                [fingerprint],
            )

        self.assertTrue(record["ready"])
        self.assertTrue(record["certificateMatchesIdentity"])
        self.assertEqual("valid", record["status"])

    def test_setup_status_is_structured_and_never_contains_signing_passwords(self):
        app = self.make_android_app("setup_status", package="org.example.setup")
        frk.register_project(app)
        (app / "android" / "key.properties").write_text(
            "storeFile=missing.jks\n"
            "storePassword=do-not-expose\n"
            "keyAlias=upload\n"
            "keyPassword=also-private\n"
        )

        record = frk.setup_status_record(frk.managed_projects()[0])
        encoded = json.dumps(record)

        self.assertFalse(record["android"]["keystoreExists"])
        self.assertFalse(record["android"]["vaultReady"])
        self.assertNotIn("do-not-expose", encoded)
        self.assertNotIn("also-private", encoded)

    def test_release_uses_caffeinate_on_macos(self):
        app = self.root / "runner"
        app.mkdir()

        with (
            patch.object(frk.sys, "platform", "darwin"),
            patch.object(frk.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}"),
            patch.object(frk.subprocess, "Popen", return_value=FakeChild()) as call,
        ):
            self.assertEqual(
                0,
                frk.run_fastlane(app, ["android", "release"], prevent_sleep=True),
            )

        self.assertEqual(
            ["caffeinate", "-ims", "fastlane", "android", "release"],
            call.call_args.args[0],
        )
        self.assertTrue(call.call_args.kwargs["start_new_session"])

    def test_fastlane_signal_exit_uses_the_standard_shell_exit_code(self):
        command = [sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"]
        with (patch.object(frk, "fastlane_installed", return_value=True),
              patch.object(frk, "fastlane_command", return_value=command)):
            self.assertEqual(143, frk.run_fastlane(self.root, ["verify"]))

    def test_invalid_or_ambiguous_release_versions_fail_early(self):
        invalid = argparse.Namespace(
            build_name="2.0.0", build_number="0", skip_tests=False, skip_build=False, dry_run=False
        )
        with self.assertRaises(SystemExit):
            frk.lane_options(invalid, release=True)

        stale = argparse.Namespace(
            build_name="2.0.1", build_number="31", skip_tests=False, skip_build=True, dry_run=False
        )
        with self.assertRaises(SystemExit):
            frk.lane_options(stale, release=True)

    def test_api_capabilities_has_a_stable_versioned_contract(self):
        self.assertEqual(0, frk.cmd_api_capabilities(argparse.Namespace()))

        payload = json.loads(self.stdout.getvalue())
        self.assertEqual(1, payload["protocolVersion"])
        self.assertEqual(frk.VERSION, payload["cliVersion"])
        self.assertFalse(payload["capabilities"]["productionRelease"])
        self.assertIn("release", payload["capabilities"]["actions"])

    def test_api_project_summary_contains_no_signing_secrets(self):
        app = self.make_android_app("api_app", package="org.example.api")
        frk.register_project(app)
        (app / "android" / "key.properties").write_text(
            "storeFile=/private/upload.jks\n"
            "storePassword=never-print-this\n"
            "keyAlias=upload\n"
            "keyPassword=also-never-print-this\n"
        )

        record = frk.project_api_record(frk.managed_projects()[0])
        encoded = json.dumps(record)

        self.assertEqual("api_app", record["name"])
        self.assertEqual("1.2.3", record["buildName"])
        self.assertEqual(4, record["buildNumber"])
        self.assertNotIn("never-print-this", encoded)
        self.assertNotIn("also-never-print-this", encoded)

    def test_api_action_mapping_keeps_desktop_off_the_human_cli_contract(self):
        args = self.api_run_args(
            "validate",
            "sample",
            platform="android",
            build_name="2.0.0",
            build_number="38",
        )

        command = frk.api_action_command(args)

        self.assertEqual("release", command[2])
        self.assertIn("--dry-run", command)
        self.assertIn("--build-number", command)
        with self.assertRaises(ValueError):
            frk.api_action_command(self.api_run_args("validate", "sample", platform="ios"))

        signing = frk.api_action_command(self.api_run_args(
            "signing-import",
            "sample",
            keystore="/backup/upload.jks",
            link=True,
        ))
        self.assertEqual("signing", signing[2])
        self.assertIn("--keystore", signing)
        self.assertIn("--link", signing)

        ios_setup = frk.api_action_command(self.api_run_args("ios-setup-signing", "sample"))
        self.assertEqual([frk.sys.executable, str(FRK_PATH), "signing", "ios-setup", "--", "sample"], ios_setup)

        forget = frk.api_action_command(self.api_run_args("forget", "sample"))
        self.assertEqual([frk.sys.executable, str(FRK_PATH), "forget", "--", "sample"], forget)

    def test_api_never_ignores_an_unsupported_dry_run(self):
        for action in frk.API_RUN_ACTIONS:
            if action == "onboard":
                continue
            with self.subTest(action=action):
                self.stdout.seek(0)
                self.stdout.truncate()
                args = self.api_run_args(action, "sample", platform="android", dry_run=True)
                with patch.object(frk.subprocess, "Popen", side_effect=AssertionError("unsupported preview started work")) as spawn:
                    self.assertEqual(2, frk.cmd_api_run(args))
                spawn.assert_not_called()
                events = [json.loads(line) for line in self.stdout.getvalue().splitlines()]
                self.assertEqual(["error", "finished"], [event["type"] for event in events])
                self.assertEqual("invalid_request", events[0]["code"])
                self.assertIn("--dry-run", events[0]["message"])
                self.assertFalse(events[-1]["success"])
        self.assertIn("--dry-run", frk.api_action_command(self.api_run_args("onboard", "sample", dry_run=True)))

    def test_api_keeps_project_values_separate_from_child_cli_options(self):
        parser = self.build_frk_parser()
        for action in frk.API_RUN_ACTIONS:
            if action == "status":
                continue
            for project in ("--skip-tests", "--help", "a project with spaces"):
                with self.subTest(action=action, project=project):
                    command = frk.api_action_command(self.api_run_args(
                        action, project, platform="android", build_name="2.1.0", build_number="42",
                    ))
                    parsed = parser.parse_args(command[2:])
                    self.assertEqual(project, parsed.app_dir)
                    self.assertFalse(getattr(parsed, "skip_tests", False))
                    if action in ("build", "validate", "release"):
                        self.assertEqual(("2.1.0", "42"), (parsed.build_name, parsed.build_number))

    def test_cli_entrypoint_names_the_shipped_command_beside_the_shared_lanes(self):
        # Located from the repository layout rather than from bin/frk's own
        # __file__ arithmetic: `api run` re-invokes this path in a subprocess, so
        # it has to stay the installed command however the CLI is later split up.
        self.assertEqual(FRK_PATH, frk.CLI_ENTRYPOINT)
        self.assertTrue(frk.CLI_ENTRYPOINT.is_file())
        self.assertTrue((frk.KIT_ROOT / "fastlane" / "Fastfile").is_file())

    def test_api_run_streams_json_lines_and_a_terminal_event(self):
        args = self.api_run_args("status")
        command = [frk.sys.executable, "-c", "print('hello from child')"]

        with patch.object(frk, "api_action_command", return_value=command):
            self.assertEqual(0, frk.cmd_api_run(args))

        events = [json.loads(line) for line in self.stdout.getvalue().splitlines()]
        self.assertEqual(["started", "log", "finished"], [event["type"] for event in events])
        self.assertEqual("hello from child", events[1]["message"])
        self.assertTrue(events[-1]["success"])
        self.assertEqual(0, events[-1]["exitCode"])

    def spy_on_popen(self):
        """Collect every child `cmd_api_run` starts, and never leave one behind."""
        started = []
        real_popen = frk.subprocess.Popen

        def popen(*positional, **keyword):
            process = real_popen(*positional, **keyword)
            started.append(process)
            return process

        def reap():
            for process in started:
                if process.poll() is None:
                    process.kill()
                    process.wait()

        self.addCleanup(reap)
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(frk.subprocess, "Popen", popen))
        return started

    def test_api_run_resolves_the_child_against_the_callers_directory(self):
        # `frk doctor .` means the shell's directory, so `frk api run doctor .`
        # has to mean the same directory. The child used to be launched in the
        # kit checkout, which silently retargeted every relative argument.
        args = self.api_run_args("status")
        command = [frk.sys.executable, "-c", "import os; print(os.getcwd())"]
        caller = Path(self.root).resolve()
        self.addCleanup(os.chdir, os.getcwd())
        os.chdir(caller)

        with patch.object(frk, "api_action_command", return_value=command):
            self.assertEqual(0, frk.cmd_api_run(args))

        events = [json.loads(line) for line in self.stdout.getvalue().splitlines()]
        logs = [event["message"] for event in events if event["type"] == "log"]
        self.assertEqual([str(caller)], logs)
        self.assertNotEqual(str(frk.KIT_ROOT), logs[0])

    def test_api_run_replaces_undecodable_child_output_instead_of_failing(self):
        # Fastlane copies tool output through verbatim, so one stray byte from a
        # non-UTF-8 log used to abort the stream between `started` and `finished`.
        args = self.api_run_args("status")
        command = [
            frk.sys.executable,
            "-c",
            r"import sys; sys.stdout.buffer.write(b'before\n\xff bad\nafter\n')",
        ]

        with patch.object(frk, "api_action_command", return_value=command):
            self.assertEqual(0, frk.cmd_api_run(args))

        events = [json.loads(line) for line in self.stdout.getvalue().splitlines()]
        self.assertEqual(
            ["before", "� bad", "after"],
            [event["message"] for event in events if event["type"] == "log"],
        )
        self.assertEqual("finished", events[-1]["type"])
        self.assertTrue(events[-1]["success"])

    def test_api_run_reaps_the_child_and_still_reports_finished_when_streaming_fails(self):
        # The child is detached with start_new_session, so a failure while
        # reading its output is the one case where nothing else would ever stop
        # it — and the client is blocked until it sees a terminal event.
        started = self.spy_on_popen()
        args = self.api_run_args("status")
        command = [frk.sys.executable, "-c", "import time; print('one', flush=True); time.sleep(20)"]
        real_emit = frk.api_emit
        seen = []

        def emit(event_type, **payload):
            if event_type == "log":
                raise RuntimeError("stream consumer exploded")
            seen.append(event_type)
            real_emit(event_type, **payload)

        with patch.object(frk, "api_action_command", return_value=command):
            with patch.object(frk, "api_emit", emit):
                status = frk.cmd_api_run(args)

        self.assertNotEqual(0, status)
        self.assertEqual(["started", "error", "finished"], seen)
        self.assertIsNotNone(started[0].returncode)
        events = [json.loads(line) for line in self.stdout.getvalue().splitlines()]
        self.assertFalse(events[-1]["success"])
        self.assertEqual(status, events[-1]["exitCode"])
        self.assertIn("stream consumer exploded", events[-2]["message"])

    def test_api_run_reports_a_child_that_cannot_be_launched_as_error_then_finished(self):
        with patch.object(frk.subprocess, "Popen", side_effect=OSError("exec format error")):
            with patch.object(frk.sys, "argv", ["frk", "api", "run", "status"]):
                status = frk.main()

        self.assertNotEqual(0, status)
        events = [json.loads(line) for line in self.stdout.getvalue().splitlines()]
        self.assertEqual(["started", "error", "finished"], [event["type"] for event in events])
        self.assertFalse(events[-1]["success"])
        self.assertEqual(status, events[-1]["exitCode"])
        # docs/MACHINE_API.md documents `finished` as always carrying
        # durationSeconds. This escaped-failure path emitted it on the normal
        # and stream_failed routes but not here, so the wire and a versioned
        # protocol disagreed.
        self.assertIn("durationSeconds", events[-1])
        self.assertIsInstance(events[-1]["durationSeconds"], float)

    def test_every_finished_event_carries_a_duration_on_the_escaped_failure_path(self):
        args = argparse.Namespace(action="build", api_stream_command=True)
        seen = []

        with patch.object(frk, "api_emit", lambda kind, **payload: seen.append((kind, payload))):
            self.assertEqual(3, frk.api_failure_channel(args, "command_failed", "boom", 3))

        self.assertEqual(["error", "finished"], [kind for kind, _ in seen])
        finished = dict(seen)["finished"]
        self.assertEqual(0.0, finished["durationSeconds"])
        self.assertEqual(3, finished["exitCode"])
        self.assertFalse(finished["success"])

    # ----------------------------------------------------------------- #
    # registry loading guards
    # ----------------------------------------------------------------- #
    def write_registry(self, text):
        self.release_home.mkdir(parents=True, exist_ok=True)
        frk.registry_path().write_text(text)

    def test_registry_with_truncated_json_is_rejected(self):
        self.write_registry('{"version": 1, "projects": [')

        with self.assertRaises(SystemExit) as raised:
            frk.load_registry()

        # die() exits with an int code, so the message only reaches stderr.
        self.assertEqual(1, raised.exception.code)
        self.assertIn("could not read registry", self.stderr.getvalue())
        self.assertIn(str(frk.registry_path()), self.stderr.getvalue())

    def test_registry_with_projects_as_a_mapping_is_rejected(self):
        self.write_registry(json.dumps({"projects": {}}))

        with self.assertRaises(SystemExit) as raised:
            frk.load_registry()

        self.assertEqual(1, raised.exception.code)
        self.assertIn("invalid project registry", self.stderr.getvalue())

    def test_registry_from_a_future_version_is_rejected(self):
        self.write_registry(json.dumps({"version": 2, "projects": []}))

        with self.assertRaises(SystemExit) as raised:
            frk.load_registry()

        self.assertEqual(1, raised.exception.code)
        # Pinned whole, not with assertIn: a future version is refused with the
        # same sentence as every other unreadable version, and appending a
        # reason to this one branch is a silent change to the CLI's contract.
        self.assertEqual(
            f"\nerror: unsupported project registry version in {frk.registry_path()}\n",
            self.stderr.getvalue(),
        )

    def test_registry_entry_without_a_path_is_rejected(self):
        self.write_registry(json.dumps({"version": 1, "projects": [{}]}))

        with self.assertRaises(SystemExit) as raised:
            frk.load_registry()

        self.assertEqual(1, raised.exception.code)
        self.assertIn("invalid project entry in registry", self.stderr.getvalue())

    def test_registry_without_a_version_key_is_tolerated(self):
        entry = {"name": "legacy", "path": str(self.root / "legacy"), "platforms": ["android"]}
        self.write_registry(json.dumps({"projects": [entry]}))

        data = frk.load_registry()

        # `data.get("version", REGISTRY_VERSION)` defaults a missing version to
        # the current one, so pre-versioning registries still load unchanged.
        self.assertNotIn("version", data)
        self.assertEqual([entry], data["projects"])
        self.assertEqual([entry], frk.managed_projects())
        self.assertEqual("", self.stderr.getvalue())

    def test_a_registry_older_than_the_current_format_needs_a_migration(self):
        # REGISTRY_MIGRATIONS is empty, so no chain reaches version 1 and the
        # walk has to refuse rather than load a format it cannot read.
        self.write_registry(json.dumps({"version": 0, "projects": []}))

        with self.assertRaises(SystemExit) as raised:
            frk.load_registry()

        self.assertEqual(1, raised.exception.code)
        self.assertIn("unsupported project registry version", self.stderr.getvalue())
        self.assertNotIn("newer frk", self.stderr.getvalue())

    def test_a_registry_version_that_is_not_a_number_is_rejected(self):
        self.write_registry(json.dumps({"version": "1", "projects": []}))

        with self.assertRaises(SystemExit) as raised:
            frk.load_registry()

        self.assertEqual(1, raised.exception.code)
        self.assertIn("unsupported project registry version", self.stderr.getvalue())

    def test_a_registered_migration_chain_upgrades_an_older_registry(self):
        entry = {"name": "legacy", "path": str(self.root / "legacy")}
        self.write_registry(json.dumps({"version": -1, "projects": [entry]}))
        steps = []

        def step(source):
            def migrate(data):
                steps.append(source)
                return dict(data, version=source + 1)
            return migrate

        with patch.dict(frk.REGISTRY_MIGRATIONS, {-1: step(-1), 0: step(0)}, clear=True):
            data = frk.load_registry()

        # Every step runs in order, and the walk stops at the current version.
        self.assertEqual([-1, 0], steps)
        self.assertEqual(frk.REGISTRY_VERSION, data["version"])
        self.assertEqual([entry], data["projects"])
        self.assertEqual("", self.stderr.getvalue())

    def test_a_migration_chain_with_a_missing_step_is_refused(self):
        self.write_registry(json.dumps({"version": -1, "projects": []}))

        with patch.dict(frk.REGISTRY_MIGRATIONS, {0: lambda data: data}, clear=True):
            with self.assertRaises(SystemExit) as raised:
                frk.load_registry()

        # The chain covers 0 -> 1 but nothing reads -1, so it is incomplete.
        self.assertEqual(1, raised.exception.code)
        self.assertIn("unsupported project registry version", self.stderr.getvalue())

    def test_missing_registry_returns_the_default_without_creating_a_file(self):
        self.assertFalse(frk.registry_path().exists())

        data = frk.load_registry()

        self.assertEqual({"version": frk.REGISTRY_VERSION, "projects": []}, data)
        self.assertFalse(frk.registry_path().exists())
        self.assertFalse(self.release_home.exists())

    # ----------------------------------------------------------------- #
    # machine API entry points
    # ----------------------------------------------------------------- #
    CREDENTIAL_ENV_KEYS = (
        "SUPPLY_JSON_KEY",
        "ASC_KEY_ID",
        "ASC_ISSUER_ID",
        "ASC_KEY_CONTENT",
        "ASC_KEY_FILEPATH",
    )

    def reset_stdout(self):
        """Discards output captured so far, so an assertion on the NEXT call's
        stdout is not also reading a setup step's (e.g. cmd_onboard's)."""
        self.stdout.truncate(0)
        self.stdout.seek(0)

    def isolate_credential_env(self):
        """credential_status_record reads the ambient environment first."""
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.dict(os.environ))
        for key in self.CREDENTIAL_ENV_KEYS:
            os.environ.pop(key, None)

    def write_play_key(self):
        source = self.root / "google-service-account.json"
        source.write_text(json.dumps({
            "type": "service_account",
            "project_id": "release-project",
            "private_key_id": "private-id",
            "private_key": "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----\n",
            "client_email": "releases@example.iam.gserviceaccount.com",
        }))
        return source

    def payload(self):
        return json.loads(self.stdout.getvalue())

    def test_api_projects_returns_an_empty_document_for_an_empty_registry(self):
        self.assertEqual(0, frk.cmd_api_projects(argparse.Namespace()))

        payload = self.payload()
        self.assertEqual({"protocolVersion", "cliVersion", "projects"}, set(payload))
        self.assertEqual(1, payload["protocolVersion"])
        self.assertEqual(frk.VERSION, payload["cliVersion"])
        self.assertEqual([], payload["projects"])

    def test_api_projects_describes_a_registered_android_project(self):
        app = self.make_android_app("listed", package="org.example.listed")
        frk.register_project(app)

        self.assertEqual(0, frk.cmd_api_projects(argparse.Namespace()))

        payload = self.payload()
        self.assertEqual(1, len(payload["projects"]))
        record = payload["projects"][0]
        self.assertEqual(
            {
                "id", "name", "path", "exists", "onboarded", "state", "platforms",
                "version", "buildName", "buildNumber", "android", "ios",
                "artifacts", "addedAt",
            },
            set(record),
        )
        self.assertEqual("listed", record["id"])
        self.assertEqual("listed", record["name"])
        self.assertEqual(str(app.resolve()), record["path"])
        self.assertTrue(record["exists"])
        self.assertTrue(record["onboarded"])
        self.assertEqual("ready", record["state"])
        self.assertEqual(["android"], record["platforms"])
        self.assertEqual("1.2.3+4", record["version"])
        self.assertEqual("1.2.3", record["buildName"])
        self.assertEqual(4, record["buildNumber"])
        self.assertEqual(
            {"packageId": "org.example.listed", "signingReady": False, "track": "internal"},
            record["android"],
        )
        self.assertIsNone(record["ios"])
        self.assertEqual({"androidAab": None, "iosIpa": None}, record["artifacts"])
        self.assertIsInstance(record["addedAt"], str)

    def test_list_and_the_api_agree_on_what_counts_as_onboarded(self):
        # One predicate feeds both surfaces. An app that lost its importer must
        # never read as ready in `frk list` while the machine record calls it
        # incomplete — these two used to spell the rule out separately.
        complete = self.make_android_app("complete", package="org.example.complete")
        half = self.make_android_app("half", package="org.example.half")
        (half / "fastlane" / "Fastfile").write_text("# importer removed\n")
        frk.register_project(complete)
        frk.register_project(half)

        for entry in frk.managed_projects():
            record = frk.project_api_record(entry)
            app = Path(entry["path"])
            self.assertEqual(frk.is_onboarded(app), record["onboarded"])
            self.assertEqual("ready" if record["onboarded"] else "incomplete", record["state"])

        self.assertEqual(0, frk.cmd_list(argparse.Namespace()))
        rows = {
            line.split()[0]: line
            for line in self.stdout.getvalue().splitlines()
            if line.startswith(("complete", "half"))
        }
        self.assertNotIn("[incomplete]", rows["complete"])
        self.assertIn("[incomplete]", rows["half"])

    def test_credential_precedence_skips_the_app_tier_for_the_machine_report(self):
        # A build honours a per-app fastlane/.env, but `frk api credentials`
        # describes the shared vault and must ignore it.
        self.isolate_credential_env()
        app = self.make_android_app("scoped", package="org.example.scoped")
        (app / "fastlane" / ".env").write_text("ASC_KEY_ID=APPLOCALXX\n")
        env_file = frk.ensure_credential_vault()
        frk.update_env_values(env_file, {"ASC_KEY_ID": "SHAREDKEY1"})

        self.assertEqual("APPLOCALXX", frk.credential_value("ASC_KEY_ID", app))
        self.assertEqual("SHAREDKEY1", frk.credential_value("ASC_KEY_ID"))
        self.assertEqual("SHAREDKEY1", frk.credential_status_record()["appStoreConnect"]["keyId"])

    def test_credential_vault_creates_the_signing_directory_only_on_request(self):
        frk.ensure_credential_vault()
        self.assertTrue((frk.credentials_dir() / "asc").is_dir())
        self.assertFalse(frk.signing_dir().exists())

        frk.ensure_credential_vault(include_signing=True)
        self.assertTrue(frk.signing_dir().is_dir())

    def test_api_credentials_reports_an_unconfigured_vault(self):
        self.isolate_credential_env()

        self.assertEqual(0, frk.cmd_api_credentials(argparse.Namespace()))

        payload = self.payload()
        self.assertEqual(
            {"protocolVersion", "cliVersion", "vaultPath", "configuredAny",
             "googlePlay", "appStoreConnect"},
            set(payload),
        )
        self.assertEqual(1, payload["protocolVersion"])
        # The vault path is reported even though the directory does not exist.
        self.assertEqual(str(self.release_home.resolve()), payload["vaultPath"])
        self.assertFalse(payload["configuredAny"])
        self.assertEqual(
            {"configured", "validationStatus", "detail", "keyPath", "clientEmail", "projectId"},
            set(payload["googlePlay"]),
        )
        self.assertEqual(
            {"configured", "validationStatus", "detail", "keyPath", "keyId", "issuerId"},
            set(payload["appStoreConnect"]),
        )
        self.assertEqual("missing", payload["googlePlay"]["validationStatus"])
        self.assertEqual("missing", payload["appStoreConnect"]["validationStatus"])
        self.assertIsNone(payload["googlePlay"]["keyPath"])
        self.assertIsNone(payload["appStoreConnect"]["keyId"])

    def test_api_credentials_reports_a_seeded_google_play_vault(self):
        self.isolate_credential_env()
        frk.configure_play_credentials(str(self.write_play_key()), force=False)

        self.assertEqual(0, frk.cmd_api_credentials(argparse.Namespace()))

        payload = self.payload()
        self.assertTrue(payload["configuredAny"])
        self.assertTrue(payload["googlePlay"]["configured"])
        self.assertEqual("ready", payload["googlePlay"]["validationStatus"])
        self.assertEqual("Service-account key is valid", payload["googlePlay"]["detail"])
        self.assertEqual(
            str((self.release_home / "play" / "service-account.json").resolve()),
            payload["googlePlay"]["keyPath"],
        )
        self.assertEqual(
            "releases@example.iam.gserviceaccount.com", payload["googlePlay"]["clientEmail"]
        )
        self.assertEqual("release-project", payload["googlePlay"]["projectId"])
        self.assertFalse(payload["appStoreConnect"]["configured"])
        self.assertEqual("missing", payload["appStoreConnect"]["validationStatus"])

    def test_api_project_returns_the_record_for_a_known_project(self):
        app = self.make_android_app("known", package="org.example.known")
        frk.register_project(app)

        self.assertEqual(0, frk.cmd_api_project(argparse.Namespace(app_dir="known")))

        payload = self.payload()
        self.assertEqual({"protocolVersion", "cliVersion", "project"}, set(payload))
        self.assertEqual("known", payload["project"]["id"])
        self.assertEqual(str(app.resolve()), payload["project"]["path"])
        self.assertEqual("ready", payload["project"]["state"])

    def test_api_project_reports_project_not_found_and_exits_nonzero(self):
        self.assertEqual(1, frk.cmd_api_project(argparse.Namespace(app_dir="ghost")))

        payload = self.payload()
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(payload))
        self.assertEqual({"code", "message"}, set(payload["error"]))
        self.assertEqual("project_not_found", payload["error"]["code"])
        self.assertEqual(
            "No managed project named or located at ghost", payload["error"]["message"]
        )

    def test_api_setup_returns_the_android_setup_status_for_a_known_project(self):
        app = self.make_android_app("setupable", package="org.example.setupable")
        frk.register_project(app)

        self.assertEqual(0, frk.cmd_api_setup(argparse.Namespace(app_dir="setupable")))

        payload = self.payload()
        self.assertEqual(
            {"protocolVersion", "cliVersion", "projectId", "android", "ios"}, set(payload)
        )
        self.assertEqual("setupable", payload["projectId"])
        self.assertIsNone(payload["ios"])
        android = payload["android"]
        self.assertEqual(
            {
                "configured", "packageId", "projectPropertiesPath", "projectPropertiesExists",
                "propertiesComplete", "missingPropertiesFields", "referencedKeystorePath",
                "keystoreExists", "keystoreValidationStatus", "keystoreValidationDetail",
                "certificateSHA256", "gradleConfigured", "gradleConfigurationPath",
                "gradleConfigurationDetail", "vaultPath", "vaultReady", "projectLinked",
                "gitTracked", "propertiesGitIgnored", "keystoreGitTracked",
                "keystoreGitIgnored", "gitSafe", "signingReady",
            },
            set(android),
        )
        self.assertTrue(android["configured"])
        self.assertEqual("org.example.setupable", android["packageId"])
        self.assertFalse(android["projectPropertiesExists"])
        self.assertFalse(android["propertiesComplete"])
        self.assertEqual(list(frk.ANDROID_SIGNING_KEYS), android["missingPropertiesFields"])
        self.assertIsNone(android["referencedKeystorePath"])
        self.assertEqual("notChecked", android["keystoreValidationStatus"])
        self.assertIsNone(android["certificateSHA256"])
        self.assertEqual(str(frk.signing_dir() / "org.example.setupable"), android["vaultPath"])
        self.assertFalse(android["vaultReady"])
        self.assertFalse(android["projectLinked"])
        self.assertFalse(android["signingReady"])

    def test_api_setup_reports_project_not_found_and_exits_nonzero(self):
        self.assertEqual(1, frk.cmd_api_setup(argparse.Namespace(app_dir="ghost")))

        payload = self.payload()
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(payload))
        self.assertEqual("project_not_found", payload["error"]["code"])
        self.assertEqual(
            "No managed project named or located at ghost", payload["error"]["message"]
        )

    def test_api_configure_credentials_returns_the_credential_document_on_success(self):
        self.isolate_credential_env()
        args = argparse.Namespace(
            store="google-play",
            file=str(self.write_play_key()),
            key_id=None,
            issuer_id=None,
            force=False,
        )

        self.assertEqual(0, frk.cmd_api_configure_credentials(args))

        payload = self.payload()
        self.assertEqual(
            {"protocolVersion", "cliVersion", "vaultPath", "configuredAny",
             "googlePlay", "appStoreConnect"},
            set(payload),
        )
        self.assertTrue(payload["configuredAny"])
        self.assertTrue(payload["googlePlay"]["configured"])
        self.assertEqual("ready", payload["googlePlay"]["validationStatus"])
        self.assertIn("SUPPLY_JSON_KEY=play/service-account.json",
                      (self.release_home / "credentials.env").read_text())

    def test_api_configure_credentials_reports_an_unwritable_vault_as_one_document(self):
        # A vault that cannot be created is an OSError, not a ValueError, and
        # used to leave the client with zero bytes of stdout and a traceback.
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            self.skipTest("root ignores directory permissions")
        self.isolate_credential_env()
        locked = self.root / "locked"
        locked.mkdir()
        self.addCleanup(locked.chmod, 0o700)
        locked.chmod(0o500)
        argv = ["frk", "api", "configure-credentials", "google-play",
                "--file", str(self.write_play_key())]

        with patch.dict(os.environ, {"FLUTTER_RELEASE_HOME": str(locked / "vault")}):
            with patch.object(frk.sys, "argv", argv):
                status = frk.main()

        self.assertEqual(1, status)
        lines = self.stdout.getvalue().splitlines()
        self.assertEqual(1, len(lines))
        payload = json.loads(lines[0])
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(payload))
        self.assertEqual("credential_vault_unavailable", payload["error"]["code"])
        self.assertIn(str(locked / "vault"), payload["error"]["message"])

    def test_api_projects_reports_a_corrupt_registry_as_one_document(self):
        # load_registry dies with a human sentence on stderr. On a machine-API
        # command that has to arrive as a document, not as nothing at all.
        self.write_registry('{"version": 1, "projects": [')

        with patch.object(frk.sys, "argv", ["frk", "api", "projects"]):
            status = frk.main()

        self.assertEqual(1, status)
        lines = self.stdout.getvalue().splitlines()
        self.assertEqual(1, len(lines))
        payload = json.loads(lines[0])
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(payload))
        self.assertEqual("command_failed", payload["error"]["code"])
        # The diagnostic itself still goes to stderr, exactly as it does for the
        # human command; the document carries the fact and the exit code.
        self.assertIn("could not read registry", self.stderr.getvalue())

    def test_a_human_command_keeps_its_stderr_contract_when_it_dies(self):
        # The JSON boundary is opt-in per subcommand, so `frk list` must still
        # exit through die() with nothing on stdout.
        self.write_registry('{"version": 1, "projects": [')

        with patch.object(frk.sys, "argv", ["frk", "list"]):
            with self.assertRaises(SystemExit) as raised:
                frk.main()

        self.assertEqual(1, raised.exception.code)
        self.assertEqual("", self.stdout.getvalue())
        self.assertIn("could not read registry", self.stderr.getvalue())

    def test_api_configure_credentials_rejects_a_non_service_account_json(self):
        self.isolate_credential_env()
        invalid_play = self.root / "not-a-service-account.json"
        invalid_play.write_text('{"type":"authorized_user"}')
        args = argparse.Namespace(
            store="google-play", file=str(invalid_play), key_id=None, issuer_id=None, force=False
        )

        self.assertEqual(1, frk.cmd_api_configure_credentials(args))

        payload = self.payload()
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(payload))
        self.assertEqual("invalid_credentials", payload["error"]["code"])
        self.assertEqual(
            "Selected JSON is not a Google service-account key", payload["error"]["message"]
        )
        self.assertFalse((self.release_home / "credentials.env").exists())

    def test_api_configure_credentials_rejects_a_p8_file_that_is_not_a_private_key(self):
        self.isolate_credential_env()
        invalid_p8 = self.root / "not-a-key.p8"
        invalid_p8.write_text("not a private key")
        args = argparse.Namespace(
            store="app-store-connect",
            file=str(invalid_p8),
            key_id="ABCDEFGHIJ",
            issuer_id="12345678-1234-1234-1234-123456789abc",
            force=False,
        )

        self.assertEqual(1, frk.cmd_api_configure_credentials(args))

        payload = self.payload()
        self.assertEqual("invalid_credentials", payload["error"]["code"])
        self.assertEqual(
            "Selected file is not a valid App Store Connect .p8 private key",
            payload["error"]["message"],
        )
        self.assertFalse((self.release_home / "credentials.env").exists())

    def test_distribution_identity_record_selects_the_identity_naming_the_team(self):
        frk.distribution_identities.cache = [
            {"fingerprint": "A" * 40, "name": "Apple Distribution: Example Ltd (ABCDE12345)"},
            {"fingerprint": "B" * 40, "name": "Apple Distribution: Other Ltd (ZZZZZ99999)"},
        ]

        record = frk.distribution_identity_record("ABCDE12345")

        self.assertEqual({"ready", "checked", "detail", "fingerprints"}, set(record))
        self.assertTrue(record["ready"])
        self.assertTrue(record["checked"])
        self.assertEqual(["A" * 40], record["fingerprints"])
        self.assertEqual(
            "Certificate and private key for team ABCDE12345 are available in Keychain",
            record["detail"],
        )

    def test_distribution_identity_record_accepts_one_unlabelled_identity(self):
        frk.distribution_identities.cache = [
            {"fingerprint": "C" * 40, "name": "iPhone Distribution: Legacy Ltd"}
        ]

        record = frk.distribution_identity_record("ABCDE12345")

        self.assertTrue(record["ready"])
        self.assertEqual(["C" * 40], record["fingerprints"])
        self.assertEqual(
            "One distribution identity is available; the profile check confirms whether it belongs to this app",
            record["detail"],
        )

    def test_distribution_identity_record_rejects_several_unmatched_identities(self):
        frk.distribution_identities.cache = [
            {"fingerprint": "D" * 40, "name": "iPhone Distribution: Legacy Ltd"},
            {"fingerprint": "E" * 40, "name": "iPhone Distribution: Other Ltd"},
        ]

        record = frk.distribution_identity_record("ABCDE12345")

        self.assertFalse(record["ready"])
        self.assertEqual([], record["fingerprints"])
        self.assertEqual(
            "Distribution identities exist, but none can be associated with team ABCDE12345",
            record["detail"],
        )

    def test_distribution_identity_record_without_any_identity_is_not_ready(self):
        frk.distribution_identities.cache = []

        record = frk.distribution_identity_record("ABCDE12345")

        self.assertFalse(record["ready"])
        self.assertEqual([], record["fingerprints"])
        self.assertEqual(
            "No Apple Distribution certificate with its private key is available in Keychain",
            record["detail"],
        )

    def test_ios_setup_record_is_ready_when_project_profile_and_export_options_agree(self):
        self.isolate_credential_env()
        bundle, team = "org.example.ios", "ABCDE12345"
        app = self.make_unonboarded_app("ios_ready", ios_bundle=bundle, ios_team=team)
        (app / "ios" / "Runner.xcworkspace").mkdir(parents=True)
        (app / "ios" / "ExportOptions.plist").write_bytes(frk.plistlib.dumps({
            "method": "app-store-connect",
            "teamID": team,
            "signingStyle": "manual",
            "destination": "export",
            "provisioningProfiles": {bundle: f"{bundle} AppStore"},
        }))
        certificate = b"distribution-certificate"
        fingerprint = frk.hashlib.sha1(certificate).hexdigest().upper()
        frk.distribution_identities.cache = [
            {"fingerprint": fingerprint, "name": f"Apple Distribution: Example ({team})"}
        ]
        profile_path = frk.signing_dir() / "ios" / team / f"AppStore_{bundle}.mobileprovision"
        profile_path.parent.mkdir(parents=True)
        profile_path.touch()
        profile = {
            "Name": "Example AppStore",
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=30),
            "TeamIdentifier": [team],
            "Entitlements": {
                "com.apple.developer.team-identifier": team,
                "application-identifier": f"{team}.{bundle}",
            },
            "DeveloperCertificates": [certificate],
        }

        with patch.object(frk, "decode_provisioning_profile", return_value=(profile, None)):
            record = frk.ios_setup_record(app, bundle, team)

        self.assertEqual(
            {
                "configured", "bundleId", "teamId", "projectIdentityReady",
                "projectIdentityDetail", "workspacePath", "workspaceExists",
                "distributionIdentityReady", "distributionIdentityDetail",
                "ascCredentialsReady", "profilePath", "profileReady",
                "profileValidationStatus", "profileValidationDetail", "profileExpiresAt",
                "profileCertificateMatchesIdentity", "exportOptionsReady",
                "exportOptionsPath", "exportOptionsDetail", "signingReady",
            },
            set(record),
        )
        self.assertTrue(record["configured"])
        self.assertEqual(bundle, record["bundleId"])
        self.assertEqual(team, record["teamId"])
        self.assertTrue(record["projectIdentityReady"])
        self.assertEqual(f"Bundle {bundle} uses Apple team {team}", record["projectIdentityDetail"])
        self.assertTrue(record["workspaceExists"])
        self.assertTrue(record["distributionIdentityReady"])
        self.assertEqual(str(profile_path), record["profilePath"])
        self.assertTrue(record["profileReady"])
        self.assertEqual("valid", record["profileValidationStatus"])
        self.assertTrue(record["profileCertificateMatchesIdentity"])
        self.assertTrue(record["exportOptionsReady"])
        self.assertEqual(
            "Export settings match this app, team, and profile", record["exportOptionsDetail"]
        )
        # ascCredentialsReady is not part of signingReady, so an unconfigured
        # App Store Connect key still yields a "ready" iOS signing record.
        self.assertFalse(record["ascCredentialsReady"])
        self.assertTrue(record["signingReady"])

    def test_ios_setup_record_reports_each_missing_signing_piece(self):
        self.isolate_credential_env()
        frk.distribution_identities.cache = []
        bundle, team = "org.example.bare", "ABCDE12345"
        app = self.make_unonboarded_app("ios_bare", ios_bundle=bundle, ios_team=team)

        record = frk.ios_setup_record(app, bundle, team)

        self.assertTrue(record["projectIdentityReady"])
        self.assertFalse(record["workspaceExists"])
        self.assertFalse(record["distributionIdentityReady"])
        self.assertFalse(record["ascCredentialsReady"])
        self.assertEqual("missing", record["profileValidationStatus"])
        self.assertEqual(
            "The app-specific App Store provisioning profile is missing",
            record["profileValidationDetail"],
        )
        self.assertFalse(record["profileReady"])
        self.assertIsNone(record["profileExpiresAt"])
        self.assertFalse(record["profileCertificateMatchesIdentity"])
        self.assertFalse(record["exportOptionsReady"])
        self.assertEqual("ios/ExportOptions.plist is missing", record["exportOptionsDetail"])
        self.assertFalse(record["signingReady"])

    def onboard_ios_app(self, name, bundle, team):
        """A fully onboarded iOS app: real `ios/Runner.xcodeproj`, registered,
        and configured — the state `cmd_signing_ios_setup` requires, distinct
        from `make_unonboarded_app`'s bare fixture."""
        app = self.make_unonboarded_app(name, ios_bundle=bundle, ios_team=team)
        exit_code = frk.cmd_onboard(self.onboard_args(app))
        self.assertEqual(0, exit_code)
        return app

    def test_ios_setup_backs_up_and_regenerates_a_stale_export_options_plist(self):
        bundle, team = "org.example.stale", "ABCDE12345"
        app = self.onboard_ios_app("ios_stale", bundle, team)
        # Onboarding already wrote a valid ExportOptions.plist; overwrite it
        # with a stale one afterwards so this test controls what gets backed up.
        (app / "ios" / "ExportOptions.plist").write_bytes(frk.plistlib.dumps({
            "method": "app-store-connect",
            "teamID": "WRONGTEAM1",
            "signingStyle": "manual",
            "destination": "export",
            "provisioningProfiles": {bundle: f"{bundle} AppStore"},
        }))

        with patch.object(frk, "run_fastlane", return_value=0) as run_fastlane:
            exit_code = frk.cmd_signing_ios_setup(argparse.Namespace(app_dir=str(app)))

        self.assertEqual(0, exit_code)
        run_fastlane.assert_called_once_with(app.resolve(), ["ios", "setup_signing"], prevent_sleep=True)

        backups = list((frk.signing_dir() / "ios" / team / "backups").glob(f"{app.name}-ExportOptions-*.plist"))
        self.assertEqual(1, len(backups))
        self.assertEqual("WRONGTEAM1", frk.plistlib.loads(backups[0].read_bytes())["teamID"])
        self.assertEqual(0o600, stat.S_IMODE(backups[0].stat().st_mode))

        regenerated = frk.plistlib.loads((app / "ios" / "ExportOptions.plist").read_bytes())
        self.assertEqual(team, regenerated["teamID"])
        self.assertEqual(f"{bundle} AppStore", regenerated["provisioningProfiles"][bundle])

    def test_ios_setup_backs_up_the_xcode_project_before_the_lane_can_edit_it(self):
        bundle, team = "org.example.pbx", "ABCDE12345"
        app = self.onboard_ios_app("ios_pbx", bundle, team)
        pbxproj = app / "ios" / "Runner.xcodeproj" / "project.pbxproj"
        original = pbxproj.read_bytes() + b"\n// marker so this test can tell its own copy apart\n"
        pbxproj.write_bytes(original)

        with patch.object(frk, "run_fastlane", return_value=0):
            frk.cmd_signing_ios_setup(argparse.Namespace(app_dir=str(app)))

        backups = list((frk.signing_dir() / "ios" / team / "backups").glob(f"{app.name}-project.pbxproj-*"))
        self.assertEqual(1, len(backups))
        self.assertEqual(original, backups[0].read_bytes())
        self.assertEqual(0o600, stat.S_IMODE(backups[0].stat().st_mode))
        # The Python side only backs the file up; rewriting it is the lane's job,
        # which is patched out here, so the working copy must be untouched.
        self.assertEqual(original, pbxproj.read_bytes())

    def test_ios_setup_skips_the_project_backup_when_there_is_no_project_yet(self):
        bundle, team = "org.example.nopbx", "ABCDE12345"
        app = self.onboard_ios_app("ios_nopbx", bundle, team)
        shutil.rmtree(app / "ios" / "Runner.xcodeproj")

        with patch.object(frk, "run_fastlane", return_value=0):
            exit_code = frk.cmd_signing_ios_setup(argparse.Namespace(app_dir=str(app)))

        self.assertEqual(0, exit_code)
        backups_dir = frk.signing_dir() / "ios" / team / "backups"
        self.assertFalse(backups_dir.exists() and any(backups_dir.glob("*project.pbxproj*")))

    # ----------------------------------------------------------------- #
    # Android keystore probing
    # ----------------------------------------------------------------- #
    PROBE_PROPERTIES = {
        "storePassword": "store-secret-value",
        "keyAlias": "upload",
        "keyPassword": "key-secret-value",
    }

    def make_jdk_bin(self, name, with_java=True):
        bin_dir = self.root / name / "bin"
        bin_dir.mkdir(parents=True)
        keytool = bin_dir / "keytool"
        keytool.touch(mode=0o700)
        if with_java:
            (bin_dir / "java").touch(mode=0o700)
        return keytool

    def test_probe_keystore_file_reports_every_failure_branch_without_leaking_passwords(self):
        store = self.root / "upload.jks"
        with_java = self.make_jdk_bin("jdk-full", with_java=True)
        without_java = self.make_jdk_bin("jdk-bare", with_java=False)
        keytool_ok = types.SimpleNamespace(
            returncode=0,
            stdout="Certificate fingerprints:\n\t SHA256: AA:BB:CC\n",
            stderr="",
        )
        java_ok = types.SimpleNamespace(returncode=0, stdout="FRK_KEY_OK\n", stderr="")
        java_fail = types.SimpleNamespace(
            returncode=1,
            stdout="",
            stderr=(
                "java.security.UnrecoverableKeyException: Get Key failed\n"
                "\tat java.base/sun.security.provider.KeyProtector.recover(KeyProtector.java:329)\n"
            ),
        )
        cases = [
            {
                "label": "no keytool on the machine",
                "keytool": None,
                "runs": [],
                "status": "unavailable",
                "fingerprint": None,
                "detail": (
                    "A JDK keytool was not found; "
                    "install/configure Flutter's Android toolchain"
                ),
            },
            {
                "label": "keytool times out",
                "keytool": with_java,
                "runs": [frk.subprocess.TimeoutExpired(cmd=["keytool"], timeout=20)],
                "status": "invalid",
                "fingerprint": None,
                "detail": "Keystore validation timed out",
            },
            {
                "label": "keytool rejects the store",
                "keytool": with_java,
                "runs": [types.SimpleNamespace(
                    returncode=1,
                    stdout="",
                    stderr=(
                        "keytool error: java.io.IOException: "
                        "Keystore was tampered with, or password was incorrect\n"
                    ),
                )],
                "status": "invalid",
                "fingerprint": None,
                "detail": (
                    "Store password, file, or keyAlias is incorrect: "
                    "keytool error: java.io.IOException: "
                    "Keystore was tampered with, or password was incorrect"
                ),
            },
            {
                "label": "no java beside keytool leaves the key password unchecked",
                "keytool": without_java,
                "runs": [keytool_ok],
                "status": "partial",
                "fingerprint": "AA:BB:CC",
                "detail": (
                    "Store password and alias are valid; the private-key password "
                    "will be checked by the first release build"
                ),
            },
            {
                "label": "java rejects the private-key password",
                "keytool": with_java,
                "runs": [keytool_ok, java_fail],
                "status": "invalid",
                "fingerprint": "AA:BB:CC",
                "detail": (
                    "keyPassword or keyAlias is incorrect: "
                    "java.security.UnrecoverableKeyException: Get Key failed"
                ),
            },
            {
                "label": "store, alias, and key password all check out",
                "keytool": with_java,
                "runs": [keytool_ok, java_ok],
                "status": "valid",
                "fingerprint": "AA:BB:CC",
                "detail": "Store password, keyAlias, and private-key password are valid",
            },
        ]

        for case in cases:
            with self.subTest(case["label"]):
                keytool = case["keytool"]
                with (
                    patch.object(
                        frk,
                        "find_keytool",
                        return_value=None if keytool is None else str(keytool),
                    ),
                    patch.object(frk.subprocess, "run", side_effect=case["runs"]) as run,
                ):
                    result = frk.probe_keystore_file(store, dict(self.PROBE_PROPERTIES))

                self.assertEqual(case["status"], result["status"])
                self.assertEqual(case["fingerprint"], result["fingerprint"])
                self.assertEqual(case["detail"], result["detail"])
                self.assertEqual(len(case["runs"]), run.call_count)
                # Security invariant of the machine API: no probe result, on any
                # branch, may carry a password value out of this function.
                encoded = json.dumps(result)
                self.assertNotIn("store-secret-value", encoded)
                self.assertNotIn("key-secret-value", encoded)

    def test_find_keytool_prefers_java_home_and_probes_each_candidate_with_help(self):
        # Every non-fake candidate (including a real Android Studio JDK on the
        # developer's machine) is forced to fail the -help probe, so the ladder
        # order is what the assertions actually observe.
        java_home = self.make_jdk_bin("java-home").parent.parent
        java_home_keytool = (java_home / "bin" / "keytool").resolve()
        path_keytool = self.make_jdk_bin("path-jdk").resolve()

        def probe(command, **kwargs):
            accepted = {str(java_home_keytool), str(path_keytool)}
            return types.SimpleNamespace(returncode=0 if command[0] in accepted else 1)

        with (
            patch.dict(os.environ, {"JAVA_HOME": str(java_home)}),
            patch.object(frk.shutil, "which", return_value=str(path_keytool)),
            patch.object(frk.subprocess, "run", side_effect=probe) as run,
        ):
            found = frk.find_keytool()

        self.assertEqual(str(java_home_keytool), found)
        # JAVA_HOME is probed first and wins, so the PATH candidate is never reached.
        self.assertEqual(1, run.call_count)
        self.assertEqual([str(java_home_keytool), "-help"], run.call_args_list[0].args[0])

    def test_find_keytool_skips_non_executable_candidates_and_falls_back_to_path(self):
        java_home = self.make_jdk_bin("unusable-home").parent.parent
        (java_home / "bin" / "keytool").chmod(0o600)
        path_keytool = self.make_jdk_bin("fallback-jdk").resolve()

        def probe(command, **kwargs):
            return types.SimpleNamespace(returncode=0 if command[0] == str(path_keytool) else 1)

        with (
            patch.dict(os.environ, {"JAVA_HOME": str(java_home)}),
            patch.object(frk.shutil, "which", return_value=str(path_keytool)),
            patch.object(frk.subprocess, "run", side_effect=probe) as run,
        ):
            found = frk.find_keytool()

        self.assertEqual(str(path_keytool), found)
        probed = [call.args[0][0] for call in run.call_args_list]
        self.assertNotIn(str((java_home / "bin" / "keytool").resolve()), probed)
        self.assertEqual(str(path_keytool), probed[-1])

    def test_find_keytool_returns_none_when_no_candidate_answers_help(self):
        with (
            patch.dict(os.environ, {"JAVA_HOME": ""}),
            patch.object(frk.shutil, "which", return_value=None),
            patch.object(
                frk.subprocess,
                "run",
                side_effect=lambda command, **kwargs: types.SimpleNamespace(returncode=1),
            ),
        ):
            self.assertIsNone(frk.find_keytool())

    # ----------------------------------------------------------------- #
    # provisioning profile decoding
    # ----------------------------------------------------------------- #
    def test_decode_provisioning_profile_reports_a_missing_security_tool(self):
        with patch.object(frk.shutil, "which", return_value=None):
            profile, error = frk.decode_provisioning_profile(self.root / "any.mobileprovision")

        self.assertIsNone(profile)
        self.assertEqual("macOS security tool is unavailable", error)

    def test_decode_provisioning_profile_reports_the_last_stderr_line_on_failure(self):
        failure = types.SimpleNamespace(
            returncode=1,
            stdout=b"",
            stderr=(
                b"security: SecPolicySetValue failed\n"
                b"security: cms: unable to read input\n"
                b"security: the final complaint\n"
            ),
        )

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", return_value=failure) as run,
        ):
            profile, error = frk.decode_provisioning_profile(self.root / "broken.mobileprovision")

        self.assertIsNone(profile)
        # detail[-1]: the LAST non-empty stderr line, not the first.
        self.assertEqual("security: the final complaint", error)
        self.assertEqual(
            ["/usr/bin/security", "cms", "-D", "-i", str(self.root / "broken.mobileprovision")],
            run.call_args.args[0],
        )

    def test_decode_provisioning_profile_falls_back_when_stderr_is_blank(self):
        failure = types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"   \n  \n")

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", return_value=failure),
        ):
            profile, error = frk.decode_provisioning_profile(self.root / "silent.mobileprovision")

        self.assertIsNone(profile)
        self.assertEqual("the profile could not be decoded", error)

    def test_decode_provisioning_profile_reports_unparseable_output(self):
        garbage = types.SimpleNamespace(returncode=0, stdout=b"not a plist at all", stderr=b"")

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", return_value=garbage),
        ):
            profile, error = frk.decode_provisioning_profile(self.root / "garbage.mobileprovision")

        self.assertIsNone(profile)
        self.assertEqual("invalid provisioning profile: Invalid file", error)

    def test_decode_provisioning_profile_discards_a_plist_that_is_not_a_mapping(self):
        listy = types.SimpleNamespace(returncode=0, stdout=frk.plistlib.dumps([1, 2]), stderr=b"")

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", return_value=listy),
        ):
            profile, error = frk.decode_provisioning_profile(self.root / "listy.mobileprovision")

        # A well-formed plist that is not a dict yields (None, None): no error
        # string is built. That is not a defect — provisioning_profile_record is
        # the only caller and supplies "The provisioning profile is unreadable".
        self.assertIsNone(profile)
        self.assertIsNone(error)

    def test_provisioning_profile_record_supplies_the_detail_decoding_left_empty(self):
        profile_path = self.root / "listy.mobileprovision"
        profile_path.touch()

        with patch.object(frk, "decode_provisioning_profile", return_value=(None, None)):
            record = frk.provisioning_profile_record(
                profile_path, "org.example.app", "ABCDE12345", []
            )

        self.assertEqual("invalid", record["status"])
        self.assertFalse(record["ready"])
        self.assertEqual("The provisioning profile is unreadable", record["detail"])

    # ----------------------------------------------------------------- #
    # onboarding platform selection
    # ----------------------------------------------------------------- #
    @staticmethod
    def platform_facts(android=True, ios=True):
        return {"android_real": android, "ios_real": ios}

    def test_detected_platforms_follow_the_identifiers_the_app_really_has(self):
        self.assertEqual(
            ["android", "ios"], frk.select_platforms(self.platform_facts(), None)
        )
        self.assertEqual(
            ["android"], frk.select_platforms(self.platform_facts(ios=False), None)
        )
        self.assertEqual(
            ["ios"], frk.select_platforms(self.platform_facts(android=False), None)
        )

    def test_an_explicit_platform_list_is_lowercased_trimmed_and_deduplicated(self):
        self.assertEqual(
            ["ios", "android"],
            frk.select_platforms(self.platform_facts(), " IOS , android ,ios, "),
        )

    def test_an_unknown_platform_name_is_rejected_before_anything_else(self):
        with self.assertRaises(ValueError) as raised:
            frk.select_platforms(self.platform_facts(), "android,web,fuchsia")

        self.assertEqual("unknown platform(s): web, fuchsia", str(raised.exception))

    def test_an_app_with_no_real_identifier_selects_no_platform(self):
        # A list that is empty after parsing ("," or ", ,") lands here too: there
        # is nothing to onboard either way.
        for requested in (None, ","):
            with self.subTest(requested=requested):
                with self.assertRaises(ValueError) as raised:
                    frk.select_platforms(
                        self.platform_facts(android=False, ios=False), requested
                    )

                self.assertTrue(
                    str(raised.exception).startswith(
                        "could not determine any release-ready platform."
                    )
                )

    def test_requesting_a_platform_the_app_cannot_sign_is_rejected_ios_first(self):
        with self.assertRaises(ValueError) as raised:
            frk.select_platforms(
                self.platform_facts(android=False, ios=False), "android,ios"
            )

        # iOS is checked first, so a doubly-unconfigured app names iOS even when
        # Android was requested first.
        self.assertEqual(
            "iOS requested but its bundle id or 10-character DEVELOPMENT_TEAM is "
            "missing, invalid, or placeholder",
            str(raised.exception),
        )

        with self.assertRaises(ValueError) as raised:
            frk.select_platforms(self.platform_facts(android=False), "android")

        self.assertEqual(
            "Android requested but its applicationId is missing, invalid, or still com.example.*",
            str(raised.exception),
        )

    # ----------------------------------------------------------------- #
    # status credentials.env listing
    # ----------------------------------------------------------------- #
    def test_status_lists_credentials_env_keys_exactly_as_written(self):
        # A duplicate key is what you get by uncommenting a template line for a
        # key that is already set — the case the listing exists to expose. The
        # other three lines pin the skip rules: comment, blank, and no `=`.
        frk.ensure_credential_vault()
        (self.release_home / "credentials.env").write_text(
            "# Flutter Release Kit shared credentials.\n"
            "SUPPLY_JSON_KEY=play/first.json\n"
            "\n"
            "NOT_AN_ASSIGNMENT\n"
            "SUPPLY_JSON_KEY=play/second.json\n"
            "  OTHER = spaced  \n"
        )
        with patch.object(frk.shutil, "which", return_value=None):
            self.assertEqual(0, frk.cmd_status(argparse.Namespace()))

        self.assertIn(
            "  ok    credentials.env — sets SUPPLY_JSON_KEY, SUPPLY_JSON_KEY, OTHER\n",
            self.stdout.getvalue(),
        )
        # The effective mapping still collapses the repeat, last write winning.
        self.assertEqual(
            {"SUPPLY_JSON_KEY": "play/second.json", "OTHER": "spaced"},
            frk.env_values(self.release_home / "credentials.env"),
        )

    def test_status_reports_a_credentials_env_with_only_comments_as_inactive(self):
        frk.ensure_credential_vault()
        (self.release_home / "credentials.env").write_text("# ASC_KEY_ID=XXXX\n\n")
        with patch.object(frk.shutil, "which", return_value=None):
            self.assertEqual(0, frk.cmd_status(argparse.Namespace()))

        self.assertIn(
            "  warn  credentials.env has no active entries", self.stdout.getvalue()
        )

    # ----------------------------------------------------------------- #
    # status signing identities
    # ----------------------------------------------------------------- #
    def run_status_with_identities(self, find_identity_stdout):
        frk.ensure_credential_vault()
        (self.release_home / "credentials.env").write_text("ASC_KEY_ID=ABCDEFGHIJ\n")
        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(
                frk.subprocess, "run",
                return_value=types.SimpleNamespace(stdout=find_identity_stdout),
            ),
        ):
            self.assertEqual(0, frk.cmd_status(argparse.Namespace()))
        head = "Signing identities (account-level, shared by all iOS apps)"
        tail = self.stdout.getvalue().split(head, 1)[1]
        return [line.strip() for line in tail.splitlines() if line.strip()]

    def test_status_lists_every_keychain_name_containing_distribution(self):
        # `frk status` filters on the substring "Distribution"; the cached
        # distribution_identities() helper filters on "Apple Distribution" or
        # "iPhone Distribution". `Mac App Distribution` is a real macOS identity
        # that only the first of those two accepts, so the helper cannot stand in
        # for this listing without dropping it from what the user sees.
        lines = self.run_status_with_identities(
            f'  1) {"A" * 40} "Apple Distribution: Example Ltd (ABCDE12345)"\n'
            f'  2) {"B" * 40} "Mac App Distribution: Example Ltd (ABCDE12345)"\n'
            f'  3) {"C" * 40} "Developer ID Application: Example Ltd (ABCDE12345)"\n'
        )

        self.assertEqual(
            [
                "ok    Apple Distribution: Example Ltd (ABCDE12345)",
                "ok    Mac App Distribution: Example Ltd (ABCDE12345)",
            ],
            lines,
        )

    def test_status_reports_a_keychain_without_any_distribution_identity(self):
        lines = self.run_status_with_identities(
            f'  1) {"C" * 40} "Apple Development: Example Ltd (ABCDE12345)"\n'
        )

        self.assertEqual(
            ["FAIL  no Apple Distribution identity — run `fastlane ios setup_signing` "
             "in any iOS app"],
            lines,
        )

    # ----------------------------------------------------------------- #
    # api store-versions
    # ----------------------------------------------------------------- #
    # The lane's own report, reproduced from fastlane/Fastfile's contract. Only
    # the marker line matters; everything around it is chatter on purpose.
    LANE_ANDROID_OK = {
        "status": "ok",
        "detail": "Google Play's highest known version code is 38 and the configured 'internal' track is at 38.",
        "track": "internal",
        "latestVersionCode": 38,
        "latestVersionName": "2.0.9",
        "tracks": [
            {"track": "internal", "versionCode": 38, "versionName": "2.0.9"},
            {"track": "beta", "versionCode": 36, "versionName": "2.0.7"},
        ],
    }
    LANE_IOS_OK = {
        "status": "ok",
        "detail": "TestFlight's newest upload is build 41 of version 2.1.0, state PROCESSING; the latest App Store release is 2.0.8.",
        "latestAppStoreVersion": "2.0.8",
        "builds": [
            {"version": "2.1.0", "build": 41, "state": "PROCESSING"},
            {"version": "2.0.9", "build": 40, "state": "VALID"},
        ],
    }

    def store_versions_app(self, name="example_app"):
        app = self.make_android_app(name)
        frk.register_project(app)
        return app

    def marker_line(self, report, prefix="[09:41:07]: "):
        body = json.dumps(report, separators=(",", ":"), ensure_ascii=False)
        return f"{prefix}{frk.STORE_VERSIONS_MARKER} {body}"

    def lane_output(self, report, **kwargs):
        """A realistic fastlane run: chatter, the marker, then the run summary."""
        return (
            "[09:41:05]: Driving the lane 'store_versions'\n"
            "[09:41:06]: Reading Google Play\n"
            f"{self.marker_line(report, **kwargs)}\n"
            "+------+------------------+-------------+\n"
            "[09:41:08]: fastlane.tools finished successfully\n"
        )

    def lane_report(self, android=None, ios=None, **overrides):
        report = {
            "project": "whatever-the-lane-says",
            "checkedAt": "2026-08-08T09:41:07.412Z",
            "android": self.LANE_ANDROID_OK if android is None else android,
            "ios": self.LANE_IOS_OK if ios is None else ios,
        }
        report.update(overrides)
        return report

    def sole_document(self):
        lines = self.stdout.getvalue().splitlines()
        self.assertEqual(1, len(lines))
        return json.loads(lines[0])

    def run_store_versions(self, output, code=0, app_dir="example_app", installed=True):
        self.store_versions_calls = []

        def capture(app, lane, *, timeout):
            self.store_versions_calls.append({"app": app, "lane": lane, "timeout": timeout})
            if isinstance(output, BaseException):
                raise output
            return code, output

        with (
            patch.object(frk, "fastlane_installed", return_value=installed),
            patch.object(frk, "capture_fastlane", side_effect=capture),
        ):
            status = frk.cmd_api_store_versions(argparse.Namespace(app_dir=app_dir))
        return status

    def assertStoreVersionsError(self, status, code):
        self.assertEqual(1, status)
        payload = self.sole_document()
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(payload))
        self.assertEqual(code, payload["error"]["code"])
        # Withholding the platform objects is the point: a client can never read
        # "the store holds nothing" out of a run that never reached the store.
        self.assertNotIn("android", payload)
        self.assertNotIn("ios", payload)
        return payload

    def test_store_versions_reports_both_stores_as_one_document(self):
        self.store_versions_app()

        status = self.run_store_versions(self.lane_output(self.lane_report()))

        self.assertEqual(0, status)
        self.assertEqual(
            {
                "protocolVersion": 1,
                "cliVersion": frk.VERSION,
                # Not "whatever-the-lane-says": the name is this side's fact.
                "project": "example_app",
                "checkedAt": "2026-08-08T09:41:07.412Z",
                "android": {
                    "status": "ok",
                    "detail": "Google Play's highest known version code is 38 and the "
                              "configured 'internal' track is at 38.",
                    "track": "internal",
                    "latestVersionCode": 38,
                    "latestVersionName": "2.0.9",
                    "tracks": [
                        {"track": "internal", "versionCode": 38, "versionName": "2.0.9"},
                        {"track": "beta", "versionCode": 36, "versionName": "2.0.7"},
                    ],
                },
                "ios": {
                    "status": "ok",
                    "detail": "TestFlight's newest upload is build 41 of version 2.1.0, state "
                              "PROCESSING; the latest App Store release is 2.0.8.",
                    "latestAppStoreVersion": "2.0.8",
                    "builds": [
                        {"version": "2.1.0", "build": 41, "state": "PROCESSING"},
                        {"version": "2.0.9", "build": 40, "state": "VALID"},
                    ],
                },
            },
            self.sole_document(),
        )
        # Read-only, and the lane is asked plainly: no options, no version
        # arguments, nothing that could make the child change a store.
        self.assertEqual([["store_versions"]], [call["lane"] for call in self.store_versions_calls])

    def test_store_versions_reports_an_android_only_project(self):
        self.store_versions_app()
        unconfigured = {
            "status": "unconfigured",
            "detail": "This project does not list ios in `platforms` in fastlane/release_kit.yml "
                      "(it lists: android).",
            "latestAppStoreVersion": None,
            "builds": [],
        }

        status = self.run_store_versions(self.lane_output(self.lane_report(ios=unconfigured)))

        self.assertEqual(0, status)
        payload = self.sole_document()
        self.assertEqual("ok", payload["android"]["status"])
        self.assertEqual(unconfigured, payload["ios"])

    def test_store_versions_reports_an_ios_only_project(self):
        self.store_versions_app()
        unconfigured = {
            "status": "unconfigured",
            "detail": "This project does not list android in `platforms` in "
                      "fastlane/release_kit.yml (it lists: ios).",
            "track": None,
            "latestVersionCode": None,
            "latestVersionName": None,
            "tracks": [],
        }

        status = self.run_store_versions(self.lane_output(self.lane_report(android=unconfigured)))

        self.assertEqual(0, status)
        payload = self.sole_document()
        self.assertEqual(unconfigured, payload["android"])
        self.assertEqual("ok", payload["ios"]["status"])

    def test_store_versions_reports_a_project_configured_for_neither_platform(self):
        self.store_versions_app()
        detail = (
            "fastlane/release_kit.yml could not be read, so {} is not configured: "
            "fastlane/release_kit.yml: `platforms` must list at least one of android, ios"
        )
        report = self.lane_report(
            android={
                "status": "unconfigured",
                "detail": detail.format("android"),
                "track": None,
                "latestVersionCode": None,
                "latestVersionName": None,
                "tracks": [],
            },
            ios={
                "status": "unconfigured",
                "detail": detail.format("ios"),
                "latestAppStoreVersion": None,
                "builds": [],
            },
        )

        status = self.run_store_versions(self.lane_output(report))

        self.assertEqual(0, status)
        payload = self.sole_document()
        self.assertEqual(["unconfigured", "unconfigured"],
                         [payload["android"]["status"], payload["ios"]["status"]])
        self.assertEqual(detail.format("android"), payload["android"]["detail"])
        self.assertEqual(detail.format("ios"), payload["ios"]["detail"])

    def test_store_versions_reports_missing_credentials_as_a_status_not_an_absence(self):
        self.store_versions_app()
        report = self.lane_report(
            android={
                "status": "no_credentials",
                "detail": "No Google Play service-account key is available, so Play was not "
                          "contacted; run `fastlane android check_credentials` for the setup steps.",
                "track": "internal",
                "latestVersionCode": None,
                "latestVersionName": None,
                "tracks": [],
            },
            ios={
                "status": "no_credentials",
                "detail": "No App Store Connect API key is available, so App Store Connect was "
                          "not contacted; run `fastlane ios check_credentials` for the setup steps.",
                "latestAppStoreVersion": None,
                "builds": [],
            },
        )

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        payload = self.sole_document()
        # "We never asked" must not read like "the store holds nothing": the
        # status says which one it is and the numbers stay null either way.
        self.assertEqual("no_credentials", payload["android"]["status"])
        self.assertEqual("no_credentials", payload["ios"]["status"])
        self.assertIsNone(payload["android"]["latestVersionCode"])
        self.assertIsNone(payload["ios"]["latestAppStoreVersion"])
        # Local knowledge survives a store that was never contacted.
        self.assertEqual("internal", payload["android"]["track"])

    def test_store_versions_reports_an_unreachable_store_as_unavailable(self):
        self.store_versions_app()
        report = self.lane_report(
            android={
                "status": "unavailable",
                "detail": "Google Play did not answer within 60 seconds.",
                "track": "internal",
                "latestVersionCode": None,
                "latestVersionName": None,
                "tracks": [],
            },
            ios={
                "status": "unavailable",
                "detail": "Could not read App Store Connect: Failed to open TCP connection to "
                          "api.appstoreconnect.apple.com:443",
                "latestAppStoreVersion": None,
                "builds": [],
            },
        )

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        payload = self.sole_document()
        self.assertEqual("unavailable", payload["android"]["status"])
        self.assertEqual("unavailable", payload["ios"]["status"])
        self.assertIn("did not answer within 60 seconds", payload["android"]["detail"])
        self.assertIn("api.appstoreconnect.apple.com", payload["ios"]["detail"])

    def test_store_versions_reports_an_empty_store_with_nulls_not_zeros(self):
        self.store_versions_app()
        report = self.lane_report(
            android={
                "status": "ok",
                "detail": "Google Play holds no version code for this app yet, so any version "
                          "code is free.",
                "track": "internal",
                "latestVersionCode": None,
                "latestVersionName": None,
                "tracks": [],
            },
            ios={
                "status": "ok",
                "detail": "TestFlight has no builds for this app yet; nothing has been released "
                          "on the App Store yet.",
                "latestAppStoreVersion": None,
                "builds": [],
            },
        )

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        payload = self.sole_document()
        self.assertIsNone(payload["android"]["latestVersionCode"])
        self.assertIsNone(payload["android"]["latestVersionName"])
        self.assertIsNone(payload["ios"]["latestAppStoreVersion"])
        self.assertEqual([], payload["android"]["tracks"])
        self.assertEqual([], payload["ios"]["builds"])

    def test_store_versions_never_suggests_a_next_version(self):
        # "Version numbers are never auto-incremented" is a product invariant.
        # This command reports facts; the client proposes and the user clicks.
        # A lane that starts emitting a suggestion must not reach the wire.
        self.store_versions_app()
        report = self.lane_report()
        report["android"] = dict(report["android"], nextVersionCode=39, suggestedVersionName="2.1.0")
        report["ios"] = dict(report["ios"], recommendedBuild=42)
        report["nextBuildNumber"] = 39

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        document = self.stdout.getvalue()
        self.assertIsNone(
            re.search(r'"[^"]*(next|suggest|recommend|increment)[^"]*"\s*:', document, re.I),
            document,
        )
        payload = self.sole_document()
        self.assertEqual({"protocolVersion", "cliVersion", "project", "checkedAt", "android", "ios"},
                         set(payload))

    def test_store_versions_cannot_pass_through_credential_material(self):
        # Defence in depth: the lane redacts its own foreign text, and this side
        # redacts again, because the document is network-derived and gets logged.
        self.store_versions_app()
        report = self.lane_report(
            android={
                "status": "unavailable",
                "detail": "Could not read Google Play: denied for "
                          "release-bot@example-123.iam.gserviceaccount.com using "
                          "/Users/someone/.flutter-release/play/service-account.json",
                "track": "internal",
                "latestVersionCode": None,
                "latestVersionName": None,
                "tracks": [],
            },
            ios={
                "status": "unavailable",
                "detail": "Could not read App Store Connect: key A1B2C3D4E5 issuer "
                          "69a6de70-1234-47e3-e053-5b8c7c11a4d1 token "
                          "eyJhbGciOiJFUzI1NiIsImtpZCI6IkExQjJDM0Q0RTUifQ",
                "latestAppStoreVersion": None,
                "builds": [],
            },
        )

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        document = self.stdout.getvalue()
        for secret in (
            "release-bot@example-123.iam.gserviceaccount.com",
            "/Users/someone/.flutter-release/play/service-account.json",
            ".flutter-release",
            "A1B2C3D4E5",
            "69a6de70-1234-47e3-e053-5b8c7c11a4d1",
            "eyJhbGciOiJFUzI1NiIsImtpZCI6IkExQjJDM0Q0RTUifQ",
        ):
            self.assertNotIn(secret, document)
        self.assertIn("<redacted>", self.sole_document()["android"]["detail"])

    def test_store_versions_redacts_a_private_key_header_on_a_single_line(self):
        # The detail is truncated to its first line before redaction, so a
        # BEGIN...END pattern spanning two lines can never match anything this
        # code sees. The header alone is what actually arrives.
        self.store_versions_app()
        report = self.lane_report(android=dict(
            self.LANE_ANDROID_OK,
            status="unavailable",
            detail="Could not read Google Play: -----BEGIN PRIVATE KEY----- MIIEvQIBADANBg",
        ))

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        detail = self.sole_document()["android"]["detail"]
        self.assertNotIn("BEGIN PRIVATE KEY", detail)
        self.assertNotIn("MIIEvQIBADANBg", detail)
        self.assertIn("<redacted>", detail)

    def test_store_versions_keeps_a_custom_play_track_that_holds_a_release(self):
        # Play's built-in track ids are lowercase, but closed-testing track ids
        # are whatever the user typed in the Console, and form-factor tracks
        # carry a prefix. Dropping those left a real version code out of the
        # list while the status still said "ok".
        self.store_versions_app()
        report = self.lane_report(android=dict(self.LANE_ANDROID_OK, track="QA", tracks=[
            {"track": "QA", "versionCode": 41, "versionName": "2.1.0"},
            {"track": "Closed Beta", "versionCode": 40, "versionName": None},
            {"track": "wear:production", "versionCode": 39, "versionName": None},
        ]))

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        payload = self.sole_document()
        self.assertEqual(
            ["QA", "Closed Beta", "wear:production"],
            [entry["track"] for entry in payload["android"]["tracks"]],
        )
        self.assertEqual("QA", payload["android"]["track"])

    def test_store_versions_leaves_a_hand_written_sentence_intact(self):
        # The redaction must not eat the lane's own prose. PROCESSING is ten
        # uppercase characters, exactly the shape of an App Store key id.
        self.store_versions_app()

        self.assertEqual(0, self.run_store_versions(self.lane_output(self.lane_report())))
        self.assertIn("state PROCESSING", self.sole_document()["ios"]["detail"])

    def test_store_versions_drops_every_field_it_does_not_know(self):
        self.store_versions_app()
        report = self.lane_report()
        report["serviceAccountEmail"] = "bot@example.com"
        report["android"] = dict(report["android"], keyPath="/vault/play/service-account.json")
        report["ios"] = dict(report["ios"], issuerId="69a6de70-1234-47e3-e053-5b8c7c11a4d1")
        report["ios"]["builds"] = [dict(report["ios"]["builds"][0], uploadedBy="bot@example.com")]

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        payload = self.sole_document()
        self.assertEqual(
            {"status", "detail", "track", "latestVersionCode", "latestVersionName", "tracks"},
            set(payload["android"]),
        )
        self.assertEqual({"status", "detail", "latestAppStoreVersion", "builds"}, set(payload["ios"]))
        self.assertEqual({"version", "build", "state"}, set(payload["ios"]["builds"][0]))
        self.assertNotIn("bot@example.com", self.stdout.getvalue())

    def test_store_versions_refuses_a_string_where_a_number_belongs(self):
        self.store_versions_app()
        report = self.lane_report(
            android=dict(self.LANE_ANDROID_OK, latestVersionCode="38", tracks=[
                {"track": "internal", "versionCode": "38", "versionName": "2.0.9"},
            ]),
            ios=dict(self.LANE_IOS_OK, builds=[{"version": "2.1.0", "build": "41", "state": "VALID"}]),
        )

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        payload = self.sole_document()
        self.assertIsNone(payload["android"]["latestVersionCode"])
        # A track entry without a usable code says nothing at all, so it goes.
        self.assertEqual([], payload["android"]["tracks"])
        self.assertIsNone(payload["ios"]["builds"][0]["build"])

    def test_store_versions_reports_a_zero_version_code_as_unknown(self):
        self.store_versions_app()
        report = self.lane_report(android=dict(self.LANE_ANDROID_OK, latestVersionCode=0, tracks=[]))

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        self.assertIsNone(self.sole_document()["android"]["latestVersionCode"])

    def test_store_versions_treats_an_unknown_status_as_unavailable(self):
        # Fail closed. "ok" is the one status that lets a client trust a number.
        self.store_versions_app()
        report = self.lane_report(
            android=dict(self.LANE_ANDROID_OK, status="fine"),
            ios=dict(self.LANE_IOS_OK, status=True),
        )

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        payload = self.sole_document()
        self.assertEqual("unavailable", payload["android"]["status"])
        self.assertEqual("unavailable", payload["ios"]["status"])

    def test_store_versions_always_carries_status_and_detail(self):
        self.store_versions_app()

        self.assertEqual(0, self.run_store_versions(self.lane_output({})))
        payload = self.sole_document()
        for platform in ("android", "ios"):
            with self.subTest(platform):
                self.assertEqual("unavailable", payload[platform]["status"])
                self.assertTrue(payload[platform]["detail"].strip())
        self.assertEqual([], payload["android"]["tracks"])
        self.assertEqual([], payload["ios"]["builds"])
        # An absent checkedAt is replaced with this side's moment, never dropped.
        self.assertTrue(payload["checkedAt"])

    def test_store_versions_drops_half_written_track_entries(self):
        self.store_versions_app()
        report = self.lane_report(android=dict(self.LANE_ANDROID_OK, tracks=[
            {"track": "internal", "versionCode": 38, "versionName": "2.0.9"},
            {"track": "beta"},
            {"versionCode": 36},
            "production",
            {"track": "internal\n", "versionCode": 30},
            {"track": "alpha", "versionCode": 12, "versionName": "October hotfix (12)"},
        ]))

        self.assertEqual(0, self.run_store_versions(self.lane_output(report)))
        self.assertEqual(
            [
                {"track": "internal", "versionCode": 38, "versionName": "2.0.9"},
                # A display name Play cannot be parsed into a version is null,
                # never a guess and never the raw display string.
                {"track": "alpha", "versionCode": 12, "versionName": None},
            ],
            self.sole_document()["android"]["tracks"],
        )

    def test_store_versions_caps_the_build_list_the_lane_promised_to_cap(self):
        self.store_versions_app()
        builds = [{"version": "2.1.0", "build": number, "state": "VALID"} for number in range(1, 26)]

        self.assertEqual(
            0,
            self.run_store_versions(self.lane_output(self.lane_report(
                ios=dict(self.LANE_IOS_OK, builds=builds)
            ))),
        )
        reported = self.sole_document()["ios"]["builds"]
        self.assertEqual(frk.STORE_VERSIONS_MAX_BUILDS, len(reported))
        self.assertEqual(1, reported[0]["build"])

    def test_store_versions_finds_a_marker_that_is_not_the_last_line(self):
        # fastlane prefixes its own timestamp and appends a run summary after
        # the lane's output, so neither "last line" nor "line starting with {"
        # can find the report.
        self.store_versions_app()

        self.assertEqual(0, self.run_store_versions(self.lane_output(self.lane_report())))
        self.assertEqual("example_app", self.sole_document()["project"])

    def test_store_versions_uses_the_last_marker_line(self):
        self.store_versions_app()
        stale = self.lane_report(android=dict(self.LANE_ANDROID_OK, latestVersionCode=1))
        fresh = self.lane_report(android=dict(self.LANE_ANDROID_OK, latestVersionCode=99))
        output = f"{self.marker_line(stale)}\nnoise\n{self.marker_line(fresh)}\nsummary\n"

        self.assertEqual(0, self.run_store_versions(output))
        self.assertEqual(99, self.sole_document()["android"]["latestVersionCode"])

    def test_store_versions_discards_every_line_that_is_not_the_marker(self):
        self.store_versions_app()
        output = (
            "[09:41:05]: SUPPLY_JSON_KEY=/Users/someone/.flutter-release/play/key.json\n"
            "[09:41:06]: ASC_ISSUER_ID=69a6de70-1234-47e3-e053-5b8c7c11a4d1\n"
            f"{self.marker_line(self.lane_report())}\n"
            "[09:41:08]: -----BEGIN PRIVATE KEY-----\n"
        )

        self.assertEqual(0, self.run_store_versions(output))
        document = self.stdout.getvalue()
        for chatter in ("SUPPLY_JSON_KEY", "ASC_ISSUER_ID", "BEGIN PRIVATE KEY", "key.json"):
            self.assertNotIn(chatter, document)

    def test_store_versions_strips_colour_around_the_marker(self):
        self.store_versions_app()
        line = self.marker_line(self.lane_report(), prefix="\x1b[32m[09:41:07]: ")

        self.assertEqual(0, self.run_store_versions(f"{line}\x1b[0m\n"))
        self.assertEqual(38, self.sole_document()["android"]["latestVersionCode"])

    def test_store_versions_accepts_a_report_from_a_lane_that_exited_non_zero(self):
        # The lane never raises and always prints the marker, each platform
        # carrying its own status. A fastlane wrapper that exits non-zero after
        # a complete answer must not turn that answer into "could not check".
        self.store_versions_app()

        self.assertEqual(0, self.run_store_versions(self.lane_output(self.lane_report()), code=1))
        self.assertEqual(38, self.sole_document()["android"]["latestVersionCode"])

    def test_store_versions_reports_a_lane_that_printed_no_marker(self):
        self.store_versions_app()

        status = self.run_store_versions("Could not find lane 'store_versions'\n", code=1)

        payload = self.assertStoreVersionsError(status, "store_query_failed")
        self.assertIn("status 1", payload["error"]["message"])
        # The child's output is never quoted back: unbounded and unredacted.
        self.assertNotIn("Could not find lane", payload["error"]["message"])

    def test_store_versions_reports_an_unparseable_marker_line(self):
        self.store_versions_app()

        status = self.run_store_versions(f"{frk.STORE_VERSIONS_MARKER} {{not json\n")

        self.assertStoreVersionsError(status, "store_report_unreadable")

    def test_store_versions_reports_a_marker_line_that_is_not_an_object(self):
        self.store_versions_app()

        status = self.run_store_versions(f"{frk.STORE_VERSIONS_MARKER} [38, 41]\n")

        self.assertStoreVersionsError(status, "store_report_unreadable")

    def test_store_versions_reports_an_unknown_project(self):
        self.store_versions_app()

        status = self.run_store_versions("", app_dir="not_a_project")

        self.assertStoreVersionsError(status, "project_not_found")
        self.assertEqual([], self.store_versions_calls)

    def test_store_versions_reports_a_project_directory_that_is_gone(self):
        app = self.store_versions_app()
        shutil.rmtree(app)

        status = self.run_store_versions("")

        self.assertStoreVersionsError(status, "project_unavailable")
        self.assertEqual([], self.store_versions_calls)

    def test_store_versions_reports_a_project_that_was_never_onboarded(self):
        app = self.store_versions_app()
        (app / "fastlane" / "Fastfile").write_text("# importer removed\n")

        status = self.run_store_versions("")

        self.assertStoreVersionsError(status, "project_not_onboarded")
        self.assertEqual([], self.store_versions_calls)

    def test_store_versions_reports_a_missing_fastlane(self):
        self.store_versions_app()

        status = self.run_store_versions("", installed=False)

        payload = self.assertStoreVersionsError(status, "fastlane_unavailable")
        self.assertIn("brew install fastlane", payload["error"]["message"])
        self.assertEqual([], self.store_versions_calls)

    def test_store_versions_reports_a_timeout_without_inventing_a_version(self):
        self.store_versions_app()

        status = self.run_store_versions(subprocess.TimeoutExpired("fastlane", 300))

        payload = self.assertStoreVersionsError(status, "store_query_timed_out")
        self.assertIn(str(frk.STORE_VERSIONS_TIMEOUT_SECONDS), payload["error"]["message"])

    def test_store_versions_timeout_message_describes_the_deadline_that_exists(self):
        # `communicate(timeout=...)` is a total wall-clock deadline, not an
        # inactivity timer. Telling the user the lane "made no progress" sends
        # them looking for a hang that never happened: a cold bundler plus two
        # slow store round-trips can make continuous progress for 305 seconds
        # and still be stopped here.
        self.store_versions_app()

        status = self.run_store_versions(subprocess.TimeoutExpired("fastlane", 300))

        message = self.assertStoreVersionsError(status, "store_query_timed_out")["error"]["message"]
        self.assertIn("did not finish within 300 seconds", message)
        self.assertNotIn("no progress", message)

    def test_store_versions_reports_a_fastlane_that_will_not_start(self):
        self.store_versions_app()

        status = self.run_store_versions(OSError(13, "Permission denied"))

        self.assertStoreVersionsError(status, "fastlane_unavailable")

    def test_store_versions_timeout_leaves_room_for_two_slow_stores(self):
        # The lane budgets 60s per store and queries two of them, behind ruby
        # and fastlane start-up. A CLI ceiling near that budget would report a
        # slow-but-working store as unreachable, which is the confusion this
        # whole command exists to remove.
        self.assertGreaterEqual(frk.STORE_VERSIONS_TIMEOUT_SECONDS, 180)
        self.store_versions_app()

        self.assertEqual(0, self.run_store_versions(self.lane_output(self.lane_report())))

        self.assertEqual(
            frk.STORE_VERSIONS_TIMEOUT_SECONDS, self.store_versions_calls[0]["timeout"]
        )

    def test_store_versions_reports_a_corrupt_registry_as_one_document(self):
        self.write_registry('{"version": 1, "projects": [')

        with patch.object(frk.sys, "argv", ["frk", "api", "store-versions", "example_app"]):
            status = frk.main()

        self.assertEqual(1, status)
        payload = self.sole_document()
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(payload))
        self.assertEqual("command_failed", payload["error"]["code"])
        self.assertIn("could not read registry", self.stderr.getvalue())

    def test_store_versions_changes_nothing_in_the_project(self):
        app = self.store_versions_app()
        before = {
            path.relative_to(app).as_posix(): path.read_bytes()
            for path in sorted(app.rglob("*")) if path.is_file()
        }

        self.assertEqual(0, self.run_store_versions(self.lane_output(self.lane_report())))

        after = {
            path.relative_to(app).as_posix(): path.read_bytes()
            for path in sorted(app.rglob("*")) if path.is_file()
        }
        self.assertEqual(before, after)

    def test_capture_fastlane_keeps_the_child_output_off_stdout(self):
        app = self.root / "captured"
        app.mkdir()
        child = FakeChild(output="chatter\n", returncode=3)

        with patch.object(frk.subprocess, "Popen", return_value=child) as popen:
            code, output = frk.capture_fastlane(app, ["store_versions"], timeout=300)

        self.assertEqual((3, "chatter\n"), (code, output))
        # A document command writes exactly one JSON object; fastlane chatter on
        # the same stream would break every client parsing it.
        self.assertEqual("", self.stdout.getvalue())
        self.assertEqual([300], child.timeouts)
        self.assertEqual(["fastlane", "store_versions"], popen.call_args.args[0])
        keywords = popen.call_args.kwargs
        self.assertEqual(app, keywords["cwd"])
        self.assertTrue(keywords["start_new_session"])
        self.assertEqual(subprocess.PIPE, keywords["stdout"])
        self.assertEqual(subprocess.STDOUT, keywords["stderr"])
        self.assertEqual("1", keywords["env"]["FASTLANE_DISABLE_COLORS"])

    def test_capture_fastlane_kills_the_whole_group_when_the_lane_hangs(self):
        child = FakeChild(hangs=True)
        killed = []

        def killpg(pid, number):
            killed.append((pid, number))
            child.hangs = False

        with (
            patch.object(frk.subprocess, "Popen", return_value=child),
            patch.object(frk.os, "killpg", side_effect=killpg),
        ):
            with self.assertRaises(subprocess.TimeoutExpired):
                frk.capture_fastlane(self.root, ["store_versions"], timeout=1)

        # SIGTERM to the group, not the pid: fastlane's ruby child would
        # otherwise keep the store connection open behind an answered command.
        self.assertEqual([(child.pid, frk.signal.SIGTERM), (child.pid, frk.signal.SIGKILL)], killed)

    def test_capture_fastlane_escalates_to_sigkill_when_sigterm_is_ignored(self):
        child = FakeChild(hangs=True)
        killed = []

        def killpg(pid, number):
            killed.append((pid, number))
            if number == frk.signal.SIGKILL:
                child.hangs = False

        with (
            patch.object(frk.subprocess, "Popen", return_value=child),
            patch.object(frk.os, "killpg", side_effect=killpg),
        ):
            with self.assertRaises(subprocess.TimeoutExpired):
                frk.capture_fastlane(self.root, ["store_versions"], timeout=1)

        self.assertEqual(
            [(child.pid, frk.signal.SIGTERM), (child.pid, frk.signal.SIGKILL)], killed
        )

    def test_cancellation_during_spawn_is_remembered_and_handlers_are_restored(self):
        child = FakeChild()
        previous = {number: frk.signal.getsignal(number) for number in (frk.signal.SIGTERM, frk.signal.SIGINT)}

        def spawn(*args, **kwargs):
            frk.signal.getsignal(frk.signal.SIGTERM)(frk.signal.SIGTERM, None)
            return child

        with patch.object(frk.subprocess, "Popen", side_effect=spawn), patch.object(frk.os, "killpg") as killpg:
            with self.assertRaises(frk.ProcessCancelled) as cancelled:
                frk.capture_fastlane(self.root, ["store_versions"], timeout=300)
        self.assertEqual(143, cancelled.exception.exit_code)
        self.assertTrue(child.finished)
        self.assertEqual([frk.signal.SIGTERM, frk.signal.SIGKILL], [call.args[1] for call in killpg.call_args_list])
        for number, handler in previous.items():
            self.assertEqual(handler, frk.signal.getsignal(number))

    def test_repeated_cancellation_cannot_interrupt_cleanup(self):
        child = FakeChild()
        original = child.communicate

        def communicate(timeout=None):
            handler = frk.signal.getsignal(frk.signal.SIGTERM)
            handler(frk.signal.SIGTERM, None)
            handler(frk.signal.SIGTERM, None)
            return original(timeout)

        child.communicate = communicate
        with patch.object(frk.subprocess, "Popen", return_value=child), patch.object(frk.os, "killpg"):
            with self.assertRaises(frk.ProcessCancelled):
                frk.capture_fastlane(self.root, ["store_versions"], timeout=300)
        self.assertTrue(child.finished)
        self.assertEqual([frk.PROCESS_TERMINATION_GRACE_SECONDS], child.timeouts)

    def test_launch_failure_restores_both_signal_handlers(self):
        previous = {number: frk.signal.getsignal(number) for number in (frk.signal.SIGTERM, frk.signal.SIGINT)}
        with patch.object(frk.subprocess, "Popen", side_effect=OSError("could not launch")):
            with self.assertRaises(OSError):
                frk.capture_fastlane(self.root, ["store_versions"], timeout=300)
        for number, handler in previous.items():
            self.assertEqual(handler, frk.signal.getsignal(number))

    def test_process_group_is_signalled_even_after_its_leader_was_reaped(self):
        child = FakeChild()
        child.finished = True
        with patch.object(frk.os, "killpg") as killpg:
            frk.signal_process_group(child, frk.signal.SIGTERM)
        killpg.assert_called_once_with(child.pid, frk.signal.SIGTERM)

    def test_stream_cancellation_is_not_success_when_the_child_exits_zero(self):
        started = self.spy_on_popen()
        args = self.api_run_args("status")
        command = [sys.executable, "-c", "print('ready', flush=True)"]
        emit = frk.api_emit

        def cancel_after_log(kind, **payload):
            emit(kind, **payload)
            if kind == "log":
                self.assertEqual(0, started[0].wait(timeout=3))
                frk.signal.getsignal(frk.signal.SIGTERM)(frk.signal.SIGTERM, None)

        with patch.object(frk, "api_action_command", return_value=command), patch.object(frk, "api_emit", cancel_after_log):
            self.assertEqual(143, frk.cmd_api_run(args))
        events = [json.loads(line) for line in self.stdout.getvalue().splitlines()]
        self.assertEqual(["started", "log", "finished"], [event["type"] for event in events])
        self.assertFalse(events[-1]["success"])
        self.assertEqual(143, events[-1]["exitCode"])

    def cancellation_worker(self):
        """A local fake Fastlane and helper; never runs a build or contacts a store."""
        directory = self.root / "fake-tools"
        directory.mkdir()
        worker = directory / "fastlane"
        worker.write_text("#!" + sys.executable + "\n" + r"""
import os, signal, subprocess, sys, time
from pathlib import Path
leaf = "import os, signal, time\nfrom pathlib import Path\nif os.environ.get('FRK_TEST_RESIST') == '1':\n    signal.signal(signal.SIGTERM, signal.SIG_IGN)\nPath(os.environ['FRK_TEST_LEAF']).write_text(str(os.getpid()))\ntime.sleep(60)\n"
if os.environ.get('FRK_TEST_RESIST') == '1':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
subprocess.Popen([sys.executable, '-c', leaf])
Path(os.environ['FRK_TEST_LEADER']).write_text(str(os.getpid()))
print('fixture diagnostic, not a store report', flush=True)
if os.environ.get('FRK_TEST_LEADER_EXITS') != '1':
    time.sleep(60)
""", encoding="utf-8")
        worker.chmod(0o755)
        leader, leaf = self.root / "leader.pid", self.root / "leaf.pid"
        environment = {
            **os.environ, "PATH": str(directory) + os.pathsep + os.environ.get("PATH", ""),
            "FRK_TEST_LEADER": str(leader), "FRK_TEST_LEAF": str(leaf),
        }

        def cleanup():
            # Kill only fixture processes that this test created, even on assertion failure.
            for file in (leaf, leader):
                if file.is_file():
                    try:
                        os.kill(int(file.read_text()), frk.signal.SIGKILL)
                    except ProcessLookupError:
                        pass
        self.addCleanup(cleanup)
        return worker, environment, leader, leaf

    def wait_for_fixture(self, process, *paths):
        deadline = time.monotonic() + 10
        while not all(path.is_file() and path.read_text() for path in paths):
            self.assertIsNone(process.poll(), "fixture exited before becoming ready")
            if time.monotonic() >= deadline:
                self.fail("fixture did not become ready")
            time.sleep(0.01)

    def assert_fixture_stopped(self, path):
        pid = int(path.read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                   capture_output=True, text=True, timeout=3)
            # An orphan can briefly be a zombie pending reaping by launchd/init.
            if state.returncode != 0 or state.stdout.strip().startswith("Z"):
                return
            time.sleep(0.01)
        self.fail("cancelled fixture process is still running")

    def run_real_api_cancellation(self, *, streaming=False, direct=False, signum=None, resist=False):
        app = self.make_android_app("cancel-app")
        frk.register_project(app)
        _, environment, leader, leaf = self.cancellation_worker()
        environment["FRK_TEST_RESIST"] = "1" if resist else "0"
        args = (["api", "run", "build", str(app), "--platform", "android"] if streaming
                else ["api", "store-versions", str(app)])
        if direct:
            args = ["build", "android", str(app)]
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
        process = subprocess.Popen([sys.executable, str(FRK_PATH), *args], env=environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                   start_new_session=True)
        try:
            self.wait_for_fixture(process, leader, leaf)
            process.send_signal(signum or frk.signal.SIGTERM)
            output, error = process.communicate(timeout=12)
            self.assertIsNone(unrelated.poll(), "cancellation reached an unrelated process")
            self.assert_fixture_stopped(leader)
            self.assert_fixture_stopped(leaf)
            return process.returncode, output, error
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=3)
            process.stdout.close()
            process.stderr.close()
            unrelated.kill()
            unrelated.wait(timeout=3)

    def test_real_store_cancellation_stops_a_stubborn_group_without_leaking_output(self):
        code, output, error = self.run_real_api_cancellation(resist=True)
        self.assertEqual(143, code, error)
        document = json.loads(output)
        self.assertEqual({"protocolVersion", "cliVersion", "error"}, set(document))
        self.assertEqual("store_query_cancelled", document["error"]["code"])
        self.assertNotIn("fixture diagnostic", output + error)

    def test_real_store_ctrl_c_returns_a_cancelled_document(self):
        code, output, error = self.run_real_api_cancellation(signum=frk.signal.SIGINT)
        self.assertEqual(130, code, error)
        self.assertEqual("store_query_cancelled", json.loads(output)["error"]["code"])

    def test_real_stream_cancellation_stops_stubborn_helpers_and_finishes_once(self):
        code, output, error = self.run_real_api_cancellation(streaming=True, resist=True)
        self.assertEqual(143, code, error)
        events = [json.loads(line) for line in output.splitlines()]
        self.assertEqual("started", events[0]["type"])
        self.assertEqual(1, sum(event["type"] == "finished" for event in events))
        self.assertEqual("finished", events[-1]["type"])
        self.assertFalse(events[-1]["success"])
        self.assertEqual(code, events[-1]["exitCode"])

    def test_direct_cli_cancellation_stops_stubborn_helpers(self):
        code, _, error = self.run_real_api_cancellation(direct=True, resist=True)
        self.assertEqual(143, code, error)
        self.assertNotIn("Traceback", error)

    def test_direct_cli_ctrl_c_stops_helpers_without_a_traceback(self):
        code, _, error = self.run_real_api_cancellation(direct=True, signum=frk.signal.SIGINT)
        self.assertEqual(130, code, error)
        self.assertNotIn("Traceback", error)

    def test_timeout_stops_a_helper_after_its_original_parent_exits(self):
        worker, environment, leader, leaf = self.cancellation_worker()
        environment["FRK_TEST_RESIST"] = "1"
        environment["FRK_TEST_LEADER_EXITS"] = "1"
        with (patch.dict(os.environ, environment),
              patch.object(frk, "fastlane_command", return_value=[str(worker)]),
              patch.object(frk, "PROCESS_TERMINATION_GRACE_SECONDS", 0.1)):
            with self.assertRaises(subprocess.TimeoutExpired):
                frk.capture_fastlane(self.root, ["store_versions"], timeout=1)
        self.assert_fixture_stopped(leader)
        self.assert_fixture_stopped(leaf)

    def test_the_document_command_list_matches_the_api_subcommands(self):
        # The class of bug this pins: a name a client can read out of the CLI
        # that the CLI does not accept, which arrives as an argparse usage block
        # on stderr instead of a JSON document. `store-versions` is a document
        # command like `credentials`, so it belongs in this list and nowhere
        # near `capabilities.actions`.
        api = self.subparser_choices(self.build_frk_parser())["api"]
        commands = self.subparser_choices(api)

        self.assertEqual(
            [name for name in commands if name != "run"], list(frk.API_DOCUMENT_COMMANDS)
        )
        self.assertIn("store-versions", frk.API_DOCUMENT_COMMANDS)
        for name in frk.API_DOCUMENT_COMMANDS:
            with self.subTest(name):
                # Every one of them must route its escaped failures to the
                # document channel; a human sentence on stderr would leave a
                # client with zero bytes and a non-zero exit.
                self.assertTrue(commands[name].get_default("api_document_command"))

    def test_no_document_command_is_advertised_as_a_run_action(self):
        self.assertEqual(0, frk.cmd_api_capabilities(argparse.Namespace()))
        advertised = json.loads(self.stdout.getvalue())["capabilities"]["actions"]

        self.assertEqual([], [name for name in frk.API_DOCUMENT_COMMANDS if name in advertised])

    # ----------------------------------------------------------------- #
    # api run action list
    # ----------------------------------------------------------------- #
    def build_frk_parser(self):
        captured = []

        def capture(parser, *args, **kwargs):
            captured.append(parser)
            raise ParserBuilt()

        with patch.object(frk.argparse.ArgumentParser, "parse_args", capture):
            with self.assertRaises(ParserBuilt):
                frk.main()
        return captured[0]

    def subparser_choices(self, parser):
        action = next(
            item for item in parser._actions
            if isinstance(item, frk.argparse._SubParsersAction)
        )
        return action.choices

    def api_run_action_choices(self):
        api = self.subparser_choices(self.build_frk_parser())["api"]
        run = self.subparser_choices(api)["run"]
        action = next(item for item in run._actions if item.dest == "action")
        return list(action.choices)

    def test_every_api_run_action_choice_maps_to_a_cli_command(self):
        choices = self.api_run_action_choices()

        self.assertEqual(
            [
                "onboard", "doctor", "verify", "build", "validate",
                "release", "signing-audit", "signing-import", "signing-link",
                "ios-setup-signing", "status", "forget",
            ],
            choices,
        )
        for action in choices:
            with self.subTest(action):
                command = frk.api_action_command(
                    self.api_run_args(action, "sample", platform="android")
                )
                self.assertEqual([frk.sys.executable, str(FRK_PATH)], command[:2])
                self.assertTrue(command[2:], "an action must map to at least one CLI word")

    # ----------------------------------------------------------------- #
    # locale independence: every byte in and out names its encoding
    # ----------------------------------------------------------------- #
    # A locale whose encoding is neither UTF-8 nor byte-transparent, so an
    # implicit platform default is caught rather than round-tripped by accident.
    ASCII_LOCALE = {"LC_ALL": "en_US.US-ASCII", "LANG": "en_US.US-ASCII"}
    LATIN1_LOCALE = {"LC_ALL": "en_US.ISO8859-1", "LANG": "en_US.ISO8859-1"}
    UTF8_LOCALE = {"LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"}
    NON_ASCII_NAME = "Café Münster فارسی"

    def child_env(self, locale):
        return {
            **os.environ,
            "FLUTTER_RELEASE_HOME": str(self.release_home),
            "PYTHONIOENCODING": "",
            **locale,
        }

    def require_locale(self, locale, expected):
        """Skip unless this machine really offers the locale the test needs."""
        probe = subprocess.run(
            [sys.executable, "-c",
             "import locale; print(locale.getpreferredencoding(False))"],
            capture_output=True, text=True, env=self.child_env(locale),
        )
        if probe.stdout.strip().lower().replace("-", "") != expected:
            self.skipTest(f"{locale['LC_ALL']} is not available on this machine")

    def run_cli(self, argv, locale):
        return subprocess.run(
            [sys.executable, str(FRK_PATH), *argv],
            capture_output=True, env=self.child_env(locale),
        )

    def register_non_ascii_project(self):
        app = self.make_android_app("accented", package="org.example.accented")
        (app / frk.CONFIG_NAME).write_text(
            f'name: "{self.NON_ASCII_NAME}"\n'
            "platforms: [android]\n"
            "android:\n"
            "  package_name: org.example.accented\n",
            encoding="utf-8",
        )
        frk.register_project(app)
        return app

    def test_list_reads_and_prints_a_non_ascii_project_name_under_an_ascii_locale(self):
        # Every read_text/write_text used the platform default, so on a machine
        # whose locale is not UTF-8 the registry could not even be decoded and
        # `frk list` died on a project that works fine elsewhere.
        self.require_locale(self.ASCII_LOCALE, "usascii")
        self.register_non_ascii_project()

        result = self.run_cli(["list"], self.ASCII_LOCALE)

        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", "replace"))
        self.assertIn(self.NON_ASCII_NAME, result.stdout.decode("utf-8"))
        self.assertEqual(b"", result.stderr)

    def test_list_output_is_byte_identical_across_utf8_and_latin1_locales(self):
        # ISO-8859-1 is byte-transparent, so the corruption is not visible in the
        # name itself — it shows up as a column width computed from mojibake.
        self.require_locale(self.LATIN1_LOCALE, "iso88591")
        self.require_locale(self.UTF8_LOCALE, "utf8")
        self.register_non_ascii_project()

        self.assertEqual(
            self.run_cli(["list"], self.UTF8_LOCALE).stdout,
            self.run_cli(["list"], self.LATIN1_LOCALE).stdout,
        )

    def test_api_projects_emits_utf8_json_under_an_ascii_locale(self):
        # The JSON Lines surface is a wire format: its bytes are UTF-8 whatever
        # the machine's locale claims, so a desktop client can always decode it.
        self.require_locale(self.ASCII_LOCALE, "usascii")
        self.register_non_ascii_project()

        result = self.run_cli(["api", "projects"], self.ASCII_LOCALE)

        self.assertEqual(0, result.returncode, result.stderr.decode("utf-8", "replace"))
        payload = json.loads(result.stdout.decode("utf-8"))
        self.assertEqual([self.NON_ASCII_NAME], [p["name"] for p in payload["projects"]])

    # ----------------------------------------------------------------- #
    # external tools that never answer
    # ----------------------------------------------------------------- #
    def wedged_tool(self):
        """Stand in for an external tool that never returns.

        A call with no `timeout` would block this process forever; the suite
        cannot wait for that, so it is reported as a failure instead. A call
        that does pass one gets the TimeoutExpired subprocess would raise.
        """
        def run(command, **kwargs):
            timeout = kwargs.get("timeout")
            if timeout is None:
                raise AssertionError(f"{command[0]} was invoked with no timeout")
            raise frk.subprocess.TimeoutExpired(cmd=command, timeout=timeout)
        return run

    def test_api_projects_answers_even_when_the_security_tool_hangs(self):
        # `security` can wedge on a locked or corrupt keychain. There was no
        # timeout here and none in the desktop client either, so the UI froze
        # permanently on a machine that is otherwise perfectly healthy.
        app = self.make_unonboarded_app(
            "wedged_ios", ios_bundle="org.example.wedged", ios_team="ABCDE12345"
        )
        (app / "fastlane").mkdir()
        (app / "fastlane" / "Fastfile").write_text("import kit_fastfile\n")
        (app / frk.CONFIG_NAME).write_text(
            "name: wedged_ios\n"
            "platforms: [ios]\n"
            "ios:\n"
            "  bundle_id: org.example.wedged\n"
            "  team_id: ABCDE12345\n"
        )
        frk.register_project(app)

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()) as run,
        ):
            self.assertEqual(0, frk.cmd_api_projects(argparse.Namespace()))

        self.assertTrue(run.call_count, "the wedged tool was never reached")
        record = self.payload()["projects"][0]
        self.assertEqual("wedged_ios", record["name"])
        # `false` here is fail-closed, not a finding: this record has no detail
        # field, so the reason lives in the setup record (next test). What must
        # not happen either way is the timeout being memoised as an empty
        # keychain for the rest of the process.
        self.assertFalse(record["ios"]["distributionIdentityReady"])
        self.assertFalse(record["ios"]["signingReady"])
        self.assertIsNone(frk.distribution_identities.cache)
        self.assertIn("did not answer within", frk.distribution_identities.unavailable)

    def test_a_wedged_security_tool_is_reported_as_unverified_not_as_no_identity(self):
        # Same wedge as above, one level up: `ready: False` is a fail-closed
        # placeholder here, so the record has to say the check never ran.
        app = self.make_unonboarded_app(
            "unverified_ios", ios_bundle="org.example.unverified", ios_team="ABCDE12345"
        )
        (app / "fastlane").mkdir()
        (app / "fastlane" / "Fastfile").write_text("import kit_fastfile\n")
        (app / frk.CONFIG_NAME).write_text(
            "name: unverified_ios\n"
            "platforms: [ios]\n"
            "ios:\n"
            "  bundle_id: org.example.unverified\n"
            "  team_id: ABCDE12345\n"
        )
        frk.register_project(app)

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            self.assertEqual(0, frk.cmd_api_setup(argparse.Namespace(app_dir="unverified_ios")))

        ios = self.payload()["ios"]
        self.assertFalse(ios["distributionIdentityReady"])
        self.assertIn("did not answer within", ios["distributionIdentityDetail"])
        self.assertNotIn(
            "No Apple Distribution certificate", ios["distributionIdentityDetail"]
        )

    def test_git_exposure_guards_fail_closed_when_git_hangs(self):
        # These four decide whether a signing secret is sitting in a repository.
        # Falling back to the reassuring answer turns a visible hang into a
        # confident wrong "safe", which is strictly worse: it is silent.
        repo = self.root / "wedged-repo"
        (repo / "android").mkdir(parents=True)
        keystore = repo / "android" / "upload.jks"
        keystore.write_bytes(b"keystore")

        cases = (
            ("git_tracks", lambda: frk.git_tracks(repo, "android/key.properties"), True),
            ("git_tracks_path", lambda: frk.git_tracks_path(keystore), True),
            ("git_ignores", lambda: frk.git_ignores(repo, "android/key.properties"), False),
            (
                "git_path_is_ignored_or_external",
                lambda: frk.git_path_is_ignored_or_external(keystore),
                False,
            ),
        )
        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/git"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            for name, helper, expected in cases:
                with self.subTest(helper=name):
                    frk.begin_git_checks()
                    # The answer that makes the caller warn, never the one that
                    # makes it reassure.
                    self.assertIs(expected, helper())
                    self.assertTrue(frk.git_check_timed_out())

        # The fallbacks are placeholders, not observations, so they are recorded
        # on the timeout channel instead: these predicates return a bool and have
        # never printed anything, and a hung git must not change that.
        self.assertEqual("", self.stdout.getvalue())
        self.assertEqual("", self.stderr.getvalue())

    def test_a_stalled_git_is_never_reported_as_a_git_safe_project(self):
        # git_safe is the machine-API field the desktop renders as a green
        # check, and cmd_signing_import's rotate-the-key warning hangs off the
        # same helpers. A stalled git must not clear either of them.
        app = self.make_android_app(package="org.example.stalled")

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/git"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            record = frk.android_setup_record(app, "org.example.stalled")

        self.assertFalse(record["gitSafe"])
        self.assertFalse(record["signingReady"])
        # The v1 key set is frozen, so the "this was never checked" signal rides
        # the group flag rather than a new field; the record's four Git booleans
        # are fail-closed placeholders whenever it is set.
        self.assertTrue(frk.git_check_timed_out())

    def test_signing_audit_reports_a_stalled_git_as_an_unfinished_check(self):
        app = self.make_android_app(package="org.example.auditstall")
        frk.register_project(app)

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/git"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            status = frk.cmd_signing_audit(argparse.Namespace(app_dir=str(app)))

        output = self.stdout.getvalue() + self.stderr.getvalue()
        self.assertEqual(1, status)
        self.assertIn("Git exposure could not be verified", output)
        # Neither the reassurance nor the accusation: nothing was observed.
        self.assertNotIn("signing secrets are not tracked by Git", output)
        self.assertNotIn("tracked by Git — remove it from the index", output)

    def test_signing_import_says_the_git_check_did_not_finish(self):
        app = self.make_android_app(package="org.example.importstall")
        frk.register_project(app)
        source_dir = self.root / "stalled-signing"
        source_dir.mkdir()
        (source_dir / "original.jks").write_bytes(b"fake-keystore")
        source = source_dir / "key.properties"
        source.write_text(
            "storeFile=original.jks\n"
            "storePassword=store-secret\n"
            "keyAlias=upload\n"
            "keyPassword=key-secret\n"
        )
        args = argparse.Namespace(
            app_dir=str(app), properties=str(source), keystore=None,
            force=False, link=False, dry_run=False,
        )

        with (
            patch.object(frk, "validate_keystore_file", return_value="AA:BB"),
            patch.object(frk.shutil, "which", return_value="/usr/bin/git"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            self.assertEqual(0, frk.cmd_signing_import(args))

        output = self.stdout.getvalue() + self.stderr.getvalue()
        self.assertIn("could not check whether the original signing file is tracked", output)
        # A stalled git used to produce silence here, which reads as "checked,
        # and it is fine" — the one thing this warning exists to prevent.
        self.assertNotIn("rotate the upload key if it was pushed", output)

    def test_signing_link_says_the_git_check_did_not_finish(self):
        app = self.make_android_app(package="org.example.linkstall")
        frk.register_project(app)
        source_dir = self.root / "link-signing"
        source_dir.mkdir()
        (source_dir / "original.jks").write_bytes(b"fake-keystore")
        source = source_dir / "key.properties"
        source.write_text(
            "storeFile=original.jks\n"
            "storePassword=store-secret\n"
            "keyAlias=upload\n"
            "keyPassword=key-secret\n"
        )
        with patch.object(frk, "validate_keystore_file", return_value="AA:BB"):
            self.assertEqual(0, frk.cmd_signing_import(argparse.Namespace(
                app_dir=str(app), properties=str(source), keystore=None,
                force=False, link=False, dry_run=False,
            )))

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/git"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            self.assertEqual(0, frk.cmd_signing_link(argparse.Namespace(app_dir=str(app))))

        output = self.stdout.getvalue() + self.stderr.getvalue()
        self.assertIn("could not check whether android/key.properties is tracked", output)
        self.assertNotIn("run `git rm --cached", output)

    def test_a_wedged_keychain_is_not_reported_as_a_missing_certificate(self):
        # "No Apple Distribution certificate ..." sends the user off to mint a
        # duplicate distribution certificate: expensive, and hard to undo. It
        # must only ever be said about a keychain that was actually read.
        identity = {"fingerprint": "B" * 40,
                    "name": "Apple Distribution: Example Ltd (ABCDE12345)"}
        success = types.SimpleNamespace(
            returncode=0, stdout=f'  1) {identity["fingerprint"]} "{identity["name"]}"\n', stderr=""
        )

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            self.assertEqual([], frk.distribution_identities())
            record = frk.distribution_identity_record("ABCDE12345")

        self.assertFalse(record["ready"])
        self.assertFalse(record["checked"])
        self.assertIn("did not answer within", record["detail"])
        self.assertNotIn("No Apple Distribution certificate", record["detail"])

        # And the timeout is not memoised as "this machine has no identities"
        # for the rest of the process.
        self.assertIsNone(frk.distribution_identities.cache)
        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", return_value=success),
        ):
            self.assertEqual([identity], frk.distribution_identities())
            self.assertTrue(frk.distribution_identity_record("ABCDE12345")["checked"])

    def test_decode_provisioning_profile_reports_a_security_tool_that_hangs(self):
        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", side_effect=self.wedged_tool()),
        ):
            profile, error = frk.decode_provisioning_profile(
                self.root / "wedged.mobileprovision"
            )

        self.assertIsNone(profile)
        # The only probe here with somewhere to put the reason, so it says what
        # actually happened rather than borrowing "tool is unavailable".
        self.assertEqual("the macOS security tool did not answer in time", error)

    def test_a_failing_security_probe_is_not_memoised_as_an_empty_keychain(self):
        # The cache is process-wide, so one transient failure used to report
        # every iOS app as having no distribution identity for the whole run.
        identity = {"fingerprint": "A" * 40,
                    "name": "Apple Distribution: Example Ltd (ABCDE12345)"}
        failure = types.SimpleNamespace(returncode=1, stdout="", stderr="keychain locked")
        success = types.SimpleNamespace(
            returncode=0, stdout=f'  1) {identity["fingerprint"]} "{identity["name"]}"\n', stderr=""
        )

        with (
            patch.object(frk.shutil, "which", return_value="/usr/bin/security"),
            patch.object(frk.subprocess, "run", side_effect=[failure, success]) as run,
        ):
            self.assertEqual([], frk.distribution_identities())
            self.assertIsNone(frk.distribution_identities.cache)
            self.assertEqual([identity], frk.distribution_identities())

        self.assertEqual(2, run.call_count)
        self.assertEqual([identity], frk.distribution_identities.cache)

    def test_find_keytool_skips_a_candidate_whose_help_probe_hangs(self):
        java_home = self.make_jdk_bin("wedged-home").parent.parent
        wedged = (java_home / "bin" / "keytool").resolve()
        responsive = self.make_jdk_bin("responsive-jdk").resolve()

        def probe(command, **kwargs):
            self.assertIsNotNone(kwargs.get("timeout"), "the -help probe can hang")
            if command[0] == str(wedged):
                raise frk.subprocess.TimeoutExpired(cmd=command, timeout=kwargs["timeout"])
            return types.SimpleNamespace(returncode=0 if command[0] == str(responsive) else 1)

        with (
            patch.dict(os.environ, {"JAVA_HOME": str(java_home)}),
            patch.object(frk.shutil, "which", return_value=str(responsive)),
            patch.object(frk.subprocess, "run", side_effect=probe),
        ):
            self.assertEqual(str(responsive), frk.find_keytool())

        # find_keytool returns a path or None and has no channel for a reason.
        self.assertEqual("", self.stdout.getvalue())

    # ----------------------------------------------------------------- #
    # source-level invariants for the two sweeps above
    # ----------------------------------------------------------------- #
    @staticmethod
    def cli_calls():
        return [
            node for node in ast.walk(ast.parse(FRK_PATH.read_text(encoding="utf-8")))
            if isinstance(node, ast.Call)
        ]

    @staticmethod
    def keyword_constant(call, name):
        for keyword in call.keywords:
            if keyword.arg == name and isinstance(keyword.value, ast.Constant):
                return keyword.value.value
        return None

    @staticmethod
    def has_keyword(call, name):
        return any(keyword.arg == name for keyword in call.keywords)

    @staticmethod
    def subprocess_calls(calls, attributes):
        for call in calls:
            func = call.func
            if (
                isinstance(func, ast.Attribute)
                and func.attr in attributes
                and isinstance(func.value, ast.Name)
                and func.value.id == "subprocess"
            ):
                yield call

    def test_every_subprocess_run_in_the_cli_passes_a_timeout(self):
        # subprocess.run waits forever by default. `security`, `git` and
        # `keytool` can all wedge, and the desktop client has no timeout of its
        # own, so one of those hung the whole UI with no way out.
        calls = self.cli_calls()
        untimed = [
            call.lineno for call in self.subprocess_calls(calls, {"run"})
            if not self.has_keyword(call, "timeout")
        ]

        self.assertEqual([], untimed)
        # The bounded calls are short probes. Build children and the API stream
        # can legitimately run for an hour; their cancellation owns the group.
        self.assertTrue(list(self.subprocess_calls(calls, {"run"})))

    def test_every_text_mode_child_in_the_cli_pins_its_decoding(self):
        for call in self.subprocess_calls(self.cli_calls(), {"run", "Popen"}):
            if self.keyword_constant(call, "text") is not True:
                continue
            with self.subTest(line=call.lineno):
                self.assertEqual("utf-8", self.keyword_constant(call, "encoding"))
                self.assertEqual("replace", self.keyword_constant(call, "errors"))

    def test_every_text_file_access_in_the_cli_names_utf8(self):
        # Path.read_text/write_text and open() follow the locale unless told
        # otherwise, which corrupts or rejects any non-ASCII project name on a
        # machine that is not configured for UTF-8. Binary read_bytes/write_bytes
        # are deliberately absent from this list.
        unpinned = []
        for call in self.cli_calls():
            func = call.func
            name = (
                func.attr if isinstance(func, ast.Attribute)
                else func.id if isinstance(func, ast.Name)
                else None
            )
            # os.open returns a raw descriptor; there is no text decoding to pin.
            if (isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name)
                    and func.value.id == "os" and name == "open"):
                continue
            if name not in {"read_text", "write_text", "open", "fdopen"}:
                continue
            if self.keyword_constant(call, "encoding") != "utf-8":
                unpinned.append((name, call.lineno))

        self.assertEqual([], unpinned)

    def test_capabilities_actions_match_the_api_run_action_surface(self):
        parser = self.build_frk_parser()
        api_commands = list(self.subparser_choices(self.subparser_choices(parser)["api"]))
        run_choices = self.api_run_action_choices()
        self.assertEqual(0, frk.cmd_api_capabilities(argparse.Namespace()))
        advertised = json.loads(self.stdout.getvalue())["capabilities"]["actions"]

        # All three copies of the action list are now one tuple, in order.
        self.assertEqual(list(frk.API_RUN_ACTIONS), run_choices)
        self.assertEqual(list(frk.API_RUN_ACTIONS), advertised)
        # `api` subcommands are a different surface and none of them is
        # advertised as an `api run` action — including the two credential
        # subcommands, which the document used to claim were run actions.
        self.assertEqual(
            [
                "capabilities", "projects", "project", "setup",
                "credentials", "configure-credentials", "store-versions",
                "build-args", "set-build-args", "set-track", "run",
            ],
            [name for name in api_commands if name not in advertised],
        )
        # Every advertised action reaches the dispatch: nothing the document
        # names can fall through to argparse's usage block on stderr.
        for name in advertised:
            with self.subTest(name):
                frk.api_action_command(self.api_run_args(name, "sample", platform="android"))

    # ----------------------------------------------------------------- #
    # docs/MACHINE_API.md against the implementation
    # ----------------------------------------------------------------- #
    DOCS_PATH = Path(__file__).resolve().parents[1] / "docs" / "MACHINE_API.md"

    @staticmethod
    def emitted_error_codes():
        """Every error code bin/frk can put on the wire, read from its source.

        Source text rather than a constant on purpose: the defect this catches
        is a code added at a call site and never written down, and a list the
        docs and the code both read from would not have caught it either.
        """
        source = FRK_PATH.read_text()
        codes = set(re.findall(r'api_error\(\s*"([a-z_]+)"', source))
        codes |= set(re.findall(r'api_failure_channel\(\s*args,\s*"([a-z_]+)"', source))
        codes |= set(re.findall(r'code="([a-z_]+)"', source))
        return codes

    def test_every_error_code_the_cli_emits_is_in_the_documented_table(self):
        # A client switches on `error.code`. A code that reaches the wire
        # without a row in the table is a branch no client knows to write, and
        # `stream_failed` — the one a crashed stream consumer emits — was
        # exactly that.
        docs = self.DOCS_PATH.read_text()
        codes = self.emitted_error_codes()

        self.assertIn("stream_failed", codes)
        for code in sorted(codes):
            with self.subTest(code):
                self.assertIn(f"| `{code}` |", docs)

    def test_docs_do_not_claim_a_failed_run_never_emits_an_error_event(self):
        # `cmd_api_run`'s `except BaseException` handler emits `error` with
        # `stream_failed` after `started`, so an unqualified "an action that
        # runs and then fails emits no error event" tells a client to skip a
        # terminal-adjacent event it will actually receive.
        docs = self.DOCS_PATH.read_text()

        self.assertNotIn("An action that runs and then fails emits no `error` event", docs)
        self.assertIn("stream_failed", docs)

    def test_docs_describe_the_store_timeout_that_the_code_implements(self):
        # `capture_fastlane` passes the budget to `communicate(timeout=...)`,
        # which is a total wall-clock deadline. Documenting it as an inactivity
        # timer sends the reader hunting for a hang that never happened.
        docs = self.DOCS_PATH.read_text()

        self.assertNotIn("no progress", docs)
        self.assertIn(
            f"did not finish within {frk.STORE_VERSIONS_TIMEOUT_SECONDS} seconds", docs
        )

    def test_the_cli_source_does_not_describe_the_store_budget_as_an_idle_timer(self):
        self.assertNotIn("stopped making progress", FRK_PATH.read_text())

    def test_every_advertised_action_is_accepted_by_the_api_run_parser(self):
        # The desktop client reads `capabilities.actions` and then spawns
        # `frk api run <action>`. An advertised action the parser rejects exits
        # 2 with an argparse usage block on stderr, breaking the
        # one-JSON-document-per-line contract before a single event is emitted.
        self.assertEqual(0, frk.cmd_api_capabilities(argparse.Namespace()))
        advertised = json.loads(self.stdout.getvalue())["capabilities"]["actions"]
        api = self.subparser_choices(self.build_frk_parser())["api"]
        run = self.subparser_choices(api)["run"]

        for name in advertised:
            with self.subTest(name):
                parsed = run.parse_args([name, "sample"])
                self.assertEqual(name, parsed.action)


if __name__ == "__main__":
    unittest.main()
