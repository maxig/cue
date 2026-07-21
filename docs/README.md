# Cue

A self-hostable, native macOS Loom alternative — a Liquid Glass menubar recorder
that captures your screen + camera + mic and shares the result.

This repo contains the completed **Phase 1 and Phase 2** recorder: native capture,
self-hosted sharing, Cloudflare AI insights, and reversible Studio composition.
Sharing remains wired through a pluggable `UploadService` with local, MinIO, and
full Cue-server backends.

## Requirements

- macOS 15.0 or later (built and tested on macOS 15.7.4)
- Xcode 26 (macOS 26 SDK) — needed because the UI adopts Apple's **Liquid Glass**
  APIs, gated to macOS 26+ with a translucent-material fallback on macOS 15.

## Build & run

```bash
open Cue.xcodeproj      # then press ⌘R
# or from the CLI:
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

The app launches as a **menubar agent** (no Dock icon — `LSUIElement`). Click the
record glyph in the menu bar to open the recorder popover.

### First-run permissions

On first record you'll be asked to grant **Screen Recording**, **Camera**, and
**Microphone** access. Screen Recording must be enabled in
*System Settings ▸ Privacy & Security ▸ Screen Recording*; macOS applies it on
the next launch, so relaunch Cue after enabling.

## Liquid Glass on macOS 15

Liquid Glass renders natively only on macOS 26+. On macOS 15 (e.g. this dev
machine) every glass surface falls back to a hand-tuned `NSVisualEffectView` /
`.ultraThinMaterial` look — same layout, same call sites
(`Cue/DesignSystem/LiquidGlass.swift`). You'll see true glass once on Tahoe.

## Project layout

```
Cue/
  App/            CueApp (MenuBarExtra + Library/Settings windows), AppState
  MenuBar/        RecorderPopoverView (the star), floating RecordingOverlay
  DesignSystem/   Liquid Glass + macOS 15 fallback, theme, components
  Capture/        ScreenRecorder (SCK), CameraRecorder (AVFoundation), DeviceManager
  Recording/      RecordingEngine orchestration, local RecordingStore
  Upload/         UploadService protocol, LocalStub + MinIO (SigV4, no deps)
  Permissions/    PermissionsManager (camera/mic/screen)
  Library/        LibraryView — playback + share surface
  Models/         Recording, CaptureModels
```

## Recording strategy

Option A from the design docs: **separate tracks**. The screen (video + one
audio track) is written to `screen.mov` via `AVAssetWriter`; the camera is
written to its own `camera.mov`. This makes device switching resilient and lets
the Studio editor reposition the webcam bubble and re-render cinematic effects.

System audio and microphone are retained on separate tracks and mixed into the
final timeline during post-composition.

## Camera bubble & compositing

When a camera is enabled for a screen recording, a live **camera bubble** floats
on screen (draggable, always-on-top). Its shape — circle / rounded-square /
square — and size are set in *Settings ▸ General ▸ Camera bubble*.

Capture writes **separate tracks** (`screen.mov`, `system.m4a`, `mic.m4a`,
`camera.mov`). On stop, Cue composes a single shareable **`final.mp4`**:
the camera baked in as a picture-in-picture (matching the bubble shape, via a
Core Image custom `AVVideoCompositing`) and the system + microphone audio mixed
into one track (offline `AVAudioEngine` render). This adds a few seconds of
"Saving…" after you stop.

## Sharing stack (local, self-hosted)

The full share pipeline runs locally. Start it once:

```bash
# 1) MinIO object storage (Docker) — creates a public-read 'cue' bucket
docker compose -f infra/docker-compose.yml up -d
#    S3 API http://localhost:9000 · console http://localhost:9001 (cueadmin / cuesecret123)

# 2) Share API + web player
cd server && npm install && npm start      # http://localhost:8787
```

Then in *Settings ▸ Sharing* choose a backend:

- **Local (no upload)** — saves locally, copies a placeholder link.
- **MinIO only** — SigV4-signed `PUT` (Foundation + CryptoKit, no SDK); the
  share link is the raw object URL.
- **Cue server** *(default once configured)* — uploads `final.mp4` to MinIO,
  registers it with the backend, and copies a real player link:
  `http://localhost:8787/v/<id>`. The page streams the video from MinIO and
  shows editable title/meta. The Cloudflare backend adds AI summaries, smart
  chapters, timestamped transcripts, reactions, and comments.

The secret key is kept in the macOS Keychain. For sharing beyond this Mac, point
the backend + MinIO at a public host (or a Cloudflare tunnel) and set the
backend/public base URLs accordingly.

## Next on the roadmap

Team workspaces, shared folders, RBAC/SSO, and deeper AI-assisted editing beyond
the current click-aware Studio effects. See `PRODUCT.md` for the current phases.
