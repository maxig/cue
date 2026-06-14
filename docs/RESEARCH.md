✦ The research phase is complete. I have explored open-source alternatives, analyzed the design aesthetics of industry leaders, and formulated a technical stack for your "Loom-killer."

  1. Open Source Alternatives (On-Premise)
  The following projects allow for self-hosting with no artificial recording limits:
   * Cap (https://github.com/capdotso/cap): The most direct Loom alternative. It’s highly polished, supports macOS/Windows, and can be self-hosted via Docker with your own S3 storage (e.g., MinIO). License: AGPL-3.0.
   * SendRec (https://github.com/sendrec/sendrec): A modern Go-based alternative focused on data sovereignty. Includes local AI transcription using whisper.cpp. License: AGPL-3.0.
   * Snapify (https://github.com/snapify/snapify): A lightweight web-based recorder that generates sharing links instantly. License: MIT.

  2. Design Inspiration & "Vibe"
  I have consolidated a design breakdown in design/vibe_research.md. 
   * Loom ("Efficient Coworker"): Friendly, purple-themed, utility-focused with a persistent floating menubar widget.
   * Cap.so ("Polished Producer"): Minimalist, dark-mode first, focuses on "Studio Mode" (post-recording edits like smooth zoom and canvas padding).
   * Interaction Pattern: We should aim for a macOS MenuBarExtra (native dropdown) for the controller and a separate-track recording approach (recording camera and screen as individual files) to allow for Cap-like post-recording layout
     changes.

  3. Recommended Technical Stack
  For a high-performance, resilient implementation:
   * macOS App: Native Swift + SwiftUI + AppKit. 
   * Capture Engine: ScreenCaptureKit for screen/audio; AVFoundation for camera/mic.
   * Recording: AVAssetWriter for segmented local recordings.
   * Strategy: "Option A" - Record separate tracks (Screen, Camera, Mic, System Audio) to allow for resilient device switching and post-recording layout flexibility.
   * Backend: Swift-friendly API (Cloudflare Workers, Node.js, or FastAPI) with background workers for processing.
   * Storage: Cloudflare R2 or S3-compatible object storage.
   * AI Features: 
       * Transcription: Deepgram or Whisper.
       * Insights: Gemini 1.5 Flash/Pro for titles, summaries, and smart chapters.


  Next Steps
  How would you like to proceed?
   1. Prototype the macOS App: Start a basic Swift project for the menubar recorder.
   2. Setup the Backend: Build the API and video processing pipeline.
   3. Deep Dive Design: Refine the UI for the sharing page or menubar controller.
