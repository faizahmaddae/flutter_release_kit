# AI access through MCP

The optional **Flutter Release Kit MCP** server exposes eight local tools to
Claude Desktop, Claude Code, Codex, and other stdio MCP clients. It calls the
existing `frk api`; Fastlane remains the only implementation of builds and
uploads. Installing it does not edit any Flutter project's settings or signing.

The adapter uses the official [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk)
in its own environment. The normal FRK CLI still needs only Python's standard
library. Both modern MCP discovery and older initialization clients are tested.

## Install

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) if necessary.
From this repository:

```bash
uv sync --project integrations/mcp --locked
```

The adapter requires Python 3.10 or newer; uv can provision a compatible Python.
FRK must support machine protocol v1 and CLI 0.8.1 or newer, because earlier
versions do not reliably stop nested helpers on cancellation. No credentials
are needed beyond those already configured in Flutter Release Kit.

## Connect your AI

Use absolute paths. Replace `/absolute/path/flutter_release_kit` with this
checkout's location. After syncing, the server command is:

```text
/absolute/path/flutter_release_kit/integrations/mcp/.venv/bin/python
```

Its single argument is:

```text
/absolute/path/flutter_release_kit/integrations/mcp/frk_mcp.py
```

### Claude Code and Codex

From the repository root:

```bash
FRK_CHECKOUT="$(pwd -P)"
claude mcp add --transport stdio --scope user flutter-release-kit -- \
  "$FRK_CHECKOUT/integrations/mcp/.venv/bin/python" \
  "$FRK_CHECKOUT/integrations/mcp/frk_mcp.py"

codex mcp add flutter-release-kit -- \
  "$FRK_CHECKOUT/integrations/mcp/.venv/bin/python" \
  "$FRK_CHECKOUT/integrations/mcp/frk_mcp.py"
```

If that name already exists, inspect it before replacing it. Reload MCP servers
or start a new AI session after configuration. In clients that provide it,
`/mcp` shows connection status and available tools.

### Claude Desktop

Merge this entry into `mcpServers` in
`~/Library/Application Support/Claude/claude_desktop_config.json`, keeping any
existing entries and preferences:

```json
{
  "mcpServers": {
    "flutter-release-kit": {
      "command": "/absolute/path/flutter_release_kit/integrations/mcp/.venv/bin/python",
      "args": ["/absolute/path/flutter_release_kit/integrations/mcp/frk_mcp.py"]
    }
  }
}
```

Restart Claude Desktop to load it. A desktop client with an MCP server settings
screen can use the same command and argument directly.

### ChatGPT or Claude in the browser

This first version is **local stdio only**. Adding it to desktop/CLI settings
does not connect a browser chat. Browser clients need a remote MCP connection
to this machine, with authentication. ChatGPT also documents a
[private MCP tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels).
No public server, open network port, tunnel, or cloud credential is installed
by this adapter. The Mac must remain available while it runs local builds.

## Tools and example requests

| Tool | Behavior |
|---|---|
| `list_projects` | Read managed project IDs, versions, signing readiness, and artifact paths |
| `inspect_project` | Read one project's configuration and setup issues |
| `start_check` | Start a store-version query, doctor check, or analysis/tests |
| `start_build` | Build one platform locally with explicit version and build number |
| `start_upload` | Test, build, and upload to the configured Play testing track or TestFlight |
| `get_job` | Read progress and final result; store queries include each platform's report |
| `list_jobs` | Recover job IDs from the current MCP server session |
| `cancel_job` | Stop local work and its FRK helpers |

Examples:

- “Show my Flutter Release Kit projects and which ones need signing setup.”
- “Check the store versions for amirza. Do not build or upload anything.”
- “Build amirza for Android with version 1.0.5 and build number 6, locally only.”
- “Upload amirza for iOS, version 1.0.5, build 6, to TestFlight.”
- “What is the status of that upload?”

Version values are examples, not recommendations. The user chooses the project,
platform, version, and build number. The server never increments versions,
changes testing tracks, skips tests, or uploads a pre-existing artifact.

## Jobs, retries, and local output

Checks/builds/uploads return immediately with a `jobId`. Poll `get_job` every
5–10 seconds until `succeeded`, `failed`, or `cancelled`; starting a job is not
proof of completion. Store-query success means the query completed, so also
inspect each store's `status` before making a version decision.

Pass a unique `request_id` for each intended operation. Retrying the same start
with the same ID and arguments in the **same MCP session** returns the same job,
including after it finishes. Reusing the ID with different arguments is rejected.
This is not a durable cross-session deduplication service. After a connection
restart, inspect the store before retrying any upload whose outcome is uncertain.

One long job runs at a time across MCP server processes sharing the same vault.
Other starts return a busy error without being queued. Read tools still work.
The native FRK app and direct CLI do not share this MCP lock: finish their jobs
before asking an AI to start another build/upload. MCP jobs are shown through
the AI tools, not the native app's Activity panel.

Jobs and request IDs live in memory (up to 200 jobs per session). Closing the
MCP server cancels active work; it does not run as a background daemon. Stopping
local work cannot undo an upload already accepted by a store.

Raw toolchain output is **not returned to the AI**, since Flutter tests or build
scripts can print arbitrary app-specific secrets. `get_job` returns progress,
exit status, and a `localLogPath` under `~/.flutter-release/mcp/`. Each log is
private (0600), capped at 10 MiB, and retained locally after the session ends for
manual diagnosis. A full log can be truncated at the cap. Remove old `.log`
files when no longer needed; do not share them without reviewing their contents.

## Configuration and boundaries

- Only registered projects are accepted. Project discovery does not scan disk.
  Use the exact ID from `list_projects`; ambiguous duplicate IDs are rejected.
- No generic shell, file reader, credential editor, signing repair, enrollment,
  removal, settings mutation, or production publishing tool is exposed.
- Upload tools are marked as actions, not read-only tools. The MCP host's tool
  permissions still apply; tool descriptions are not an authorization mechanism.
- Existing configured signing and store credentials are used by FRK locally.
  They are not requested as tool arguments or returned as credential contents.
- `--frk /path/to/bin/frk` selects a different compatible CLI checkout.
- `FLUTTER_RELEASE_HOME` selects the same alternate vault as the CLI. The MCP
  log/lock directory defaults to its `mcp` subdirectory. `--state-dir` overrides
  this for isolated tests; clients that should serialize jobs must share it.
- GUI clients get conventional Flutter/Homebrew/POSIX tool paths. For custom
  installations, add a `PATH` entry to that client's MCP environment.

## Development checks

```bash
make mcp
make check
```

The MCP tests use a fake CLI and a temporary vault, including for simulated
uploads. Real CLI checks use empty or synthetic temporary registries. No store
upload or live signing repair is performed by these checks.
