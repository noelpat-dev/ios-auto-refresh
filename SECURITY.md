# Security policy

## Supported version

Security fixes are applied to the latest revision on the default branch.

## Reporting a vulnerability

Please use a private GitHub security advisory when available. Do not place
credentials, provisioning profiles, device identifiers, private project paths,
or exploit details in a public issue.

## Trust boundaries

This tool runs as the signed-in macOS user. It invokes Xcode and can install a
verified update onto a configured development device. Only install reviewed
revisions and only configure Xcode projects you trust: project build phases are
executable code.

The tool does not request or store Apple account passwords, two-factor codes,
private signing keys, or API tokens. Xcode and Keychain remain responsible for
account authentication and signing credentials.

Real catalog files are intentionally ignored by Git. They contain local paths,
bundle and team identifiers, and device identifiers. Keep them private. Runtime
state and bounded diagnostic logs are stored in a private directory under the
current user's Library. Trusted Xcode build phases can write arbitrary output to
those logs, so treat the logs as sensitive even when a signing attempt fails.
