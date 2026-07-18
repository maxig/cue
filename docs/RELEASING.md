# Releasing and testing Cue updates

Cue uses [Sparkle 2](https://sparkle-project.org/) for in-app updates and GitHub
Releases for hosting. GitHub Actions builds a universal app, signs it with
Developer ID, sends it to Apple's notary service, creates a DMG and a Sparkle ZIP,
generates `appcast.xml`, and publishes all three assets.

Normal pushes and pull requests run `.github/workflows/ci.yml`. A release is
created only for a three-part version tag such as `v1.0.1`.

## One-time signing setup

The workflows are committed without secrets. Add these in
**GitHub → maxig/cue → Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key exported as `.p12` |
| `DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used when exporting that `.p12` |
| `APP_STORE_CONNECT_API_KEY_P8` | Contents of an App Store Connect **team** API key (`AuthKey_….p8`) allowed to notarize |
| `APP_STORE_CONNECT_KEY_ID` | API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect issuer ID |
| `SPARKLE_PRIVATE_KEY` | Cue's exported Sparkle private key |

Developer ID and notarization require an Apple Developer Program membership.
Create a **Developer ID Application** certificate in Xcode's Accounts settings or
the Apple Developer portal, install it, and export it with its private key from
Keychain Access as a password-protected `.p12`.

For notarization, create a **Team Key** under **App Store Connect → Users and
Access → Integrations → App Store Connect API**. Do not use an Individual API Key;
Apple does not allow individual keys to authenticate `notarytool`.

Cue's Sparkle key has already been generated under the Keychain account
`com.max.Cue`. Its public key is safe and committed in the Xcode project. Export
the private key and upload it without printing it:

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.max.Cue \
  -x /private/tmp/cue-sparkle-private-key
gh secret set SPARKLE_PRIVATE_KEY < /private/tmp/cue-sparkle-private-key
rm /private/tmp/cue-sparkle-private-key
```

The easiest way to add the remaining values without copying them into shell
history is `gh secret set SECRET_NAME`, then paste at its hidden prompt. For the
certificate, pipe the base64 text directly:

```bash
base64 < /path/to/DeveloperIDApplication.p12 | \
  gh secret set DEVELOPER_ID_APPLICATION_P12_BASE64
```

Keep both the `.p12` and the Sparkle private key in a separate secure backup.
Losing the Sparkle key prevents existing installations from trusting future
updates.

## Publish a release

First make sure `main` is green, then create a version tag:

```bash
git switch main
git pull --ff-only
git tag -a v1.0.1 -m "Cue 1.0.1"
git push origin v1.0.1
```

The tag determines `CFBundleShortVersionString`; the workflow uses its monotonic
GitHub run number for `CFBundleVersion`. Sparkle compares that build number.
Do not reuse or move a published release tag.

The release appears at `https://github.com/maxig/cue/releases`. Cue reads the
stable feed URL:

```text
https://github.com/maxig/cue/releases/latest/download/appcast.xml
```

Run the same verification locally at any time:

```bash
scripts/ci.sh
```

## Test a real in-place upgrade

Use two genuine releases; an Xcode Run build is a separate DerivedData copy and
does not prove that replacement of the installed app works.

1. Publish an older release, download its DMG, drag `Cue.app` to `/Applications`,
   and launch `/Applications/Cue.app`.
2. Launch it twice, or use **Check for Updates…** manually. Sparkle intentionally
   waits until the second launch before asking about automatic checks.
3. Make a small visible change, publish a higher tag, and wait for the Release
   workflow to finish.
4. Stop any Cue process launched by Xcode. Launch only `/Applications/Cue.app`.
5. Right-click Cue's menu-bar icon and choose **Check for Updates…**.
6. Accept the update. Cue should replace itself in `/Applications`, relaunch, and
   show the new version and build in **Settings → General**.
7. Confirm screen/camera/microphone permissions, settings, and existing recordings
   are still present, then make and play a short recording.

If an automatic check was throttled during testing, clear only Sparkle's last
check timestamp and relaunch:

```bash
defaults delete com.max.Cue SULastCheckTime
```

Also test the DMG on a clean macOS user account: mount it, drag Cue to
Applications, launch it, and confirm Gatekeeper identifies the developer without
showing an unidentified-developer warning.

## What CI verifies

- Debug and Release builds compile with signing disabled.
- Xcode's static analyzer completes for Release.
- Release tags additionally require a universal Developer ID-signed app, successful
  Apple notarization, stapled tickets, a notarized DMG, and a Sparkle-signed update.
- A release is not published if any signing, notarization, packaging, or
  verification step fails.
