# FRK machine API v1

The machine API is the compatibility boundary for desktop applications and
other local tooling. Human-readable CLI output is not an API and may change.

## Discovery

```bash
frk api capabilities
frk api projects
frk api project example_app
frk api setup example_app
frk api credentials
frk api store-versions example_app
frk api build-args example_app
```

Each command writes one compact JSON document to stdout. `capabilities` reports
the supported desktop protocol range and must be checked before other calls.
All of these are local except `store-versions`, which talks to the stores; it
has its own section below. `set-build-args` is the one write among the local
commands and has its own section too, under "Extra build flags".

`api credentials` reports readiness, public account labels, and resolved paths;
it never returns private-key contents. Desktop clients configure one store with:

```bash
frk api configure-credentials google-play --file /path/to/service-account.json
frk api configure-credentials app-store --file /path/to/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX --issuer-id xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

The source is validated and preserved. FRK copies it into the private vault,
updates `credentials.env` atomically, and requires `--force` before replacing a
different vault copy.

## Store version report

```bash
frk api store-versions example_app
```

Google Play and App Store Connect count uploads independently, so the two build
numbers drift apart and `pubspec.yaml` — which holds a single `+N` — cannot
describe both. This command reports what each store already holds, before
anything is built, so a duplicate build number is caught in the client instead
of twenty minutes later in a rejected upload.

```json
{"protocolVersion":1,"cliVersion":"0.7.0","project":"example_app","checkedAt":"2026-08-08T09:41:07.412Z","android":{"status":"ok","detail":"Google Play's highest known version code is 38 and the configured 'internal' track is at 38.","track":"internal","latestVersionCode":38,"latestVersionName":"2.0.9","tracks":[{"track":"internal","versionCode":38,"versionName":"2.0.9"}]},"ios":{"status":"ok","detail":"TestFlight's newest upload is build 41 of version 2.1.0, state PROCESSING; the latest App Store release is 2.0.8.","latestAppStoreVersion":"2.0.8","builds":[{"version":"2.1.0","build":41,"state":"PROCESSING"}]}}
```

### Facts only — no suggested next version

There is no `next`, `suggested`, `recommended`, or `increment` field in this
document, at any nesting level, and adding one is a breaking change to the
product rather than a helpful extra. FRK never chooses a version number: the
number that ships is the one a human typed or clicked. A client is expected to
compute a candidate from these facts and present it as something the user must
accept — the computation is a client concern precisely because the user has to
own the result. A field here would move that decision into the CLI and make it
look already made.

### Read-only

Nothing is built, uploaded, promoted, or deleted, in either store or in the
project directory. The lane runs with no options, so there is no argument that
could make it act. The one write-shaped call is Google Play's `insert_edit`,
which opens a scratch edit and abandons it in the same breath: the Publishing
API offers no other way to read a track, and it is the same probe
`check_credentials` has always used. Nothing is committed, so no edit survives
the call.

### It reaches the network, so it is slow

`bin/frk` cannot query the stores itself — signing a Play OAuth assertion needs
RS256, which the Python standard library does not provide — so the whole store
conversation happens in `fastlane store_versions`, behind Ruby, Bundler, and
fastlane start-up. The lane budgets 60 seconds per store and queries two, so a
slow-but-working answer can take well over two minutes. `frk` stops the child
after 300 seconds of wall clock measured from spawn — a total deadline, not an
inactivity timer and not a query budget. A child still printing output at 300
seconds is stopped exactly like a wedged one, which is why the error says the
lane "did not finish" rather than that it stalled. The per-store budget belongs
to the lane, which reports a slow store as `unavailable` while the other store
still answers; only the lane can attribute a timeout to one store.

Clients should call this behind a spinner and cancel by terminating the `frk`
process.

Cancellation behaves differently here than in `api run`, and clients need to
know which one they are using. `api run` installs signal handlers that pass a
termination on to its child's process group. `store-versions` does **not**:
fastlane is started in its own session, so killing `frk` returns control to the
client immediately but leaves the lane running until it finishes its own
per-store budget. Nothing is at risk — the lane is read-only and its output is
discarded once nobody is reading it — but a client that cancels and instantly
retries can have two lanes querying the stores at once. Debounce the retry.
`frk` reaps the child itself only on its own 300-second timeout.

### Statuses

`android` and `ios` always carry `status` and `detail`, whatever happened. A
platform that is not configured is `"unconfigured"`, never a missing key, so a
client never has to distinguish "absent" from "unknown".

| `status` | Meaning | Was the store contacted? |
|---|---|---|
| `ok` | The store answered. The numbers in this object are what it holds. | Yes |
| `unconfigured` | The project does not ask for this platform — it is not in `platforms` in `fastlane/release_kit.yml` — or that platform's section is unusable. | No |
| `no_credentials` | The platform is configured, but no usable store credential was found. | No |
| `unavailable` | The store was asked and did not produce a usable answer: a timeout, an API error, denied access, or no such app. | Attempted |

`unavailable` is also the fail-closed value: a status `frk` does not recognise
is reported as `unavailable` and never passed through.

`detail` is one human sentence, always present, safe to display. It is never a
raw store error: text that FRK did not write is redacted in the lane and again
in `frk`, first line only, and capped at 400 characters.

The two stores are independent. One can be `ok` while the other is
`unavailable`, and the command still exits 0 — a half-answer is more useful
than none, and `status` says which half.

`ios` is itself two reads — the TestFlight build list and the App Store release
list — and App Store Connect can serve one and refuse the other. When that
happens `status` is `unavailable` for the whole platform (fail closed) but the
half that answered is still populated, and `detail` has one clause per half
naming which one could not be read. So on `unavailable`, treat a populated
field as real and a `null` or `[]` field as unknown, and show `detail`.

### Reading the numbers

Every numeric field is a number or `null`. `null` means unknown; `0` is never
used as a stand-in, and a number never arrives as a string.

**`status: "ok"` with `latestVersionCode: null` is a real, useful answer**: the
store answered and holds nothing yet, so any version code is free. That is a
different fact from `unavailable`, and a client that conflates them will tell a
user with an established app that they may reuse build 1.

| Field | Meaning |
|---|---|
| `checkedAt` | When the stores were read. UTC ISO-8601 with milliseconds — but see the note below on the two spellings. |
| `project` | The managed project's name, taken from FRK's own registry and config — never from the lane's output. |
| `android.track` | The Play testing track configured for this project. `null` when it could not be read. Track ids are not limited to Play's built-in lowercase names: a closed-testing track is named in the Console (`QA`, `Closed Beta`) and form-factor tracks are prefixed (`wear:production`). |
| `android.latestVersionCode` | The highest version code Play knows anywhere in this app, including uploaded bundles that were never released. This is the number Play compares against on upload; it is not necessarily on the configured track. |
| `android.latestVersionName` | The version name belonging to that code, or `null` when the code came from a bundle with no track release. |
| `android.tracks` | Per-track state, configured track first, then the rest in a stable order. Entries without both a track and a code are dropped. At most 16. |
| `ios.latestAppStoreVersion` | The highest version released on the App Store. `null` does **not** mean "never shipped" on its own — read `ios.status` first. It means never shipped only when `status` is `ok`; when `status` is `unavailable` the release list was not read, and `detail` says which half failed. |
| `ios.builds` | The most recent TestFlight builds, newest upload first, at most 10. Includes builds still `PROCESSING`, which is deliberate: a build that finished uploading two minutes ago is already taken. |
| `ios.builds[].build` | The build number, or `null` when `CFBundleVersion` is not a plain integer (Apple accepts `"1.2.3"`). Apple scopes build numbers to the version string, which is why the list is returned rather than a single latest build. |

`checkedAt` has two spellings and a client must parse both. The normal value is
the lane's own moment and ends in `Z` (`2026-08-08T09:41:07.412Z`). When the
lane's timestamp is missing or malformed, `frk` substitutes its own, which is
the same instant written with a numeric offset (`2026-08-08T09:41:07.412+00:00`).
Parse it as ISO-8601; matching on a trailing `Z` will fail on the fallback.

### Failures

Every failure below answers with the standard error envelope described under
[Errors](#errors) and exits 1. The envelope carries no `android` or `ios` key
at all, which is the point: a client can never read "the store holds nothing"
out of a run that never reached a store.

| Code | Meaning |
|---|---|
| `project_not_found` | The named project or path is not in the opt-in registry |
| `project_unavailable` | The registered project directory no longer exists |
| `project_not_onboarded` | The project has no shared Fastfile import or release configuration; run `frk onboard` first |
| `fastlane_unavailable` | fastlane is not on `PATH`, or the child process could not be started |
| `store_query_timed_out` | The lane did not finish within 300 seconds of being started and was stopped. No store version was read |
| `store_query_failed` | The lane produced no report line: fastlane crashed, died early, or the shared Fastfile predates the lane |
| `store_report_unreadable` | A report line arrived that this CLI cannot read as a JSON object — the lane and the CLI disagree about the format |

The 300 seconds is a **total deadline measured from spawn**, not an inactivity
timer: a run that is still printing output is stopped at 300 seconds exactly
like a wedged one. It is set far above the honest worst case (the lane budgets
60 seconds per store and queries two, behind ruby, bundler and fastlane
start-up), so reaching it means something is wrong rather than merely slow —
but on a cold machine a working run can still reach it, and retrying is the
right first response.

`message` never quotes the child's output. It is unbounded and unredacted, and
this document gets logged; the message names the command to run by hand
instead.

A non-zero exit from fastlane accompanied by a complete report is **not** a
failure. The lane never raises, always emits its report, and carries each
platform's own status, so a wrapper exiting non-zero afterwards must not turn a
complete answer into "could not check". `frk` returns the document and exits 0.

## Extra build flags

```bash
frk api build-args example_app
frk api set-build-args example_app --platform android --arg "--dart-define=A=1" --arg "--dart-define=B=2"
frk api set-build-args example_app --platform android
```

Flags appended to every `flutter build` this project runs, for `--dart-define`
and similar project-specific flags FRK has no opinion about. `shared` applies
to every platform the app ships; each platform also has its own list, for a
flag one platform needs and the other must never see — Android and iOS build
independently, and a flag scoped to the wrong one is not always a build error,
sometimes a silent behavior difference, which is worse. `effective` is `shared`
followed by that platform's own list, in the order actually passed to
`flutter build`.

```json
{"protocolVersion":1,"cliVersion":"0.7.0","shared":["--dart-define=COMMON=1"],"android":{"configured":true,"own":["--dart-define=A=1"],"effective":["--dart-define=COMMON=1","--dart-define=A=1"]},"ios":{"configured":true,"own":[],"effective":["--dart-define=COMMON=1"]}}
```

`build-args` is read-only. `set-build-args` replaces the named platform's
*own* list — never `shared`, which stays a hand-edited setting in
`fastlane/release_kit.yml` — and returns the same document `build-args` would,
reflecting the change. Omitting every `--arg` clears that platform's list. Both
edit only the one `extra_build_args:` block under `android:`/`ios:` in the
project's `release_kit.yml`; every other line, including comments and the
other platform's section, is preserved byte for byte. Local and instant: no
network, no fastlane, no build.

A platform not in `platforms` reports `"configured": false` with empty lists,
and `set-build-args` for that platform is `invalid_platform` rather than
silently writing a section the app does not use.

## Google Play track

```bash
frk api set-track example_app --track alpha
```

Changes which Google Play testing track this project's Android uploads go
to: `internal` (the default), `alpha`, or `beta` — Play Console's own
current names for these are Internal testing, Closed testing, and Open
testing. `production` is not a valid value here or anywhere else in FRK;
the Fastfile refuses it at upload time regardless of what reaches it.

There is no read-only counterpart: the current track is already part of
every project record `api project`/`api projects` return, at
`android.track`. `set-track` returns that same record — read back from the
file rather than assumed — so a client can update its state from one write
instead of reloading the whole fleet.

```json
{"protocolVersion":1,"cliVersion":"0.8.0","project":{"id":"example_app","name":"example_app","path":"/Users/dev/flutter/example_app","exists":true,"onboarded":true,"state":"ready","platforms":["android","ios"],"version":"1.2.0+42","buildName":"1.2.0","buildNumber":42,"android":{"packageId":"com.example.app","signingReady":true,"track":"alpha"},"ios":{"bundleId":"com.example.app","teamId":"ABCDE12345","profilePath":"/Users/dev/.flutter-release/asc/profile.mobileprovision","profileReady":true,"distributionIdentityReady":true,"signingReady":true},"artifacts":{"androidAab":null,"iosIpa":null},"addedAt":"2026-01-15T10:00:00+00:00"}}
```

Edits only the one `track:` line under `android:` in the project's
`release_kit.yml`; every other line is preserved byte for byte. Local and
instant: no network, no fastlane, no build.

A project not configured for Android is `invalid_platform`.

## Streaming actions

```bash
frk api run doctor example_app
frk api run build example_app --platform android \
  --build-name 2.1.0 --build-number 43
