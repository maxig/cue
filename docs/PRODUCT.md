# Product Documentation: Cue

**Cue** is an open-source, self-hostable Loom alternative designed for high-performance screen recording, instant sharing, and AI-powered video insights. It prioritizes data sovereignty, minimal footprint (menubar-first), and a polished "Studio" aesthetic.

## 1. Core Objectives
- **Zero Friction:** One-click recording from the macOS menubar.
- **Privacy First:** All videos stored on user-controlled hardware (S3/MinIO).
- **AI-Enhanced:** Automatic transcription, summarization, and "smart" chapters.
- **Philosophy:** "Don't make me think." Minimalist controls, maximum output quality.

## 2. Competitive Analysis: The "Vital" Moats

To succeed against incumbents, Cue must bridge the gap between Loom's collaborative speed and Cap's studio-grade aesthetics.

### 2.1 Loom: The Efficiency Powerhouse
Loom's success is built on "Instant" workflows that minimize the time between *thought* and *shared link*.
- **Streaming Uploads:** Decoupling recording from uploading. The link is ready before the user even finishes speaking.
- **Filler Word Removal:** AI-driven "clean" transcripts and audio by stripping "ums" and "uhs" automatically.
- **Interactive Timeline:** Emoji reactions at specific timestamps turn a monologue into a conversation.
- **Searchable Library:** A team-wide "Video CMS" where every word spoken is indexed and searchable.

### 2.2 Cap.so: The Studio Aesthetic
Cap (and Screen Studio) won by making raw screen captures look like professionally edited product demos.
- **Studio Mode:** Post-recording camera repositioning and resizing. The webcam isn't "burned" into the video.
- **Dynamic Zoom:** Automatic "Auto-Zoom" on clicks and key presses using smooth spring-physics transitions.
- **Cursor Smoothing:** Eliminating mouse jitter by transforming raw paths into "silky-smooth" cinematic curves.
- **Canvas Backgrounds:** Framing the recording within custom gradients or branded backgrounds to elevate the visual polish.

## 3. Target Features

### Phase 1: The Core (MVP)
- **Menubar Controller:** Start/Stop/Pause recording, toggle webcam, select display/window.
- **High-Performance Recording:** 4K/60fps support using macOS ScreenCaptureKit.
- **Instant Upload:** Streaming upload to S3-compatible storage as the recording happens.
- **Sharing Page:** A minimalist web player with a unique shareable URL.

### Phase 2: AI & Studio Polish
- **AI Insights:** Word-level transcription, summarization, and **Filler Word Removal** (AI-detected "ums/uhs").
- **Studio Layouts:** Post-recording camera repositioning/resizing and **Custom Canvas Backgrounds**.
- **Visual Refinement:** **Smooth Mouse Paths** (post-processing) and click-ripple animations.
- **Team Workspaces:** Basic user management, shared folders, and RBAC.

### Phase 3: Advanced Automation & Collaboration
- **Automated Cinematography:** AI-powered **Auto-Zoom on Click** and interaction-aware focus.
- **Interactive Player:** **Emoji reactions at timestamps** and threaded comments on the video timeline.
- **Enterprise Library:** Global search across all team videos (indexed by transcript) and SSO/SCIM integration.
- **Custom Branding:** White-labeled sharing pages and custom domains.

## 4. User Flow
1. **Trigger:** User clicks the Cue icon in the macOS menubar or uses a global hotkey.
2. **Configure:** Quick-select menu appears (Screen+Cam, Window, Area).
3. **Record:** Visual countdown; a subtle recording indicator appears in the menubar.
4. **Finish:** User stops recording. The link is automatically copied to the clipboard.
5. **View:** Recipient opens the link to a high-performance web player with AI features.

## 5. Technical Architecture
- **Client:** Native macOS Application (Swift, SwiftUI, AppKit).
- **Storage:** S3-compatible (MinIO for on-prem, R2/S3 for cloud).
- **Processing:** Native macOS media frameworks (AVFoundation, ScreenCaptureKit) for local processing; background workers for AI transcription and metadata.
- **Backend:** Swift-friendly API (Cloudflare Workers, Node.js, or FastAPI) for link management, auth, and metadata.

## 6. Design Vibe
- **Theme:** Dark Mode by default.
- **Typography:** Inter or SF Pro (Native Mac feel).
- **Accents:** Electric Blue or Deep Teal (distinguishing from Loom's Purple).
- **Philosophy:** "Don't make me think." Minimalist controls, maximum output quality.

