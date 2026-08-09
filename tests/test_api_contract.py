import argparse
import atexit
import importlib.util
import io
import json
import os
import contextlib
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
FRK_PATH = REPO_ROOT / "bin" / "frk"
FIXTURE_PATH = Path(__file__).resolve().parent / "fixtures" / "api_v1_keys.json"

# bin/frk reads FLUTTER_RELEASE_HOME every time it needs a vault path, so
# pointing it at a throwaway directory for the whole test process keeps the real
# ~/.flutter-release out of reach. setUp narrows it to a per-test directory.
_SANDBOX_HOME = tempfile.TemporaryDirectory(prefix="frk-api-contract-")
atexit.register(_SANDBOX_HOME.cleanup)
os.environ["FLUTTER_RELEASE_HOME"] = _SANDBOX_HOME.name

SPEC = importlib.util.spec_from_loader("frk", SourceFileLoader("frk", str(FRK_PATH)))
frk = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(frk)

# Store credentials are read from the process environment first, so they are
# cleared while records are built. Only key names are compared, but a stray
# ASC_KEY_ID on a developer machine would still change which branch runs.
CREDENTIAL_ENVIRONMENT = {
    "SUPPLY_JSON_KEY": "",
    "ASC_KEY_ID": "",
    "ASC_ISSUER_ID": "",
    "ASC_KEY_CONTENT": "",
    "ASC_KEY_FILEPATH": "",
}

ROOT_PATH = "."


def key_map(record):
    """Flatten a record into {dotted path: sorted key names} with no values.

    A list of objects is a nesting level too, and one the desktop side has to
    model: its elements are recorded under `<path>[]`. Every element is walked
    rather than just the first, and an element whose key set differs from its
    siblings' is an error here — a heterogeneous list is not a contract, and
    averaging it into a union would let a dropped key hide behind a neighbour.
    """
    paths = {}

    def walk(node, prefix):
        keys = sorted(node.keys())
        previous = paths.get(prefix)
        if previous is not None and previous != keys:
            raise AssertionError(
                f"{prefix} has inconsistent objects: {previous} then {keys}"
            )
        paths[prefix] = keys
        for key, value in node.items():
            child = key if prefix == ROOT_PATH else f"{prefix}.{key}"
            if isinstance(value, dict):
                walk(value, child)
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        walk(item, f"{child}[]")

    walk(record, ROOT_PATH)
    return paths


def seed_project(root):
    """A dual-platform managed project with both release artifacts present."""
    app = root / "contract_app"
    (app / "android" / "app").mkdir(parents=True)
    (app / "ios" / "Runner.xcodeproj").mkdir(parents=True)
    (app / "fastlane").mkdir(parents=True)
    (app / "build" / "app" / "outputs" / "bundle" / "release").mkdir(parents=True)
    (app / "build" / "ios" / "ipa").mkdir(parents=True)

    (app / "pubspec.yaml").write_text(
        "name: contract_app\n"
        "version: 1.4.2+17\n"
        "dependencies:\n"
        "  flutter:\n"
        "    sdk: flutter\n"
    )
    (app / "android" / "app" / "build.gradle.kts").write_text(
        'android { defaultConfig { applicationId = "org.example.contract" } }\n'
    )
    (app / "ios" / "Runner.xcodeproj" / "project.pbxproj").write_text(
        "PRODUCT_BUNDLE_IDENTIFIER = org.example.contract;\n"
        "DEVELOPMENT_TEAM = ABCDE12345;\n"
    )
    (app / "fastlane" / "Fastfile").write_text("import kit_fastfile\n")
    (app / frk.CONFIG_NAME).write_text(
        "name: contract_app\n"
        "platforms: [android, ios]\n"
        "android:\n"
        "  package_name: org.example.contract\n"
        "  track: internal\n"
        "ios:\n"
        "  bundle_id: org.example.contract\n"
        "  team_id: ABCDE12345\n"
    )
    (app / "build" / "app" / "outputs" / "bundle" / "release" / "app-release.aab").write_bytes(b"aab")
    (app / "build" / "ios" / "ipa" / "contract_app.ipa").write_bytes(b"ipa")
    return app