frk api run validate example_app --platform android \
  --build-name 2.1.0 --build-number 43
frk api run release example_app --platform ios \
  --build-name 2.1.0 --build-number 43
```

The process writes one JSON object per line. Event types are `started`, `log`,
`error`, and `finished`. Clients must use the final event and process exit code
to determine success. Terminating the API process also terminates its active
child process group.

Supported actions in protocol v1 are:

```text
onboard, doctor, verify, build, validate, release,
signing-audit, signing-import, signing-link, ios-setup-signing, status, forget
```

`api setup` is read-only and returns structured Android/iOS readiness without
credential values. Android status is ordered around the real release chain:
`key.properties`, its referenced keystore, credential validation, Gradle
wiring, Git safety, and optional vault management. iOS status reports Xcode
identity, a local distribution identity, the decoded app profile and expiry,
certificate/profile compatibility, ExportOptions, and automation access.
`signing-import` can accept `--properties`, `--keystore`, `--force`, and
`--link`; the source is preserved and secrets never appear in events.
`forget` removes only the selected entry from FRK's private project registry;
it never deletes or edits the Flutter project.
`ios-setup-signing` may change Apple Developer signing state and clients must
obtain explicit confirmation immediately before running it.

`validate` is Android-only. It sends the AAB to Google Play's validation API,
but does not create a release on any track. This is a remote store operation,
not a local-only check.

### Action flags

The project argument is optional in the parser, but every action except `status`
fails with `invalid_request` when it is omitted. Flags that do not apply to the
selected action are accepted by the parser and ignored.

| Flag | Actions | Purpose |
|---|---|---|
| `--platform android\|ios\|all` | `build`, `validate`, `release` | Required; `validate` accepts `android` only |
| `--build-name` | `build`, `validate`, `release` | Marketing version |
| `--build-number` | `build`, `validate`, `release` | Store build number/versionCode |
| `--skip-tests` | `release` | Skip the pre-release test run |
| `--skip-build` | `release` | Upload the artifact already on disk |
| `--name` | `onboard` | Stable managed-project name |
| `--platforms` | `onboard` | `android`, `ios`, or `android,ios` |
| `--android-package` | `onboard` | Explicit Android applicationId |
| `--ios-bundle-id` | `onboard` | Explicit iOS bundle identifier |
| `--ios-team-id` | `onboard` | Explicit Apple developer team id |
| `--track internal\|alpha\|beta` | `onboard` | Play testing track |
| `--dry-run` | `onboard` | Preview only |
| `--properties` | `signing-import` | Source `key.properties` |
| `--keystore` | `signing-import` | Selected `.jks` or `.keystore` |
| `--force` | `signing-import` | Replace a different vault copy |
| `--link` | `signing-import` | Link the project after copying |

## Event fields

Every event carries `protocolVersion`, `cliVersion`, `type`, and `timestamp`
(UTC ISO-8601 with milliseconds). The remaining fields depend on the type:

| Type | Additional fields |
|---|---|
| `started` | `action`, `project`, `platform` |
| `log` | `action`, `sequence`, `stream`, `message` |
| `error` | `action`, `code`, `message` |
| `finished` | `action`, `success`, `exitCode`, `durationSeconds` |

`action` is the requested action name and is present on all four types.
`project` is the project argument exactly as supplied, and is `null` only when
the argument was omitted. The parser allows it to be omitted for every action,
but only `status` runs without one; every other action then fails with
`invalid_request`.
`platform` is `null` unless `--platform` was passed. `sequence` starts at 1 and
counts emitted `log` events, not source lines: blank lines are dropped and ANSI
escapes are removed from `message`. `stream` is always `combined`, because the
child's stdout and stderr are merged. `exitCode` is the underlying command's
exit status, and `success` is `exitCode == 0`.

A successful or failed run emits `started`, then zero or more `log` events,
then `finished`. A request that cannot be mapped to a command emits `error`
with code `invalid_request` and then `finished`, and **no `started` event at
all**. A client that waits for `started` before showing progress or before
accepting a terminal event will hang on every rejected request.

An action that runs to completion and exits non-zero emits no `error` event:
that failure belongs to the underlying command and is reported only by
`finished.success` and `finished.exitCode`.

There is one exception, and it is not the command failing — it is the stream
itself failing. If reading the child's output raises (an I/O error, or a signal
delivered to `frk`), the run emits `error` with code `stream_failed` after
`started`, kills the child's process group, and then emits `finished` with
`success: false`. So a client must accept an `error` event at any point after
`started`, not only in place of one.

## Errors

The single-document commands report a handled failure by replacing the payload
with an `error` object:

```json
{"protocolVersion":1,"cliVersion":"0.7.0","error":{"code":"project_not_found","message":"..."}}
```

In the streaming protocol the same information arrives as an `error` event
whose `code` and `message` are top-level event fields, not a nested object.

| Code | Emitted by | Meaning |
|---|---|---|
| `project_not_found` | `api project`, `api setup`, `api store-versions`, `api build-args`, `api set-build-args`, `api set-track` | The named project or path is not in the opt-in registry |
| `invalid_credentials` | `api configure-credentials` | The source file is missing or failed validation, or a different vault copy exists and `--force` was not supplied |
| `credential_vault_unavailable` | `api configure-credentials` | The chosen file is fine but `~/.flutter-release` could not be written — distinct from `invalid_credentials` so a client can tell "pick another file" from "fix the vault" |
| `invalid_request` | `api run` | The action and arguments cannot be mapped to a command: a missing project or `--platform`, or `validate` with a non-Android platform |
| `stream_failed` | `api run` | Reading the child's output raised, or `frk` was signalled. Emitted after `started`; the child's process group is killed and `finished` follows with `success: false` |
| `project_unavailable` | `api store-versions`, `api build-args`, `api set-build-args`, `api set-track` | The registered project directory no longer exists |
| `project_not_onboarded` | `api store-versions` | The project has no shared Fastfile import or release configuration |
| `fastlane_unavailable` | `api store-versions` | fastlane is not on `PATH`, or the child process could not be started |
| `store_query_timed_out` | `api store-versions` | The lane did not finish within 300 seconds of being started and was stopped |
| `store_query_failed` | `api store-versions` | The lane produced no report line |
| `store_report_unreadable` | `api store-versions` | The report line is not a JSON object |
| `invalid_platform` | `api set-build-args` | The project does not have the given `--platform` in `platforms` |
| `invalid_platform` | `api set-track` | The project is not configured for Android |
| `command_failed` | Any document command | The command exited through a handled diagnostic; the sentence is on stderr |
| `internal_error` | Any document command | An unhandled exception escaped the command body |

`command_failed` and `internal_error` are the last-resort channels: a machine
API command must never answer a failure with zero bytes, and never with exit 0.

Argument errors caught by the parser itself, such as an unknown action or an
unknown flag, are not part of this contract. They print human usage text on
stderr, produce no JSON, and exit with status 2.

## Exit codes

Exit codes are not uniform across the API commands, so clients must interpret
them per command.

| Command | 0 | 1 | 2 |
|---|---|---|---|
| `api capabilities`, `api projects`, `api credentials` | Always | — | — |
| `api project`, `api setup` | Document returned | `project_not_found` | — |
| `api store-versions` | A report was returned, whatever the per-platform statuses say | Any of its error codes; nothing was read | — |
| `api build-args` | Document returned | `project_not_found`, `project_unavailable` | — |
| `api set-build-args` | The list was written (or was already what was asked for) | `project_not_found`, `project_unavailable`, `invalid_platform` | — |
| `api set-track` | The track was written (or was already what was asked for) | `project_not_found`, `project_unavailable`, `invalid_platform` | — |
| `api configure-credentials` | Store configured | `invalid_credentials` | — |
| `api run` | The action succeeded | The action ran and failed | `invalid_request` |

Any document command can also exit 70 (`internal_error`) or exit with the
status a handled diagnostic used (`command_failed`, exit 1 in practice).

`api run` exit 1 therefore has a different meaning from exit 1 anywhere else in
this API: the request was valid and the underlying action was started, and it
is the action that failed. `api run` returns the underlying command's own exit
status, so a non-zero code other than 2 comes from that command rather than
from the API layer, and `finished.exitCode` always carries the same value.

When the underlying process is terminated by a signal, the reported code is
`128 + signal` — for example 143 after a client cancels a run by sending
`SIGTERM` to the API process.

## Compatibility and security

- Existing v1 fields retain their meaning. New optional fields may be added.
- New commands may be added within a protocol version. Neither a new field nor
  a new command changes an existing request, so neither is breaking — but a
  client must not treat the command list here as closed, and must not assume
  that every `frk` reporting `protocolVersion: 1` accepts every command
  described here. See below.
- Breaking changes require a new protocol version and an advertised overlap.
- Responses contain project metadata and artifact paths, never credential
  contents, passwords, or private signing material. `store-versions` is the
  network-facing path and carries no key path, key id, issuer id,
  service-account email, or token in any field, including free text.
- Production publication is not a machine API capability.

### Is a new command covered by "new optional fields may be added"?

No, and `store-versions` is the case that exposed it. That sentence is about
the contents of a document. A command is a new *request*, and a client that
sends `api store-versions` to an older `frk` does not get a v1 document with a
field missing: argparse rejects the subcommand, writes a usage block to stderr,
writes **nothing** to stdout, and exits 2. That is outside the JSON contract
entirely, so the field rule never applied to it. The second bullet above was
added to say what the rule actually is, rather than stretching the field rule
to cover something it does not describe.

The remaining sharp edge is detection. `api capabilities` does not advertise
document commands at all: its `capabilities` object has no `documents` key, and
its key set is frozen at v1 by `tests/fixtures/api_v1_keys.json`, so adding one
is itself a protocol change and not a thing to slip in. Until that key exists,
a client detects support for a command in one of two ways:

- compare `cliVersion` from `api capabilities` against the version that
  introduced the command — `store-versions` is present from 0.7.0 onward; or
- run it and treat *exit 2 with empty stdout* as "this CLI does not have it",
  which is distinguishable from every documented failure, all of which exit 1
  with a JSON error document.

The fix belongs in the next protocol version: add a `documents` key to
`capabilities.capabilities` listing the document commands, so support is
discoverable without a version comparison. Do **not** meanwhile list a document
command in `capabilities.actions`. That list is `api run` actions; a document
command placed there is advertised to clients and then rejected by `api run`
with an argparse usage block, which is exactly the bug that removed
`credentials` and `configure-credentials` from it.
