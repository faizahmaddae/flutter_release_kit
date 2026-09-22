"""Local MCP adapter. FRK remains the sole owner of release behavior.

Run with `uv run --project integrations/mcp python integrations/mcp/frk_mcp.py`.
Only stdio is exposed: no network listener, credential editor, or shell tool.
"""
from __future__ import annotations

import argparse
import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import sys
import time
from typing import Annotated, Any, Literal
import uuid

import anyio
from mcp.server import MCPServer
from mcp.types import ToolAnnotations
from pydantic import Field

KIT_ROOT = Path(__file__).resolve().parents[2]
Platform = Literal["android", "ios"]
BuildNumber = Annotated[int, Field(strict=True, ge=1, le=2_100_000_000)]
VersionName = Annotated[str, Field(pattern=r"^[0-9][0-9A-Za-z.+-]{0,63}$")]
RequestID = Annotated[str, Field(min_length=8, max_length=128, pattern=r"^[A-Za-z0-9_-]+$")]
READ_ONLY = ToolAnnotations(read_only_hint=True, destructive_hint=False, open_world_hint=False)
START_JOB = ToolAnnotations(read_only_hint=False, destructive_hint=False, open_world_hint=True)
MAX_LOG_BYTES = 10 * 1024 * 1024

INSTRUCTIONS = """Manage only registered Flutter Release Kit projects. Inspect the project and
store versions before an upload. Use the project ID, platform, version, and build
number requested or accepted by the user; never invent or increment versions.
Call start_upload only when the user requested that upload. Reuse request_id when
retrying a start call in this connection. Poll get_job until terminal; a job ID is
not success. Uploads target configured Play testing tracks or TestFlight only.
Jobs belong to this MCP server session; closing it cancels active work. Cancellation
cannot undo an upload already accepted by a store. Raw build output stays in a
private local log and is never returned to the model. Setup repair, credentials,
project enrollment, configuration edits, and production publishing are not tools.
Do not run releases in the desktop app or CLI while an MCP job is running.
"""


def timestamp() -> str:
    return datetime.now(timezone.utc).isoformat()


