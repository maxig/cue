# Cue

Native macOS menubar screen recorder (Swift 5, SwiftUI + AppKit). Capture via ScreenCaptureKit, encoding via AVFoundation, uploads signed SigV4 with CryptoKit — **no AWS SDK dependency; keep it that way**. Sharing backend on Cloudflare (Worker + R2 + D1 + Workers AI), with a local Node/Express + MinIO path for dev and self-hosters.

Full incident history and deeper capture rules live in the `cue-macos-recorder` skill (`~/.claude/skills/cue-macos-recorder/SKILL.md`) — load it before touching pause/mute/camera/track logic.

## Layout

- `Cue.xcodeproj` — single target and scheme `Cue`. **No XCTest target** — verification is manual (see below).
- `Cue/` — app source (modules below)
- `cloudflare/` — production share backend (Worker, `wrangler.toml`, `schema.sql`)
- `server/` — local-dev share backend (Express, feature parity with the Worker)
- `infra/docker-compose.yml` — MinIO for local S3 storage
- `docs/` — product/tech notes; `build/` — xcodebuild derived data, ignore

### Cue/ modules

- `App/` — `CueApp` + `AppDelegate` entry, `AppState`, `Preferences`/`SettingsView`
- `MenuBar/` — `RecorderPopoverView`, `RecordingOverlay` + `OverlayController`, `CameraBubble`, `CaptureRegionIndicator`
- `Capture/` — `ScreenRecorder` (ScreenCaptureKit), `CameraEngine`, `DeviceManager`
- `Recording/` — `RecordingEngine` (track writers), `VideoComposer` (compositing — must sustain the configured 30/60 fps, and raw camera frames are preserved, never baked flat: post-record camera reposition is a feature), `CameraMatte`, `RecordingStore`
- `Upload/` — `UploadService` protocol with `LocalStubUploadService` (default), `MinIOUploadService`, `CueBackendUploadService`; SigV4 via CryptoKit; `Keychain`, `UploadSettings` (backend picker)
- `Upload/CloudflareProvisioning/` — one-click Cloudflare setup: paste one API token (pre-filled dashboard template), the app provisions R2 + D1 + schema + Worker + secrets + workers.dev via REST and derives the S3 keys from the token (access key = token id, secret = SHA-256 of token). Optional owner email → Cloudflare Access one-time-PIN lock for the `/app` web library; custom-domain attach; onboarding flow (intro → permissions → email → sharing) with state on `AppState` because the popover closes when the browser opens. `CueWorker.js`/`CueSchema.sql` are **generated** from `cloudflare/` — regenerate with `cd cloudflare && npm run sync:app-resources` after any Worker/schema change; never edit them directly.
- `DesignSystem/` — `Theme`, `Components`, `LiquidGlass` (macOS 26 Liquid Glass APIs, availability-gated)
- `Permissions/` — `PermissionsManager` (TCC: Screen Recording, Microphone, Camera) + `OnboardingView`. Prompt before capture starts, never mid-flow; degrade gracefully (e.g. record without camera).
- `Library/` — `LibraryView` local recordings browser
- `Models/` — `CaptureModels`, `Recording`

## Build & run

Requires Xcode 26 (macOS 26 SDK) for the Liquid Glass APIs.

```sh
open Cue.xcodeproj   # then ⌘R
# or
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

## Releasing

Pushing a `vX.Y.Z` tag triggers `.github/workflows/release.yml` (sign,
notarize, DMG + Sparkle appcast, GitHub release). The version comes from the
tag — nothing to bump in the repo.

1. **Always write release notes first**: add a `## X.Y.Z — YYYY-MM-DD` section
   at the top of `CHANGELOG.md`, written for users (what changed, why they'd
   care). It becomes the release body and the in-app update notes; without it
   the release ships with meaningless auto-generated text.
2. Commit, then: `git tag -a vX.Y.Z -m "Cue X.Y.Z" && git push origin main vX.Y.Z`

## Backends

`cloudflare/` (production — cue.gordienok.com):

```sh
cd cloudflare
npm run dev            # wrangler dev (localhost:8787)
npm run deploy         # wrangler deploy
npm run tail           # wrangler tail — first stop for prod debugging
npm run db:schema      # apply schema.sql to remote D1 (db:schema:local for local)
```

- Bindings: `MEDIA` (R2 bucket `cue`), `DB` (D1), `AI` (Workers AI — Whisper transcription, `SUMMARY_MODEL` summaries).
- The whole `/api` surface is fail-closed behind the `OWNER_TOKEN` secret (`wrangler secret put OWNER_TOKEN`); public viewing (`/v/:id`, `/file`) only serves enabled links. `/app` owner dashboard is gated by Cloudflare Access (jose JWT).
- `MAX_BYTES` caps R2 usage by evicting oldest recordings (local copies in the app survive).

`server/` (local dev): `node index.js` — Express on port 8787 (same default as `wrangler dev`), `db.json` for metadata, MinIO for bytes.

`infra/`: `docker compose -f infra/docker-compose.yml up -d` — MinIO S3 on :9000, console on :9001 (cueadmin/cuesecret123), bucket `cue` with anonymous download.

**Parity rule:** sharing features must work against both the Worker and `server/`+MinIO — a feature that only works on the Worker breaks self-hosters.

## A/V control semantics — a contract, do not reinterpret

These exact controls caused multi-turn bug chains. Reason about all tracks (screen, camera, mic) as one system before changing any:

- **Mute** = replace mic samples with silence, timestamps continuous. Must NEVER pause or stop any writer. Un-mute resumes real samples.
- **Hide camera** = UI-only: the overlay disappears, camera capture and encoding CONTINUE (the user may unhide). Must not freeze the last frame into the composite.
- **Pause** = ALL tracks pause and resume together, with ONE timestamp strategy applied to every track — either shift all subsequent timestamps by the pause duration, or fill all tracks (silence/last-frame). Mixing strategies per track is exactly what caused audio desync and screen-track loss.
- After resume, every writer must still be writing. A past "fix" stopped the screen track at pause while camera/audio continued; the follow-up "fix" lost everything after the pause.

**Mandatory verification for any capture-logic change** (a green `xcodebuild` is not verification, and there are no unit tests covering this): record a real ~1-minute session exercising the changed control mid-recording — e.g. record → 10s → pause 5s → resume → mute 5s → unmute → stop — then inspect the output: total duration correct, A/V in sync at the END of the clip (desync accumulates), no frozen/black segments, no lost segments, all tracks present.