# The report `fastlane store_versions` prints, seeded here so the golden key set
# comes out of a real run of the real builder instead of being transcribed from
# bin/frk by eye. Both platforms are "ok" on purpose: that is the only case that
# populates every member, including the objects inside `tracks` and `builds`,
# and a key set generated from a degraded report would freeze a smaller surface
# than the one clients actually receive. Two entries per list so `key_map`'s
# per-element check has something to compare.
LANE_STORE_VERSIONS_REPORT = {
    "project": "whatever-the-lane-calls-it",
    "checkedAt": "2026-01-01T00:00:00.000Z",
    "android": {
        "status": "ok",
        "detail": "Google Play's highest known version code is 38 and the configured "
                  "'internal' track is at 38.",
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
        "detail": "TestFlight's newest upload is build 41 of version 2.1.0, state PROCESSING; "
                  "the latest App Store release is 2.0.8.",
        "latestAppStoreVersion": "2.0.8",
        "builds": [
            {"version": "2.1.0", "build": 41, "state": "PROCESSING"},
            {"version": "2.0.9", "build": 40, "state": "VALID"},
        ],
    },
}


def lane_output(report):
    """A realistic fastlane run: chatter, the marker line, then a run summary."""
    payload = json.dumps(report, separators=(",", ":"), ensure_ascii=False)
    return (
        "[00:00:00]: Driving the lane 'store_versions'\n"
        f"[00:00:01]: {frk.STORE_VERSIONS_MARKER} {payload}\n"
        "[00:00:02]: fastlane.tools finished successfully\n"
    )


def registry_entry(app):
    return {
        "name": "contract_app",
        "path": str(app),
        "platforms": ["android", "ios"],
        "added_at": "2026-01-01T00:00:00+00:00",
    }


class APIContractTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.release_home = self.root / "release-home"
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(
            patch.dict(os.environ, {"FLUTTER_RELEASE_HOME": str(self.release_home)})
        )
        # An empty cache keeps `security find-identity` away from the real keychain.
        frk.distribution_identities.cache = []
        self.app = seed_project(self.root)
        self.entry = registry_entry(self.app)

    def tearDown(self):
        self.temp.cleanup()

    def golden(self, record_name):
        contract = json.loads(FIXTURE_PATH.read_text())
        return contract["records"][record_name]

    def build_project_record(self):
        return frk.project_api_record(self.entry)

    def build_setup_record(self):
        return frk.setup_status_record(self.entry)

    def build_credential_record(self):
        with patch.dict(os.environ, CREDENTIAL_ENVIRONMENT, clear=False):
            return frk.credential_status_record()

    def build_capabilities_document(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            frk.cmd_api_capabilities(argparse.Namespace())
        return json.loads(stdout.getvalue())

    def build_store_versions_document(self):
        """Run the real command end to end with the store conversation stubbed out.

        `capture_fastlane` is the seam, not the parsing: everything from the
        marker line inwards is the shipping code path, so a renamed key in
        bin/frk's builders reaches this document. Nothing here can touch a
        store — `capture_fastlane` never runs, and the command is read-only in
        any case.
        """
        frk.register_project(self.app)
        stdout = io.StringIO()
        stack = contextlib.ExitStack()
        with stack:
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(patch.object(frk, "fastlane_installed", return_value=True))
            stack.enter_context(
                patch.object(
                    frk,
                    "capture_fastlane",
                    return_value=(0, lane_output(LANE_STORE_VERSIONS_REPORT)),
                )
            )
            status = frk.cmd_api_store_versions(argparse.Namespace(app_dir="contract_app"))
        self.assertEqual(0, status, "the seeded report must produce a document, not an error")
        return json.loads(stdout.getvalue())

    def build_build_args_document(self):
        """Runs the real read command against a config that actually has a shared
        AND a per-platform entry, so `shared`/`own`/`effective` are all populated —
        an empty-everywhere config would freeze a smaller key surface for `effective`
        than clients actually receive, the same reasoning `LANE_STORE_VERSIONS_REPORT`
        above uses for the store-versions document. The shared (top-level) list has
        no CLI/API writer by design, so it is added here directly rather than through
        `set_platform_extra_build_args`, which only ever touches a platform's own."""
        frk.register_project(self.app)
        config_path = self.app / frk.CONFIG_NAME
        config_path.write_text(
            'extra_build_args:\n  - "--dart-define=COMMON=1"\n\n' + config_path.read_text()
        )
        frk.set_platform_extra_build_args(self.app, "android", ["--dart-define=A=1"])
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            status = frk.cmd_api_build_args(argparse.Namespace(app_dir="contract_app"))
        self.assertEqual(0, status, "the seeded config must produce a document, not an error")
        return json.loads(stdout.getvalue())

    def test_project_api_record_keys_match_the_golden_contract(self):
        self.assertEqual(key_map(self.build_project_record()), self.golden("project_api_record"))

    def build_set_track_response(self):
        """`set-track` wraps the same project_api_record `project` already returns,
        rather than inventing a shape of its own — this proves that reuse holds by
        running the real write end to end instead of asserting it against the
        builder in isolation."""
        frk.register_project(self.app)
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            status = frk.cmd_api_set_track(argparse.Namespace(app_dir="contract_app", track="beta"))
        self.assertEqual(0, status, "a valid track on a dual-platform project must produce a document, not an error")
        return json.loads(stdout.getvalue())

    def test_api_set_track_response_matches_the_project_record_contract(self):
        response = self.build_set_track_response()
        self.assertEqual("beta", response["project"]["android"]["track"])
        self.assertEqual(key_map(response["project"]), self.golden("project_api_record"))

    def test_setup_status_record_keys_match_the_golden_contract(self):
        self.assertEqual(key_map(self.build_setup_record()), self.golden("setup_status_record"))

    def test_credential_status_record_keys_match_the_golden_contract(self):
        self.assertEqual(key_map(self.build_credential_record()), self.golden("credential_status_record"))

    def test_capabilities_document_keys_match_the_golden_contract(self):
        self.assertEqual(key_map(self.build_capabilities_document()), self.golden("capabilities_document"))

    def test_store_versions_document_keys_match_the_golden_contract(self):
        self.assertEqual(
            key_map(self.build_store_versions_document()),
            self.golden("store_versions_document"),
        )

    def test_build_args_document_keys_match_the_golden_contract(self):
        self.assertEqual(
            key_map(self.build_build_args_document()),
            self.golden("build_args_document"),
        )

    def test_no_api_record_offers_a_next_version_number(self):
        # A product invariant, pinned where the whole key surface is visible at
        # once: FRK never picks a version number. `store-versions` reports what
        # the stores hold and the client makes the user choose, so a helpfully
        # added nextVersionCode/suggestedBuild anywhere in the API fails here.
        contract = json.loads(FIXTURE_PATH.read_text())
        forbidden = ("next", "suggest", "recommend", "increment")
        for record_name, paths in contract["records"].items():
            for path, keys in paths.items():
                for key in keys:
                    lowered = key.lower()
                    for word in forbidden:
                        self.assertNotIn(
                            word, lowered, f"{record_name}.{path}.{key} proposes a version"
                        )

    def test_golden_contract_records_only_key_names(self):
        contract = json.loads(FIXTURE_PATH.read_text())
        for record_name, paths in contract["records"].items():
            for path, keys in paths.items():
                self.assertIsInstance(keys, list, f"{record_name}.{path}")
                for key in keys:
                    self.assertIsInstance(key, str)
                    self.assertNotIn("/", key, f"{record_name}.{path} looks like a path value")
                self.assertEqual(keys, sorted(keys), f"{record_name}.{path} is not sorted")

    def test_api_documents_wrap_every_record_in_the_same_envelope(self):
        # setup and credentials are splatted into api_document, so their record keys
        # sit next to the envelope keys rather than under a container key.
        setup = frk.api_document(**self.build_setup_record())
        credentials = frk.api_document(**self.build_credential_record())
        project = frk.api_document(project=self.build_project_record())

        for document in (setup, credentials, project):
            self.assertEqual(document["protocolVersion"], 1)
            self.assertEqual(document["cliVersion"], frk.VERSION)
        self.assertEqual(sorted(project.keys()), ["cliVersion", "project", "protocolVersion"])
        self.assertEqual(
            sorted(setup.keys()),
            ["android", "cliVersion", "ios", "projectId", "protocolVersion"],
        )

    def test_project_record_omits_nested_records_when_a_platform_is_absent(self):
        # Characterizes today's behaviour: android/ios/artifact members become null
        # rather than empty objects, which is why the desktop models mark them optional.
        entry = dict(self.entry, path=str(self.root / "not-a-project"))
        golden = self.golden("project_api_record")
        record = frk.project_api_record(entry)

        self.assertEqual(
            key_map(record),
            {ROOT_PATH: golden[ROOT_PATH], "artifacts": golden["artifacts"]},
        )
        self.assertIsNone(record["android"])
        self.assertIsNone(record["ios"])
        self.assertIsNone(record["artifacts"]["androidAab"])
        self.assertEqual(record["state"], "missing")


if __name__ == "__main__":
    unittest.main()
