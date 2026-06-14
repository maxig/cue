# Technical Requirements: Cue

This document outlines the technical stack and architecture for **Cue**, optimized for high-performance macOS capture and a native user experience.

## 1. Primary Tech Stack
- **Languages:** Swift
- **UI Frameworks:** SwiftUI + AppKit
  - *Rationale:* Native Swift provides the best access to macOS media frameworks (ScreenCaptureKit, AVFoundation) and ensures the highest performance, reliability, and model efficiency.
- **Media Frameworks:**
  - **Screen Capture:** ScreenCaptureKit (SCK)
  - **Camera/Mic:** AVFoundation
  - **Encoding/Muxing:** AVAssetWriter (fallback to VideoToolbox/AudioToolbox if needed)
- **Networking:** URLSession (Background uploads)
- **Backend (Server):** Cloudflare Workers, Node.js, or FastAPI (Swift-friendly JSON API)
- **Database:** PostgreSQL (Supabase/Firebase)
- **Storage:** S3-compatible (Cloudflare R2 or AWS S3)

## 2. System Architecture

### A. UI Shell
- **MenuBarExtra:** Primary entry point for the application.
- **Recorder Control Window:** Detached window for real-time recording controls (Start/Stop/Pause).
- **Permissions Onboarding:** Guided flow for Camera, Microphone, and Screen Recording permissions.
- **Upload/Share History:** SwiftUI-based view for managing past recordings.

### B. Core Modules
- **CaptureCore:**
  - `ScreenCaptureManager`: Manages ScreenCaptureKit streams.
  - `CameraCaptureManager`: Manages AVFoundation camera sessions.
  - `MicrophoneCaptureManager`: Manages audio inputs.
  - `DeviceManager`: Handles camera/mic enumeration and hot-switching.
  - `CaptureSynchronizer`: Ensures temporal alignment across streams.
- **RecordingCore:**
  - `SampleBufferRouter`: Routes frames to the correct encoder/writer.
  - `CompositionEngine`: Handles screen + camera overlay (V2 focus).
  - `Encoder`: Video/Audio encoding logic.
  - `SegmentWriter`: Writes recording to local disk in segments.
  - `RecordingManifest`: Tracks metadata and segment locations.
- **UploadCore:**
  - `BackgroundUploader`: Resilient `URLSession` background tasks.
  - `RetryQueue`: Manages failed uploads.
  - `ShareLinkClient`: Interfaces with the backend to generate public links.
  - `LocalRecordingStore`: Local cache and management of recorded files.

## 3. Recording Strategy (Iterative)

### Phase 1: Separate Track Recording (MVP)
Record separate tracks to ensure reliability and simplify device switching:
- Screen video track
- Camera video track
- Microphone audio track
- System audio track
- Metadata track (for layout/switch events)
*Composition happens post-recording or on the player side.*

### Phase 2: Real-time Compositing (Loom-style)
Composite screen and camera (e.g., camera bubble) into a single encoded MP4/MOV in real-time.

## 4. AI Pipeline
- **Transcription:** Deepgram SDK or Whisper (Native implementation).
- **Processing:**
  - **Summarization:** LLM (Gemini 1.5 Flash/Pro) for titles and summaries.
  - **Smart Chapters:** Visual change detection + Audio cues.
- **Post-Processing:** AI-driven filler word removal and smart trimming.

## 5. Deployment & Packaging
- **Distribution:** Developer ID Notarization (Direct Download).
- **Updates:** Sparkle framework or native updater.
- **Avoid Initially:** Mac App Store (due to sandbox limitations on screen recording/system audio if applicable).

## 6. Constraints & Avoidances
- **Avoid:** Electron, Tauri, React Native macOS (Performance/Native API overhead).
- **Avoid Initially:** FFmpeg (Adds packaging/licensing complexity; use native frameworks first).
- **Strictly Native:** No hybrid modules; keep the app dependency-light for maximum reliability.
