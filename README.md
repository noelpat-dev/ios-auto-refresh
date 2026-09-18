# iOS Auto Refresh

A small macOS LaunchAgent that refreshes near-expiry, automatically signed iOS
development builds without opening Xcode. Multiple apps are configured through
private plist catalog entries and processed serially.

This is for apps you build yourself on devices you control. It is not a signing
service and does not bypass Apple authentication, provisioning, trust,
Developer Mode, or device-lock requirements.

## Safety model

- Existing apps are updated in place with `devicectl device install app`.
- The tool never issues an app-uninstall command and refuses a first install.
- Bundle ID, team/application identifier, provisioning expiry, and code
  signature are checked before every update.
- The running-process state is checked twice, including immediately before the
  install command. A launch in the unavoidable final device-command gap cannot
  be prevented, so the tool never promises an atomic running-state lock.
- Cached profiles are quarantined only when their application identifier is an
  exact match. Restoration is attempted on failure; if restoration itself
  fails, the recovery files remain in the private run directory. A later run
  restores an unambiguous quarantine left by interruption or power loss and
  stops for manual recovery if a destination conflict exists.
- `--status` and `--dry-run` do not write, build, contact a device, or move a
  provisioning profile.
- The installed scheduler runs a private content-addressed copy of the worker,
  not the mutable Git checkout.

Xcode project build phases execute code with your user permissions. Configure
only projects you trust, inspect changes before installing a new tool revision,
and do not run an unattended scheduler against untrusted branches.

## Requirements

- macOS with Xcode and Command Line Tools
- an Apple account already configured interactively in Xcode
- a valid Apple Development signing identity in Keychain
- a paired and trusted iPhone with Developer Mode enabled
- the app already installed on that iPhone under the configured bundle ID

## Configure an app

Copy the example without committing the result:

```bash
cp apps.d/example.plist.template apps.d/my-app.plist
```

Fill in every value. Find useful identifiers with:

```bash
xcodebuild -project /path/to/App.xcodeproj -scheme App -showdestinations
xcrun devicectl list devices
```

Catalog filenames become app keys. A file named `my-app.plist` is selected as
`--app my-app`. Real `apps.d/*.plist` files are ignored because they contain
local project paths and deployment identifiers.

## Validate and inspect

```bash
bin/ios-auto-refresh --app my-app --validate
bin/ios-auto-refresh --app my-app --status
bin/ios-auto-refresh --app my-app --dry-run
bin/ios-auto-refresh --all --dry-run
```

When running from the checkout, point the worker at its private source catalog:

```bash
IOS_AUTO_REFRESH_CATALOG_DIR="$PWD/apps.d" \
  bin/ios-auto-refresh --all --dry-run
```

## Install the scheduler

```bash
bin/install-launch-agent
```

The installer validates every real catalog entry, copies the worker, and stages
the complete catalog under `~/Library/Application Support/iOSAutoRefresh`. It
validates that staging area before replacing the prior catalog as one unit, then
generates `~/Library/LaunchAgents/dev.ios-auto-refresh.plist` and schedules serial checks
at minutes 2, 17, 32, and 47. Work occurs only inside each app's configured
expiry threshold.

The source `apps.d` directory is authoritative. For safety, installation stops
if the private installed catalog contains a stale entry that no longer has a
matching source file; move that entry aside explicitly before reinstalling.

To preview installation without writing or invoking `launchctl`:

```bash
bin/install-launch-agent --dry-run
```

To stage and inspect the private snapshot and generated plist without loading
the LaunchAgent:

```bash
bin/install-launch-agent --no-load
```

## Manual commands

```bash
bin/ios-auto-refresh --app my-app
bin/ios-auto-refresh --app my-app --force
bin/ios-auto-refresh --all
```

`--force` bypasses the recorded expiry gate but retains all identity, signature,
installed-app, and running-app safeguards.

## Disable the scheduler

```bash
bin/uninstall-launch-agent
```

This unloads the LaunchAgent and moves its plist to Trash. It preserves app
catalogs, state, diagnostics, installed applications, and application data.

## Private runtime data

Runtime state, a hash-verified worker snapshot, and the most recent diagnostic
logs live below `~/Library/Application Support/iOSAutoRefresh` with
owner-only permissions. Diagnostic logs may contain signing and device metadata;
trusted Xcode project build phases may also write arbitrary sensitive output, so
do not publish them. Each retained log is truncated to its most recent MiB when
an attempt finishes. A capping failure is recorded as a failed outcome.

## Tests

```bash
tests/run-tests.zsh
```

The test suite uses temporary directories and does not build, sign, install,
contact a device, or load a LaunchAgent.

## Limitations

The Mac must be awake with the user logged in. Xcode signing must work without a
prompt, and the configured device must be reachable and unlocked when an update
is due. Free development provisioning remains subject to Apple's expiry rules;
this tool performs best-effort refreshes rather than eliminating those rules.
The device API exposes the installed bundle ID but not a reliable installed-team
field on every supported Xcode version. The candidate's team and application
identifier are verified, and iOS remains the final enforcement point for update
signing compatibility.