def process_environment() -> dict[str, str]:
    """Preserve the host's toolchain choices and add conventional GUI fallbacks."""
    env = os.environ.copy()
    preferred = [
        str(Path.home() / ".local/bin"), str(Path.home() / "development/flutter/bin"),
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    existing = [value for value in env.get("PATH", "").split(os.pathsep) if value]
    env["PATH"] = os.pathsep.join(dict.fromkeys(existing + preferred))
    env.setdefault("LANG", "en_US.UTF-8")
    env.setdefault("LC_ALL", "en_US.UTF-8")
    env["PYTHONUNBUFFERED"] = "1"
    return env


async def stop_process(process: asyncio.subprocess.Process, *, drain_output: bool = False) -> None:
    """Let frk cancel its own nested process groups before considering a kill."""

    async def discard_output() -> None:
        # After a read error/cancellation nobody else consumes stdout. A full
        # asyncio pipe can otherwise keep wait() pending even after child exit.
        while await process.stdout.read(64 * 1024):
            pass

    drain = asyncio.create_task(discard_output()) if drain_output else None
    try:
        if process.returncode is None:
            try:
                process.terminate()
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(process.wait(), timeout=15)
            except asyncio.TimeoutError:
                try:
                    process.kill()
                except ProcessLookupError:
                    pass
                await process.wait()
    finally:
        if drain is not None:
            await drain


class FRKClient:
    def __init__(self, executable: Path):
        self.executable = executable.resolve()
        self.env = process_environment()

    def command(self, *arguments: str) -> list[str]:
        return [sys.executable, str(self.executable), "api", *arguments]

    async def document(self, *arguments: str, timeout: float = 60) -> dict:
        process = await asyncio.create_subprocess_exec(
            *self.command(*arguments), stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            env=self.env,
        )
        try:
            output, _ = await asyncio.wait_for(process.communicate(), timeout)
        except BaseException:
            with anyio.CancelScope(shield=True):
                await stop_process(process, drain_output=True)
            raise
        try:
            result = json.loads(output)
        except (ValueError, UnicodeDecodeError):
            raise ValueError("FRK returned an unreadable response. Check the local CLI installation.") from None
        if not isinstance(result, dict) or result.get("protocolVersion") != 1:
            raise ValueError("This MCP adapter requires FRK machine API protocol 1.")
        if process.returncode or result.get("error"):
            # Do not echo unknown stderr, raw errors, or credential material to an AI.
            raise ValueError("FRK could not complete the read. Check the project ID and local CLI setup.")
        return result

    async def check_compatibility(self) -> None:
        result = await self.document("capabilities")
        version = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", result.get("cliVersion", ""))
        if not version or tuple(map(int, version.groups())) < (0, 8, 1):
            raise ValueError("FRK 0.8.1 or newer is required for reliable job cancellation.")
        actions = result.get("capabilities", {}).get("actions", [])
        if not {"build", "release", "doctor", "verify"}.issubset(actions):
            raise ValueError("The installed FRK does not support the required actions.")

    async def project(self, project_id: str) -> dict:
        if not project_id or len(project_id) > 256 or any(ord(c) < 32 for c in project_id):
            raise ValueError("Use an exact project ID returned by list_projects.")
        # Discovery IDs come from the current config name, while `api project`
        # also accepts paths and resolves names from the saved registry. Resolve
        # against discovery itself so renames and duplicate IDs cannot select
        # the wrong app. All subsequent calls use this record's absolute path.
        projects = (await self.document("projects", timeout=180)).get("projects", [])
        matches = [project for project in projects if project.get("id") == project_id]
        if not matches:
            raise ValueError("Use an exact registered project ID returned by list_projects, not a directory path.")
        if len(matches) != 1:
            raise ValueError("This project ID is ambiguous. Give the registered projects distinct names in FRK first.")
        result = matches[0]
        if not result.get("exists") or not result.get("onboarded"):
            raise ValueError("This registered project is missing or needs onboarding in FRK.")
        return result


@dataclass
class Job:
    id: str
    request_id: str
    signature: tuple
    action: str
    project_id: str
    platform: str | None
    version_name: str | None
    build_number: int | None
    destination: str | None
    log_path: Path
    lock_file: object
    created_at: str = field(default_factory=timestamp)
    started: float = field(default_factory=time.monotonic)
    status: str = "running"
    finished_at: str | None = None
    elapsed: float | None = None
    exit_code: int | None = None
    log_events: int = 0
    result: dict | None = None
    message: str | None = None
    cancel_requested: bool = False
    process: asyncio.subprocess.Process | None = None
    task: asyncio.Task | None = None

    def snapshot(self) -> dict:
        return {
            "jobId": self.id, "requestId": self.request_id, "action": self.action,
            "projectId": self.project_id, "platform": self.platform,
            "versionName": self.version_name, "buildNumber": self.build_number,
            "destination": self.destination, "status": self.status,
            "startedAt": self.created_at, "finishedAt": self.finished_at,
            "elapsedSeconds": round(self.elapsed if self.elapsed is not None else time.monotonic() - self.started, 1),
            "exitCode": self.exit_code, "logEvents": self.log_events,
            "localLogPath": str(self.log_path), "result": self.result,
            "message": self.message,
        }


class Jobs:
    def __init__(self, client: FRKClient, state_dir: Path):
        self.client = client
        self.state_dir = state_dir
        self.jobs: dict[str, Job] = {}
        self.requests: dict[str, Job] = {}
        self.mutex = asyncio.Lock()

    async def start(
        self, action: str, project_id: str, request_id: str,
        platform: str | None = None, version_name: str | None = None,
        build_number: int | None = None,
    ) -> dict:
        if action not in {"stores", "doctor", "verify", "build", "upload"}:
            raise ValueError("Unsupported FRK action.")
        if not re.fullmatch(r"[A-Za-z0-9_-]{8,128}", request_id):
            raise ValueError("Use a unique request_id of 8–128 letters, digits, underscores, or hyphens.")
        if action in {"build", "upload"}:
            if platform not in {"android", "ios"}:
                raise ValueError("Choose exactly one platform: android or ios.")
            if not isinstance(version_name, str) or not re.fullmatch(r"[0-9][0-9A-Za-z.+-]{0,63}", version_name):
                raise ValueError("Supply the version name explicitly, for example 1.2.0.")
            if type(build_number) is not int or not 1 <= build_number <= 2_100_000_000:
                raise ValueError("Supply an explicit build number between 1 and 2100000000.")
        signature = (action, project_id, platform, version_name, build_number)
        async with self.mutex:
            if request_id in self.requests:
                previous = self.requests[request_id]
                if previous.signature != signature:
                    raise ValueError("This request_id was already used for different arguments. No new job was started.")
                return previous.snapshot()
            if len(self.jobs) >= 200:
                raise ValueError("This session has reached 200 jobs. Start a new MCP session before starting more.")
            project = await self.client.project(project_id)
            if platform and platform not in project.get("platforms", []):
                raise ValueError("This project is not configured for that platform.")
            destination = None
            if action == "upload":
                destination = "TestFlight" if platform == "ios" else (project.get("android") or {}).get("track")
                if not destination or "production" in destination.lower():
                    raise ValueError("Only a configured testing destination is supported.")

            self.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            lock = os.fdopen(os.open(self.state_dir / "active.lock", os.O_CREAT | os.O_RDWR, 0o600), "r+")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                lock.close()
                raise ValueError("Another FRK MCP job is running. Wait for it or cancel it in its original AI connection.") from None
            job_id = uuid.uuid4().hex
            job = Job(job_id, request_id, signature, action, project_id, platform,
                      version_name, build_number, destination, self.state_dir / f"{job_id}.log", lock)
            self.jobs[job_id] = self.requests[request_id] = job
            # Pass the API-resolved absolute project path, never a shell command.
            job.task = asyncio.create_task(self._run(job, project["path"]))
            return job.snapshot()

    async def _run(self, job: Job, project_path: str) -> None:
        log = None
        try:
            log = os.fdopen(os.open(job.log_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "wb")
            arguments = ["store-versions"] if job.action == "stores" else [
                "run", "release" if job.action == "upload" else job.action,
            ]
            if job.platform:
                arguments += [f"--platform={job.platform}", f"--build-name={job.version_name}", f"--build-number={job.build_number}"]
            arguments += ["--", project_path]
            job.process = await asyncio.create_subprocess_exec(
                *self.client.command(*arguments), stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
                env=self.client.env, limit=1024 * 1024,
            )
            if job.cancel_requested:
                job.process.terminate()
            finished = []
            protocol_error = False
            bytes_written = 0
            async for line in job.process.stdout:
                if bytes_written < MAX_LOG_BYTES:
                    chunk = line[:MAX_LOG_BYTES - bytes_written]
                    log.write(chunk)
                    log.flush()
                    bytes_written += len(chunk)
                try:
                    event = json.loads(line)
                    if not isinstance(event, dict) or event.get("protocolVersion") != 1:
                        raise ValueError("Unexpected protocol")
                    if job.action == "stores":
                        if job.result is not None or event.get("error"):
                            protocol_error = True
                        else:
                            job.result = event
                    elif event.get("type") == "finished":
                        finished.append(event)
                    elif event.get("type") == "log":
                        job.log_events += 1
                    elif event.get("type") != "started":
                        protocol_error = True
                except (ValueError, UnicodeDecodeError):
                    protocol_error = True
            job.exit_code = await job.process.wait()
            success = (
                job.result is not None if job.action == "stores" else
                len(finished) == 1 and finished[0].get("success") is True and finished[0].get("exitCode") == 0
            )
            if job.cancel_requested:
                job.status = "cancelled"
                job.result = None
                job.message = "Local work stopped. Cancellation does not undo uploads already accepted by a store."
            elif job.exit_code == 0 and success and not protocol_error:
                job.status = "succeeded"
            else:
                job.status = "failed"
                job.message = "FRK did not report a successful completion. Inspect the private local log for details."
        except BaseException as exc:
            if job.process is not None:
                with anyio.CancelScope(shield=True):
                    await stop_process(job.process, drain_output=True)
                job.exit_code = job.process.returncode
            job.status = "cancelled" if job.cancel_requested or isinstance(exc, asyncio.CancelledError) else "failed"
            job.result = None
            job.message = "The local job was interrupted. Inspect the local log and store state before retrying an upload."
        finally:
            job.elapsed = time.monotonic() - job.started
            job.finished_at = timestamp()
            if log is not None:
                log.close()
            job.lock_file.close()

    def get(self, job_id: str) -> Job:
        if job_id not in self.jobs:
            raise ValueError("Unknown job ID in this MCP session. Use list_jobs; do not restart an upload blindly.")
        return self.jobs[job_id]

    async def cancel(self, job_id: str) -> dict:
        job = self.get(job_id)
        if job.task is not None and not job.task.done():
            job.cancel_requested = True
            job.status = "cancelling"
            if job.process is not None:
                await stop_process(job.process)
            await job.task
        return job.snapshot()

    async def close(self) -> None:
        for job in list(self.jobs.values()):
            await self.cancel(job.id)


def create_server(executable: Path, state_dir: Path) -> MCPServer:
    client = FRKClient(executable)
    jobs = Jobs(client, state_dir)

    @asynccontextmanager
    async def lifespan(server):
        await client.check_compatibility()
        try:
            yield
        finally:
            with anyio.CancelScope(shield=True):
                await jobs.close()

    server = MCPServer("Flutter Release Kit", version="0.1.0", instructions=INSTRUCTIONS, lifespan=lifespan)

    @server.tool(annotations=READ_ONLY)
    async def list_projects() -> dict[str, Any]:
        """List registered Flutter apps, exact project IDs, platforms, signing readiness, versions, and artifact paths."""
        return await client.document("projects", timeout=180)

    @server.tool(annotations=READ_ONLY)
    async def inspect_project(project_id: str) -> dict[str, Any]:
        """Read one registered app and its signing/setup issues. Does not repair or change configuration."""
        project = await client.project(project_id)
        return {"project": project, "setup": await client.document("setup", "--", project["path"])}

    @server.tool(annotations=START_JOB)
    async def start_check(project_id: str, check: Literal["stores", "doctor", "tests"], request_id: RequestID) -> dict[str, Any]:
        """Start a check and return a job ID. stores reads store versions; doctor checks release readiness; tests runs analysis/tests.

        Nothing is uploaded. Store reads can take minutes. Poll get_job. Reuse request_id only when retrying this same request.
        """
        return await jobs.start("verify" if check == "tests" else check, project_id, request_id)

    @server.tool(annotations=START_JOB)
    async def start_build(project_id: str, platform: Platform, version_name: VersionName,
                          build_number: BuildNumber, request_id: RequestID) -> dict[str, Any]:
        """Build one app/platform locally with an explicit user-chosen version and build number. No upload.

        Returns a job ID, not a completed build. Poll get_job. Reuse request_id on retries to avoid duplicate execution.
        """
        return await jobs.start("build", project_id, request_id, platform, version_name, build_number)

    @server.tool(annotations=START_JOB)
    async def start_upload(project_id: str, platform: Platform, version_name: VersionName,
                           build_number: BuildNumber, request_id: RequestID) -> dict[str, Any]:
        """Build, test, and UPLOAD one app to its configured Google Play testing track or TestFlight.

        Requires the user's explicit upload request for this project/platform/version. Inspect project and store versions first.
        Does not skip tests, reuse an old artifact, edit versions/configuration, or publish to production.
        Poll get_job; an accepted job is not upload success. Reuse request_id when retrying a start call in this session.
        """
        return await jobs.start("upload", project_id, request_id, platform, version_name, build_number)

    @server.tool(annotations=READ_ONLY)
    async def get_job(job_id: str) -> dict[str, Any]:
        """Read progress/result for this session's job. Poll every 5–10 seconds while running/cancelling.

        Terminal states: succeeded, failed, cancelled. Raw output stays in localLogPath and is not exposed to the model.
        A successful stores check can still report an unavailable store; inspect each platform's status.
        """
        return jobs.get(job_id).snapshot()

    @server.tool(annotations=READ_ONLY)
    async def list_jobs() -> dict[str, Any]:
        """List jobs in this MCP session, most recent first. Jobs do not survive a server restart."""
        return {"jobs": [job.snapshot() for job in reversed(list(jobs.jobs.values()))]}

    @server.tool(annotations=ToolAnnotations(read_only_hint=False, destructive_hint=False, idempotent_hint=True, open_world_hint=False))
    async def cancel_job(job_id: str) -> dict[str, Any]:
        """Stop a local job and its FRK helpers. Does not undo an upload that the store already accepted."""
        return await jobs.cancel(job_id)

    return server


def main() -> None:
    parser = argparse.ArgumentParser(description="Flutter Release Kit MCP server (local stdio only)")
    parser.add_argument("--frk", type=Path, default=KIT_ROOT / "bin/frk", help="FRK CLI script")
    parser.add_argument("--state-dir", type=Path, help="Private MCP log/lock directory; defaults to the FRK vault's mcp directory")
    args = parser.parse_args()
    state_dir = args.state_dir or Path(os.environ.get("FLUTTER_RELEASE_HOME", "~/.flutter-release")).expanduser() / "mcp"

    def interrupt(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    try:
        create_server(args.frk, state_dir).run(transport="stdio")
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
