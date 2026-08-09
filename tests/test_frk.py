import argparse
import contextlib
import importlib.util
from importlib.machinery import SourceFileLoader
import io
import json
import os
import tempfile
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch


FRK_PATH = Path(__file__).resolve().parents[1] / "bin" / "frk"
SPEC = importlib.util.spec_from_loader("frk", SourceFileLoader("frk", str(FRK_PATH)))
frk = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(frk)


class FrkTestCase(unittest.TestCase):
    def setUp(self):
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        self.stdout_redirect = contextlib.redirect_stdout(self.stdout)
        self.stderr_redirect = contextlib.redirect_stderr(self.stderr)
        self.stdout_redirect.__enter__()
        self.stderr_redirect.__enter__()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.release_home = self.root / "release-home"
        frk.CREDENTIALS_DIR = self.release_home
        frk.REGISTRY_PATH = self.release_home / "projects.json"
        frk.SIGNING_DIR = self.release_home / "signing"
        frk._distribution_identities_cache = None

    def tearDown(self):
        self.temp.cleanup()
        self.stderr_redirect.__exit__(None, None, None)
        self.stdout_redirect.__exit__(None, None, None)

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

    def test_registry_contains_only_explicitly_registered_apps(self):
        managed = self.make_android_app("managed")
        self.make_android_app("unmanaged")

        frk.register_project(managed)

        projects = frk.managed_projects()
        self.assertEqual(1, len(projects))
        self.assertEqual(str(managed.resolve()), projects[0]["path"])
        self.assertEqual(["android"], projects[0]["platforms"])
        self.assertEqual(0o600, frk.REGISTRY_PATH.stat().st_mode & 0o777)

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
        self.assertEqual(0o600, frk.REGISTRY_PATH.stat().st_mode & 0o777)

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
        vault = frk.SIGNING_DIR / "org.example.shipped"
        self.assertEqual(store.read_bytes(), (vault / "upload-keystore.jks").read_bytes())
        self.assertEqual(0o600, (vault / "key.properties").stat().st_mode & 0o777)
        central_text = (vault / "key.properties").read_text()
        self.assertIn("storePassword=store secret=#value", central_text)
        self.assertIn("keyPassword=key\\secret", central_text)

        self.assertEqual(0, frk.cmd_signing_link(argparse.Namespace(app_dir=str(app))))
        self.assertTrue(project_props.is_symlink())
        self.assertEqual((vault / "key.properties").resolve(), project_props.resolve())
        self.assertTrue(any((vault / "backups").iterdir()))

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

        vault_props = frk.SIGNING_DIR / "org.example.selected" / "key.properties"
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
            patch.object(frk.subprocess, "call", return_value=0) as call,
        ):
            self.assertEqual(
                0,
                frk.run_fastlane(app, ["android", "release"], prevent_sleep=True),
            )

        self.assertEqual(
            ["caffeinate", "-ims", "fastlane", "android", "release"],
            call.call_args.args[0],
        )

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
        self.assertEqual([frk.sys.executable, str(FRK_PATH), "signing", "ios-setup", "sample"], ios_setup)

        forget = frk.api_action_command(self.api_run_args("forget", "sample"))
        self.assertEqual([frk.sys.executable, str(FRK_PATH), "forget", "sample"], forget)

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


if __name__ == "__main__":
    unittest.main()
