<div align="center">

# 🎬 Cue

**A self-hostable, native macOS screen recorder — your own Loom, on your own storage.**

Record your screen + camera + mic from the menu bar, get an instant share link,
and keep every byte on infrastructure you control.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white)
![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-+_AppKit-1575F9?logo=swift&logoColor=white)
![Backend](https://img.shields.io/badge/backend-self--hosted-00B8BD)
![Free tier](https://img.shields.io/badge/Cloudflare-free_tier-F38020?logo=cloudflare&logoColor=white)
![Status](https://img.shields.io/badge/status-Phase_1-0A84FF)

</div>

---

Cue is an open-source alternative to Loom and Cap, built around one idea:
**your recordings are yours.** No accounts, no third-party video host, no egress
bills. Capture happens natively on your Mac; sharing runs on storage you own —
either a local MinIO bucket or a free-tier **Cloudflare** stack (R2 + D1 + a
Worker that also does AI transcription).

- 🪶 **Menubar-first** — a tiny agent, no Dock clutter. Click, record, done.
- 🖥️ **Native capture** — ScreenCaptureKit + AVFoundation. Screen, window, region, or camera-only.
- 🎥 **Camera bubble** — a draggable webcam overlay, baked into the final video as picture-in-picture.
- 🔒 **Private by default** — share links are **off** until you enable them; the backend is fail-closed.
- ☁️ **Self-hosted sharing** — local (MinIO + Node) or Cloudflare (R2 + D1 + Worker), your choice.
- 🤖 **AI transcription** — Whisper via Workers AI on the Cloudflare backend.
- ✨ **Liquid Glass UI** — adopts Apple's macOS 26 design language, with a tuned fallback on macOS 15.

> **Status:** Phase 1 — the runnable menubar app and the full sharing pipeline
> work today. Studio polish (auto-zoom, canvas backgrounds) and collaboration
> (reactions, comments, teams) are on the [roadmap](#-roadmap).

---

## ✨ Features

**Working today**

- One-click recording from the menu bar with a live recording overlay.
- Capture modes: **full screen**, **single window**, **selected region**, **camera-only**.
- Screen, system audio, microphone, and camera are recorded as **separate tracks**,
  then composed into a single shareable **`final.mp4`** (camera as a shaped PiP, audio mixed).
- A configurable **camera bubble** (circle / rounded-square / square, sized in Settings).
- Pluggable sharing via three backends — local-only, bucket-only, or the full Cue server.
- A minimalist **web player** page per recording, with a unique share URL.
- **Owner controls**: enable/disable a link, remove from cloud, or delete everywhere.
- **AI transcription** (Cloudflare backend) — Whisper turns the audio sidecar into
  a searchable transcript shown in the player.
- Secrets (S3 keys, owner token) live in the **macOS Keychain**, never on disk in clear.

**On the roadmap** → see [`docs/PRODUCT.md`](docs/PRODUCT.md)

- AI summaries, smart chapters, and filler-word removal.
- Studio mode: post-recording camera repositioning, custom canvas backgrounds, auto-zoom on click.
- Interactive player: timestamped emoji reactions and threaded comments.
- Team workspaces, shared libraries, SSO.

---

## 🧭 How it works

```
   ┌─────────────────┐   record    ┌──────────────┐   PUT (S3/SigV4)   ┌──────────┐
   │  Cue menubar app │ ──────────▶ │  final.mp4   │ ─────────────────▶ │  Storage │
   │  (SwiftUI/AppKit) │            │  + audio.m4a │                     │ R2/MinIO │
   └─────────────────┘             └──────────────┘                     └────┬─────┘
            │ register metadata (owner token)                                │ stream
            ▼                                                                 ▼
   ┌─────────────────────────────┐   share link    ┌───────────────────────────────┐
   │  Backend (Worker / Node)     │ ──────────────▶ │  Web player  /v/<id>           │
   │  D1 / db.json · /v · /file   │                 │  (anyone with the link, if on) │
   └─────────────────────────────┘                 └───────────────────────────────┘
```

The app records locally and uploads the finished file **directly to your bucket**.
The backend only stores metadata and serves the player page — it never proxies the
upload. Share links start **disabled**; you flip them on per recording.

---

## 🚀 Quick start

### Requirements

- **macOS 15.0+** (built and tested on 15.7.4).
- **Xcode 26** (macOS 26 SDK) — the UI adopts Apple's **Liquid Glass** APIs, gated
  to macOS 26+ with a translucent-material fallback on macOS 15.

### Build & run

```bash
open Cue.xcodeproj      # then press ⌘R
# …or from the CLI:
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

Cue launches as a **menubar agent** (no Dock icon — `LSUIElement`). Click the
record glyph in the menu bar to open the recorder.

### First-run permissions

On first record macOS asks for **Screen Recording**, **Camera**, and **Microphone**
access. Screen Recording must be enabled in *System Settings ▸ Privacy & Security ▸
Screen Recording*; macOS applies it on the next launch, so **relaunch Cue** after
enabling.

---

## ☁️ Set up sharing

In *Settings ▸ Sharing* pick a backend:

| Backend | What it does | Best for |
| --- | --- | --- |
| **Local (no upload)** | Saves locally, copies a placeholder link | Trying the app offline |
| **Bucket only** | SigV4 `PUT` to S3/MinIO; link is the raw object URL | Quick direct links |
| **Cue server** | Uploads to the bucket **and** registers with the backend for a real web player | Real sharing |

You can self-host the **Cue server** two ways:

### Option A — Local (MinIO + Node), in two commands

```bash
# 1) MinIO object storage (Docker) — creates a 'cue' bucket
docker compose -f infra/docker-compose.yml up -d
#    S3 API http://localhost:9000 · console http://localhost:9001 (cueadmin / cuesecret123)

# 2) Share API + web player
cd server && npm install && npm start      # http://localhost:8787
```

Great for development. Share links work on your machine (or anywhere via a tunnel).

### Option B — Cloudflare (R2 + D1 + Worker), free-tier & always-on

A fully-hosted, **free-tier** deployment: R2 for the video (zero egress fees), D1
for metadata, a Worker for the API + player, and Workers AI for transcription.

👉 **Follow the step-by-step guide:** [`cloudflare/README.md`](cloudflare/README.md)

It's written for newcomers and covers picking an EU/US bucket region, the owner
token, deploying, pointing the app at it, and an optional **Cloudflare
Access-gated dashboard** at `/app` to browse your whole library from the browser.

---

## 🔐 Security & privacy

Cue is built to keep your library private:

- **Links are off by default.** A fresh upload is registered **disabled** — nothing
  is viewable until you click *Enable link*.
- **The backend is fail-closed.** Every `/api` endpoint (list, register, delete,
  enable/disable, transcribe) requires an **owner token**; without it you get `401`,
  and the whole surface is `503` until the token is configured.
- **No public catalog.** There is no endpoint that lists your videos to the public;
  the landing page shows nothing. Only enabled `/v/<id>` links work, and IDs are
  random UUIDs (unguessable capability URLs).
- **Private storage.** On the Cloudflare backend the R2 bucket is private (no public
  URL, no CORS); bytes flow only through the Worker while a link is enabled. The D1
  database is reachable only from the Worker.
- **Secrets in the Keychain.** Your S3 secret and owner token never sit in plaintext
  config.

See the [Cloudflare security model](cloudflare/README.md#security-model) for the
full breakdown and self-check commands.

---

## 🗂️ Project layout

```
Cue/                 # the macOS app (SwiftUI + AppKit)
  App/               # CueApp (MenuBarExtra + Library/Settings), AppState
  MenuBar/           # recorder popover, floating recording overlay, camera bubble
  Capture/           # ScreenRecorder (ScreenCaptureKit), CameraEngine (AVFoundation)
  Recording/         # RecordingEngine orchestration, VideoComposer, local store
  Upload/            # UploadService protocol: LocalStub / MinIO / Cue server (SigV4, no SDK)
  DesignSystem/      # Liquid Glass + macOS 15 fallback, theme, components
  Permissions/       # camera / mic / screen permission flow + onboarding
  Library/           # playback + share surface
  Models/            # Recording, CaptureModels
server/              # local dev backend (Node/Express, db.json) — mirrors the Worker API
cloudflare/          # production backend: Worker + R2 + D1 + Workers AI  ← see its README
infra/               # docker-compose for local MinIO
docs/                # product spec, research, design notes
```

## 🛠️ Tech stack

- **App:** Swift 5, SwiftUI + AppKit, ScreenCaptureKit, AVFoundation, CryptoKit (SigV4 signing, no AWS SDK).
- **Local backend:** Node.js + Express, JSON file store, MinIO (S3-compatible).
- **Cloud backend:** Cloudflare Workers, R2 (storage), D1 (SQLite), Workers AI (Whisper), `jose` (Access JWTs).

---

## 🗺️ Roadmap

| Phase | Focus |
| --- | --- |
| **1 — Core** *(here)* | Menubar capture, compositing, self-hosted sharing, web player, transcription |
| **2 — AI & Studio** | Summaries, smart chapters, filler-word removal, camera repositioning, canvas backgrounds |
| **3 — Collaboration** | Timestamped reactions & comments, team workspaces, global search, SSO |

Full detail in [`docs/PRODUCT.md`](docs/PRODUCT.md).

---

## 🤝 Contributing

Issues and PRs are welcome. The codebase is structured so new capture sources,
upload backends, and player features slot in without rework — `UploadService` is a
clean protocol, and the local Node server mirrors the Cloudflare Worker's API so you
can develop against either.

## 📄 License

[MIT](LICENSE) © 2026 Maksim Hardziyenak.

## 🙏 Acknowledgements

Inspired by [Loom](https://loom.com) and [Cap](https://cap.so). Built on Apple's
media frameworks and Cloudflare's developer platform.
