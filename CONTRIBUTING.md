# Contributing

## What belongs where

`bin/frk` owns the command-line interface and the versioned machine API; it is
the only entry point other tools are expected to call. `fastlane/Fastfile` owns
all release logic — build, validation, signing, and tester-release behavior live
there and nowhere else. `desktop/ReleaseKitApp` is a client: it renders state and
invokes `frk`, and never reimplements release logic. `templates/` holds the small
non-secret files generated into each onboarded app. Start with the
[README](README.md) and the [machine API contract](docs/MACHINE_API.md) for how
the pieces are used.

## Durable invariants

These hold across every change. Breaking one is a defect, not a trade-off.

- `bin/frk` uses the Python standard library only. No third-party import at
  runtime.
- `fastlane/Fastfile` is the single source of build, validation, and
  tester-release behavior.
- The desktop app is a client. Release logic stays in the CLI.
- Secrets and signing material live under `~/.flutter-release`, never in Git and
  never in an API response.
- Version numbers are never auto-incremented.
- Uploads target Play testing tracks and TestFlight only, never production.
- The Store Listing Manager and the First Release Assistant were deliberately
  removed and are out of scope. Do not reintroduce them, their CLI endpoints,
  their Fastlane lanes, or their Swift models.

## Where does a change go

| Change | Files to touch |
|---|---|
| Release, build, or signing behavior | `fastlane/Fastfile` |
| App-specific option | `fastlane/release_kit.yml` in that app, with a backward-compatible default |
| New generated app file | `templates/`, plus the onboarding writer in `bin/frk` |
| CLI command or flag | `bin/frk` |
| Machine API field | `bin/frk` + `docs/MACHINE_API.md` + `desktop/ReleaseKitApp/Sources/Models.swift`, in one commit |
| Desktop UI | `desktop/ReleaseKitApp/Sources/` |

The machine API row is the one that bites. There is no schema and no codegen,
but the **key names** are pinned across Python and Swift by a golden fixture,
`tests/fixtures/api_v1_keys.json`. `tests/test_api_contract.py` asserts the CLI
still emits exactly those names; the `...FieldTheAppDecodesIsEmittedByTheCLI`
tests in `desktop/ReleaseKitApp/Tests/ReleaseKitAppTests.swift` check the same
fixture against the app's models in both directions — a field the app decodes
but the CLI dropped, and a field the CLI emits that no Swift model reads any
more. Adding a CLI key is a compatible protocol v1 change, so it has to be
admitted deliberately through the commented `cliKeysTheAppIntentionallyIgnores`
allow-list.

What the fixture does **not** pin: value types, enum spellings, semantics, and
`docs/MACHINE_API.md`, which no test reads. Renaming a status string or changing
a field's type passes every check and breaks the app at runtime. Change all
three files together, and regenerate the fixture in the same commit.

## Running the checks

A `Makefile` at the repository root wraps the checks:

```bash
make test      # CLI tests plus the Ruby and shell syntax checks
make desktop   # Swift package tests only
make check     # both
```

Use `make check` before handing work off. `make test` skips the Swift half and
will pass while the desktop app is broken.

`make check` covers the macOS half of CI. Two CI jobs need tools the `Makefile`
does not assume, so reproduce them by hand when a change could affect them:

```bash
pipx run ruff==0.16.2 check bin/frk tests/     # lint job; config in ruff.toml
/usr/bin/python3 -m unittest discover -s tests # the 3.9 floor CI also enforces
```

The floor is real: `str.removeprefix` in `bin/frk` requires Python 3.9, and
macOS ships exactly 3.9 at `/usr/bin/python3`.

## Test harness gotcha

`tests/test_frk.py:32-34` loads `bin/frk` through `SourceFileLoader` as a module
named `frk`, because `bin/frk` is a script rather than an importable package.

The vault is sandboxed by an environment variable, not by rebinding globals.
`bin/frk` derives every path below the private vault from one accessor:

```python
def credentials_dir() -> Path:
    return Path(os.environ.get("FLUTTER_RELEASE_HOME", "~/.flutter-release")).expanduser()
```

`registry_path()` and `signing_dir()` derive from it, and nothing else in
`bin/frk` reads the vault location. These are **functions, not constants**, so
`FLUTTER_RELEASE_HOME` is re-read on every call.

The harness sets that variable at two levels. `tests/test_frk.py:28-30` points
it at one throwaway `TemporaryDirectory` before `exec_module` runs, so the real
`~/.flutter-release` is unreachable for the whole test process; `setUp` then
narrows it per test with `patch.dict(os.environ, ...)`. `tests/test_api_contract.py`
does the same. `test_vault_paths_are_read_from_the_environment_on_every_call`
pins the seam itself.

The warning here is now much weaker than it used to be, and that is the point:
a new vault path **cannot** silently escape the sandbox, because there is no
list of derived constants to keep in step. Add `credentials_dir() / "whatever"`
wherever you need it and it is sandboxed by construction. Three things still
break it, all of them louder than the old failure mode:

- **Reading the vault location from anywhere but `credentials_dir()`** — a bare
  `Path.home() / ".flutter-release"`, or a second `os.environ.get` — bypasses
  the seam and reaches live credentials. Route it through the accessor.
- **Freezing a path into a module-level constant** (`SIGNING = signing_dir()`
  at module scope) evaluates once at import. That still lands inside the
  process-wide sandbox, but it ignores `setUp`'s per-test directory, so state
  leaks between tests. Call the accessor inside the function that needs it.
- **Adding a memo that outlives a test.** Two functions cache on themselves:
  `distribution_identities.cache` and `find_keytool.cache`. `setUp` resets both
  to `None`, and `tests/test_api_contract.py` sets the identities cache to `[]`
  to keep `security find-identity` away from the real keychain. A new
  function-attribute cache that `setUp` does not reset leaks across tests.

## One surprising coupling

`frk status` prints the shared Fastfile's physical line count:

```text
  ok    shared Fastfile (1450 lines)
```

So **any** edit to `fastlane/Fastfile` — including adding a comment — changes
`frk status` output. Expect it when a change to the Fastfile makes an output
comparison fail for no apparent reason.

## Version

`frk --version` reports the CLI version. The machine protocol version is
reported only by `frk api capabilities`, which is also where a client discovers
the supported protocol range. Do not restate either number in prose; a
hardcoded version drifts the moment the CLI is bumped. Worked JSON examples in
`docs/MACHINE_API.md` are the one exception — they show a whole document, and a
placeholder there would misrepresent the shape.
