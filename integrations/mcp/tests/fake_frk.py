"""Test-only FRK substitute. Never imports FRK, Fastlane, or live credentials."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def emit(**values):
    print(json.dumps({"protocolVersion": 1, "cliVersion": "0.8.1", **values}), flush=True)


args = sys.argv[2:]
mode = os.environ.get("FAKE_FRK_MODE", "success")
project = {
    "id": "test-app", "path": os.environ["FAKE_PROJECT_PATH"],
    "exists": True, "onboarded": True, "platforms": ["android", "ios"],
    "android": {"track": "production" if mode == "production" else "internal"},
}
if mode == "missing":
    project["exists"] = False
if mode == "android_only":
    project["platforms"] = ["android"]
if mode == "no_android_config":
    project["android"] = None
command = args[0]
if command == "capabilities":
    print(json.dumps({
        "protocolVersion": 2 if mode == "protocol" else 1,
        "cliVersion": "0.8.0" if mode == "old" else "0.8.1",
        "capabilities": {"actions": ["build", "release", "doctor", "verify"]},
    }), flush=True)
elif command == "projects":
    emit(projects=[project])
elif command == "project":
    if args[-1] not in {"test-app", project["path"]}:
        emit(error={"code": "project_not_found", "message": "PRIVATE_SENTINEL"})
        sys.exit(1)
    emit(project=project)
elif command == "setup":
    emit(projectId="test-app", android={"signingReady": True}, ios={"signingReady": True})
elif command in {"store-versions", "run"}:
    with Path(os.environ["FAKE_CALLS_PATH"]).open("a") as calls:
        calls.write(json.dumps(args) + "\n")
    if mode == "slow":
        # Like frk, own a separate helper group and stop it on cancellation.
        helper = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)

        def cancel(signum, frame):
            os.killpg(helper.pid, signal.SIGTERM)
            helper.wait()
            emit(type="finished", success=True, exitCode=0)
            sys.exit(0)  # Cancellation must stay cancellation even on exit 0.

        signal.signal(signal.SIGTERM, cancel)
        Path(os.environ["FAKE_SERVER_PID"]).write_text(str(os.getppid()))
        Path(os.environ["FAKE_HELPER_PID"]).write_text(str(helper.pid))
        emit(type="started")
        time.sleep(60)
    elif command == "store-versions":
        emit(project="test-app", android={"status": "ok", "latestVersionCode": 41}, ios={"status": "unavailable"})
    else:
        emit(type="started")
        emit(type="log", message="PRIVATE_SENTINEL password=not-for-the-model -----BEGIN PRIVATE KEY-----")
        if mode == "raw":
            print("PRIVATE_SENTINEL unexpected raw output", flush=True)
        if mode in {"oversized", "oversized_slow"}:
            print("x" * (8 * 1024 * 1024), flush=True)
            if mode == "oversized_slow":
                time.sleep(60)
        if mode == "error":
            emit(type="error", code="stream_failed", message="PRIVATE_SENTINEL")
        if mode != "missing_finished":
            emit(type="finished", success=mode != "failure", exitCode=1 if mode == "failure" else 0)
        if mode == "duplicate_finished":
            emit(type="finished", success=True, exitCode=0)
        sys.exit(1 if mode in {"failure", "bad_exit"} else 0)
else:
    raise SystemExit("Unexpected fake command")
