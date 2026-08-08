# Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

## What is signed

AkvaLink publishes a Windows executable for configuring and provisioning the AkvaLink pool temperature sensor.

| Artifact | Format | Distribution |
|---|---|---|
| `AkvaLink.exe` (bundled inside `akvalink-app-windows-vX.Y.Z-unsigned.zip`, together with its Flutter runtime DLLs and assets) | Authenticode-signed Windows executable | [GitHub Releases](https://github.com/stenmo/AkvaLink/releases) and [akvalink.com](https://akvalink.com) |

Device firmware for the NORA-W40 / ESP32-C6 is not Authenticode-signed; it is distributed as `.bin` images from the same releases.

## Team roles

AkvaLink is a single-maintainer project.

- **Committers and reviewers:** [@stenmo](https://github.com/stenmo)
- **Approvers:** [@stenmo](https://github.com/stenmo)

All changes proposed by non-committers arrive as pull requests and are reviewed by a maintainer before merge. This includes build scripts and CI workflow files. All accounts with write access to the repository and to SignPath use multi-factor authentication.

## Build and signing process

- Release binaries are built exclusively by GitHub Actions from source in this repository. Locally built binaries are never submitted for signing.
- The signing request is raised by the release workflow and requires manual approval by an approver listed above.
- The private key is held by SignPath in an HSM. This project has no access to it and stores no signing keys.
- Signatures are timestamped, so they remain valid after the certificate expires.
- The build's version resource sets `ProductName` to `AkvaLink` and the same `ProductVersion` across the whole build, matching SignPath's metadata requirements (see `app_flutter/windows/runner/Runner.rc`).

## Privacy policy

This program will not transfer any information to other networked systems unless specifically requested by the user or the person installing or operating it, with one exception:

On startup, the app makes a single unauthenticated HTTPS GET request to the public GitHub Releases API (`api.github.com`) to check the latest available AkvaLink firmware version, so the "flash latest" buttons can be labelled with the current release tag. This request sends no personal data, device identifiers, or account information — it is the same plain metadata request anyone's browser could make against a public, open-source GitHub repository. No analytics, crash reporting, or other telemetry is sent, and no AkvaLink-operated cloud service is involved.

The program also communicates over Bluetooth Low Energy and/or serial with AkvaLink hardware on the user's own network, and — for the standalone Wi-Fi builds — with the sensor directly over the local network (HTTP, mDNS). Once commissioned, the sensor communicates over Thread/Matter with the user's own hub or controller.

## Installation and uninstallation

The executable is a standalone tool that requires no installation; delete the file to remove it. It does not modify system configuration.

## Verifying a signature

On Windows, right-click the downloaded `.exe`, choose **Properties › Digital Signatures**, and confirm the signer is **SignPath Foundation**. From PowerShell:

```powershell
Get-AuthenticodeSignature .\AkvaLink.exe | Format-List Status, SignerCertificate
```

`Status` should read `Valid`, and the certificate subject should be `SignPath Foundation`.

## Reporting

Suspected abuse of the AkvaLink signing certificate can be reported to the maintainer via [GitHub issues](https://github.com/stenmo/AkvaLink/issues) and to SignPath at support@signpath.io.
