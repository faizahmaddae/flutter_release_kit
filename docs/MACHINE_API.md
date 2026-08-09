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
```

Each command writes one compact JSON document to stdout. `capabilities` reports
the supported desktop protocol range and must be checked before other calls.

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
onboard, doctor, verify, build, validate, release, forget,
signing-audit, signing-import, signing-link, ios-setup-signing, status
```

`api setup` is read-only and returns structured Android/iOS readiness without
credential values. Android status is ordered around the real release chain:
`key.properties`, its referenced keystore, credential validation, Gradle
wiring, Git safety, and optional vault management. iOS status reports Xcode
identity, a local distribution identity, the decoded app profile and expiry,
certificate/profile compatibility, ExportOptions, and automation access.
`signing-import` can accept `--properties`, `--keystore`, and `--link`; the
source is preserved and secrets never appear in events.
`forget` removes only the selected entry from FRK's private project registry;
it never deletes or edits the Flutter project.
`ios-setup-signing` may change Apple Developer signing state and clients must
obtain explicit confirmation immediately before running it.

`validate` is Android-only. It sends the AAB to Google Play's validation API,
but does not create a release on any track. This is a remote store operation,
not a local-only check.

## Compatibility and security

- Existing v1 fields retain their meaning. New optional fields may be added.
- Breaking changes require a new protocol version and an advertised overlap.
- Responses contain project metadata and artifact paths, never credential
  contents, passwords, or private signing material.
- Production publication is not a machine API capability.
