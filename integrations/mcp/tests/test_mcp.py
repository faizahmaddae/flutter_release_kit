import asyncio
import json
import os
from pathlib import Path
import signal
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

from mcp import Client
from mcp.client.stdio import StdioServerParameters

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from frk_mcp import FRKClient, Jobs, process_environment  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
SERVER = ROOT / "integrations/mcp/frk_mcp.py"
FAKE = Path(__file__).with_name("fake_frk.py")


class MCPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="frk-mcp-test-")
        self.root = Path(self.temp.name)
        self.env = {
            "FLUTTER_RELEASE_HOME": str(self.root / "vault"),
            "FAKE_PROJECT_PATH": str(self.root / "project with spaces"),
            "FAKE_CALLS_PATH": str(self.root / "calls.jsonl"),
            "FAKE_HELPER_PID": str(self.root / "helper.pid"),
            "FAKE_SERVER_PID": str(self.root / "server.pid"),
        }
        self.client = FRKClient(FAKE)
        self.client.env.update(self.env)
        self.jobs = Jobs(self.client, self.root / "state")

    async def asyncTearDown(self):
        await self.jobs.close()
        self.temp.cleanup()

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    async def finish(self, result):
        job = self.jobs.get(result["jobId"])
        await asyncio.wait_for(job.task, 10)
        return job.snapshot()

    async def wait_for_helper(self):
        for _ in range(200):
            if (self.root / "helper.pid").exists():
                return int((self.root / "helper.pid").read_text())
            await asyncio.sleep(0.01)
        self.fail("Fake FRK never started its helper")

    async def test_compatibility_and_old_cli_rejection(self):
        await self.client.check_compatibility()
        for mode in ["old", "protocol"]:
            self.client.env["FAKE_FRK_MODE"] = mode
            with self.assertRaises(ValueError):
                await self.client.check_compatibility()

    async def test_explicit_toolchain_path_takes_precedence_over_gui_fallbacks(self):
        with patch.dict(os.environ, {"PATH": "/custom/flutter/bin:/custom/ruby/bin"}):
            env = process_environment()
        self.assertTrue(env["PATH"].startswith("/custom/flutter/bin:/custom/ruby/bin:"))
        self.assertIn("/opt/homebrew/bin", env["PATH"].split(os.pathsep))

    async def test_build_uses_api_resolved_path_and_explicit_arguments(self):
        result = await self.jobs.start("build", "test-app", "request-001", "android", "1.2.3", 42)
        self.assertEqual(result["status"], "running")
        done = await self.finish(result)
        self.assertEqual(done["status"], "succeeded")
        self.assertEqual(self.calls(), [["run", "build", "--platform=android", "--build-name=1.2.3", "--build-number=42", "--", self.env["FAKE_PROJECT_PATH"]]])
        self.assertNotIn("PRIVATE_SENTINEL", json.dumps(done))
        self.assertIn("PRIVATE_SENTINEL", Path(done["localLogPath"]).read_text())
        self.assertEqual(stat.S_IMODE(Path(done["localLogPath"]).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.jobs.state_dir.stat().st_mode), 0o700)

    async def test_upload_uses_existing_testing_destination_without_bypass_flags(self):
        for platform, destination in [("android", "internal"), ("ios", "TestFlight")]:
            result = await self.jobs.start("upload", "test-app", "upload-" + platform, platform, "1.2.3", 42)
            self.assertEqual((await self.finish(result))["destination"], destination)
        self.assertTrue(all(call[1] == "release" for call in self.calls()))
        self.assertFalse(any("--skip-" in arg for call in self.calls() for arg in call))

    async def test_retry_returns_same_job_even_after_completion(self):
        arguments = ("upload", "test-app", "same-request", "ios", "1.2.3", 42)
        one, two = await asyncio.gather(self.jobs.start(*arguments), self.jobs.start(*arguments))
        self.assertEqual(one["jobId"], two["jobId"])
        await self.finish(one)
        again = await self.jobs.start(*arguments)
        self.assertEqual(again["jobId"], one["jobId"])
        self.assertEqual(len(self.calls()), 1)
        with self.assertRaisesRegex(ValueError, "different arguments"):
            await self.jobs.start("upload", "test-app", "same-request", "ios", "1.2.3", 43)

    async def test_bad_input_never_starts_work(self):
        for platform, version, number in [("all", "1.0", 1), ("ios", None, 1), ("ios", "--flag", 1), ("ios", "1.0;echo", 1), ("ios", "1.0", True), ("ios", "1.0", 0), ("ios", "1.0", 2_100_000_001)]:
            with self.assertRaises(ValueError):
                await self.jobs.start("upload", "test-app", "request-bad", platform, version, number)
        for project in ["unknown", "--skip-tests", self.env["FAKE_PROJECT_PATH"]]:
            with self.assertRaises(ValueError):
                await self.jobs.start("build", project, "request-bad", "ios", "1.0", 1)
        self.assertEqual(self.calls(), [])

    async def test_missing_projects_unconfigured_platforms_and_production_are_rejected(self):
        for mode in ["missing", "android_only", "production", "no_android_config"]:
            self.client.env["FAKE_FRK_MODE"] = mode
            platform = "ios" if mode == "android_only" else "android"
            with self.assertRaises(ValueError):
                await self.jobs.start("upload", "test-app", "request-" + mode, platform, "1.0", 1)
        self.assertEqual(self.calls(), [])

    async def test_unknown_or_disallowed_action_never_executes(self):
        for action in ["forget", "signing-import", "ios-setup-signing", "onboard", "status", "shell"]:
            with self.assertRaises(ValueError):
                await self.jobs.start(action, "test-app", "request-bad")
        self.assertEqual(self.calls(), [])

    async def test_failure_signals_and_malformed_streams_never_report_success(self):
        for mode in ["failure", "bad_exit", "missing_finished", "duplicate_finished", "raw", "error", "oversized", "oversized_slow"]:
            with self.subTest(mode=mode):
                self.client.env["FAKE_FRK_MODE"] = mode
                result = await self.jobs.start("build", "test-app", "case-" + mode, "ios", "1.0", 1)
                done = await self.finish(result)
                self.assertEqual(done["status"], "failed")
                self.assertNotIn("PRIVATE_SENTINEL", json.dumps(done))

    async def test_store_result_preserves_independent_platform_status(self):
        result = await self.jobs.start("stores", "test-app", "store-check")
        done = await self.finish(result)
        self.assertEqual(done["status"], "succeeded")
        self.assertEqual(done["result"]["android"]["latestVersionCode"], 41)
        self.assertEqual(done["result"]["ios"]["status"], "unavailable")

    async def test_global_lock_prevents_work_from_a_second_mcp_connection(self):
        self.client.env["FAKE_FRK_MODE"] = "slow"
        first = await self.jobs.start("build", "test-app", "first-job", "ios", "1.0", 1)
        await self.wait_for_helper()
        other = Jobs(self.client, self.jobs.state_dir)
        with self.assertRaisesRegex(ValueError, "Another FRK MCP job"):
            await other.start("upload", "test-app", "second-job", "ios", "1.0", 2)
        await self.jobs.cancel(first["jobId"])
        self.client.env["FAKE_FRK_MODE"] = "success"
        second = await other.start("build", "test-app", "second-job", "ios", "1.0", 2)
        await asyncio.wait_for(other.get(second["jobId"]).task, 10)
        self.assertEqual(other.get(second["jobId"]).status, "succeeded")

    async def test_cancel_stops_helper_and_remains_cancelled_on_exit_zero(self):
        self.client.env["FAKE_FRK_MODE"] = "slow"
        result = await self.jobs.start("build", "test-app", "cancel-job", "ios", "1.0", 1)
        helper_pid = await self.wait_for_helper()
        done = await asyncio.wait_for(self.jobs.cancel(result["jobId"]), 10)
        self.assertEqual(done["status"], "cancelled")
        with self.assertRaises(ProcessLookupError):
            os.kill(helper_pid, 0)
        self.assertEqual((await self.jobs.cancel(result["jobId"]))["status"], "cancelled")

    async def test_cancel_before_spawn_and_close_release_lock(self):
        result = await self.jobs.start("build", "test-app", "early-cancel", "ios", "1.0", 1)
        done = await self.jobs.cancel(result["jobId"])
        self.assertEqual(done["status"], "cancelled")
        self.client.env["FAKE_FRK_MODE"] = "slow"
        result = await self.jobs.start("build", "test-app", "close-job", "ios", "1.0", 1)
        pid = await self.wait_for_helper()
        await asyncio.wait_for(self.jobs.close(), 10)
        self.assertEqual(self.jobs.get(result["jobId"]).status, "cancelled")
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    async def test_no_raw_cli_error_exposed_to_model(self):
        with self.assertRaises(ValueError) as error:
            await self.client.document("project", "--", "unknown")
        self.assertNotIn("PRIVATE_SENTINEL", str(error.exception))

    def real_project_fixture(self, names):
        entries = []
        for index, name in enumerate(names):
            app = self.root / f"app-{index}"
            (app / "fastlane").mkdir(parents=True)
            (app / "fastlane/Fastfile").write_text("import kit_fastfile\n")
            (app / "fastlane/release_kit.yml").write_text(
                f"name: {name}\nplatforms: [android]\nandroid:\n  package_name: org.example.test{index}\n"
            )
            entries.append({"name": f"original-{index}", "path": str(app), "platforms": ["android"]})
        vault = self.root / "vault"
        vault.mkdir()
        (vault / "projects.json").write_text(json.dumps({"version": 1, "projects": entries}))
        client = FRKClient(ROOT / "bin/frk")
        client.env.update(self.env)
        return client, entries

    async def test_discovered_id_resolves_after_config_rename_without_changing_registry(self):
        client, entries = self.real_project_fixture(["renamed-app"])
        registry = self.root / "vault/projects.json"
        original = registry.read_bytes()
        project = (await client.document("projects"))["projects"][0]
        selected = await client.project(project["id"])
        self.assertEqual(selected["path"], str(Path(entries[0]["path"]).resolve()))
        self.assertEqual(registry.read_bytes(), original)
        for invalid in [entries[0]["name"], entries[0]["path"]]:
            with self.assertRaises(ValueError):
                await client.project(invalid)

    async def test_duplicate_discovery_ids_are_rejected_before_selecting_an_app(self):
        client, _ = self.real_project_fixture(["same-name", "same-name"])
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            await client.project("same-name")

    async def test_document_timeout_cleans_up_a_full_output_pipe(self):
        # A timed-out read relinquishes its stdout reader. Cleanup must drain
        # the pipe instead of waiting forever on an already terminated child.
        spawn = asyncio.create_subprocess_exec
        children = []

        async def capture_spawn(*args, **kwargs):
            child = await spawn(*args, **kwargs)
            children.append(child)
            return child

        command = [sys.executable, "-c", """
import signal, sys, time
def stop(*_):
    sys.stdout.write('x' * (8 * 1024 * 1024))
    sys.stdout.flush()
    sys.exit(0)
signal.signal(signal.SIGTERM, stop)
time.sleep(60)
"""]
        with patch.object(self.client, "command", return_value=command), patch("frk_mcp.asyncio.create_subprocess_exec", side_effect=capture_spawn):
            task = asyncio.create_task(self.client.document("projects", timeout=0.2))
            done, _ = await asyncio.wait({task}, timeout=2)
            if task not in done:
                # Keep a failing regression from leaving a paused pipe behind.
                await children[0].stdout.read()
            with self.assertRaises(asyncio.TimeoutError):
                await task
        self.assertIn(task, done, "Read timeout left cleanup blocked on stdout")
        self.assertIsNotNone(children[0].returncode)

    def stdio_parameters(self, executable=FAKE):
        return StdioServerParameters(
            command=sys.executable,
            args=[str(SERVER), "--frk", str(executable), "--state-dir", str(self.root / "wire-state")],
            env={**os.environ, **self.env},
        )

    async def test_real_stdio_protocol_tools_annotations_and_job_lifecycle(self):
        async with Client(self.stdio_parameters()) as client:
            tools = (await client.list_tools()).tools
            by_name = {tool.name: tool for tool in tools}
            self.assertEqual(set(by_name), {"list_projects", "inspect_project", "start_check", "start_build", "start_upload", "get_job", "list_jobs", "cancel_job"})
            self.assertTrue(by_name["list_projects"].annotations.read_only_hint)
            self.assertFalse(by_name["start_upload"].annotations.read_only_hint)
            self.assertTrue(by_name["start_upload"].annotations.open_world_hint)
            projects = await client.call_tool("list_projects")
            self.assertFalse(projects.is_error)
            self.assertEqual(projects.structured_content["projects"][0]["id"], "test-app")
            inspection = await client.call_tool("inspect_project", {"project_id": "test-app"})
            self.assertFalse(inspection.is_error)
            self.assertTrue(inspection.structured_content["setup"]["ios"]["signingReady"])
            invalid = await client.call_tool("start_upload", {"project_id": "test-app", "platform": "ios", "version_name": "1.0", "build_number": True, "request_id": "invalid-bool"})
            self.assertTrue(invalid.is_error)
            args = {"project_id": "test-app", "platform": "android", "version_name": "1.2.3", "build_number": 42, "request_id": "wire-build"}
            started = await client.call_tool("start_build", args)
            self.assertFalse(started.is_error)
            job_id = started.structured_content["jobId"]
            for _ in range(100):
                status = await client.call_tool("get_job", {"job_id": job_id})
                if status.structured_content["status"] != "running":
                    break
                await asyncio.sleep(0.02)
            self.assertEqual(status.structured_content["status"], "succeeded")
            self.assertNotIn("PRIVATE_SENTINEL", status.model_dump_json())
            retry = await client.call_tool("start_build", args)
            self.assertEqual(retry.structured_content["jobId"], job_id)
            listing = await client.call_tool("list_jobs")
            self.assertEqual(len(listing.structured_content["jobs"]), 1)

    async def test_legacy_handshake_client_and_real_cli_empty_sandbox(self):
        # Real FRK, but an empty temporary vault: no user's projects or keys are reachable.
        async with Client(self.stdio_parameters(ROOT / "bin/frk"), mode="legacy") as client:
            result = await client.call_tool("list_projects")
            self.assertFalse(result.is_error)
            self.assertEqual(result.structured_content["projects"], [])

    async def test_stdio_disconnect_cancels_active_job(self):
        parameters = self.stdio_parameters()
        parameters.env["FAKE_FRK_MODE"] = "slow"
        async with Client(parameters) as client:
            started = await client.call_tool("start_build", {"project_id": "test-app", "platform": "ios", "version_name": "1.0", "build_number": 1, "request_id": "disconnect-job"})
            self.assertFalse(started.is_error)
            pid = await self.wait_for_helper()
        for _ in range(200):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            await asyncio.sleep(0.02)
        else:
            os.kill(pid, signal.SIGTERM)
            self.fail("MCP disconnect left a job helper running")

    async def test_server_sigterm_stops_active_helper(self):
        parameters = self.stdio_parameters()
        parameters.env["FAKE_FRK_MODE"] = "slow"
        async with Client(parameters) as client:
            started = await client.call_tool("start_build", {"project_id": "test-app", "platform": "ios", "version_name": "1.0", "build_number": 1, "request_id": "sigterm-job"})
            self.assertFalse(started.is_error)
            helper_pid = await self.wait_for_helper()
            server_pid = int((self.root / "server.pid").read_text())
            os.kill(server_pid, signal.SIGTERM)
        with self.assertRaises(ProcessLookupError):
            os.kill(helper_pid, 0)


if __name__ == "__main__":
    unittest.main()
