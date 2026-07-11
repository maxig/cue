# Cue — Review Findings & Implementation Plan

> Prepared for the next implementation pass ("Opus plan"). Based on a full read of the
> macOS app (`Cue/`), the local Node backend (`server/`), and the Cloudflare Worker
> (`cloudflare/`), plus research into segmented recording and Loom's current feature set.
>
> Three parts:
> **A** — bugs & issues found in the current code (prioritized, with file references).
> **B** — design for segmented ("chunked") recording + resilient/streaming upload.
> **C** — Loom feature-gap analysis and which missing features are essential.
>
> A suggested execution order is at the end.

---

## Part A — Bugs & issues to fix

### P0 — data loss / correctness

#### A1. A crash or force-quit mid-recording loses the entire recording
- `screen.mov` is written by `AVAssetWriter` with no `movieFragmentInterval`
  (`Cue/Capture/ScreenRecorder.swift:91`). Without movie fragments, the `moov` atom is
  only written in `finishWriting` — if the app crashes, the Mac sleeps/panics, or the
  user force-quits, the file on disk is unreadable and the whole session is gone.
- Even when raw files survive, the recording is invisible: `store.upsert(recording)` only
  runs at the end of `RecordingEngine.stop()` (`Cue/Recording/RecordingEngine.swift:304`),
  so an interrupted session leaves an orphan UUID folder in `~/Movies/Cue` that the
  library never shows and nothing ever cleans up or recovers.
- **Fix (minimum):** set `writer.movieFragmentInterval = CMTime(seconds: 5, ...)` before
  `startWriting()` so a partial `screen.mov` is playable up to the last fragment
  (`AVCaptureMovieFileOutput` used for `camera.mov` already defaults to 10 s fragments).
  Then add a startup recovery scan (see B2) so orphan folders are surfaced as
  recoverable recordings instead of silently leaking disk.
- This is the cheap half of the segmentation work in Part B — do it first regardless.

#### A2. `Recording.duration` includes paused time (and countdown edge cases)
- `RecordingEngine.stop()` computes `duration = Date().timeIntervalSince(start)`
  (`Cue/Recording/RecordingEngine.swift:210`) and never subtracts `pausedWallTotal`
  (nor a still-open pause). The composer *does* excise pauses, so the metadata duration
  disagrees with `final.mp4` — wrong in the library row, wrong in the
  `durationSeconds` sent to the backend, wrong on the share page.
- **Fix:** compute duration from the composition timeline (content start → stop, minus
  `pausedWallTotal` and any open pause span) — essentially `compositionNow()` at stop
  time; or better, read the composed asset's actual duration after compose and use that.

#### A3. Cancel-during-start race can leak a running capture stream
- `RecordingEngine.start()` sets `currentID` synchronously, then suspends at
  `makeFilterAndSize` / `screenRecorder.start()` awaits
  (`Cue/Recording/RecordingEngine.swift:94-110`). If the user cancels the countdown
  right then, `cancel()` interleaves at the suspension point: it sees `usedScreen ==
  false`, skips `screenRecorder.stop()`, deletes the folder, and resets. `start()` then
  resumes, finishes starting the SCStream, and returns — leaving ScreenCaptureKit
  capturing into a deleted folder with the app in `.idle` (recording indicator visible
  in macOS menu bar, purple dot, no way to stop it without relaunch).
- **Fix:** make start/cancel race-safe — e.g. a monotonically increasing session
  generation captured at `start()` entry, re-checked after every `await` (abort and
  stop the recorder if superseded), or have `cancel()` await the in-flight start task
  before tearing down.

#### A4. Camera-only recordings: mic mute causes permanent audio desync
- `CameraEngine.setMicMuted` disables the audio connection on `movieOutput`
  (`Cue/Capture/CameraEngine.swift:208-216`). Dropped samples leave a *gap* in the audio
  track that players collapse — after unmuting, all subsequent audio plays early and
  drifts out of sync. This is exactly the bug that was correctly solved in
  `ScreenRecorder` by writing silence instead of dropping buffers
  (`Cue/Capture/ScreenRecorder.swift:246-282`), but camera-only mode still has it.
- **Fix:** record camera-only through an `AVAssetWriter` pipeline (reusing the silence
  injection), or keep `AVCaptureMovieFileOutput` and don't disable the connection —
  instead capture audio via a data output and silence it. (Moving camera-only capture to
  the same writer-based path as the screen also unlocks segmenting in Part B.)

#### A5. Keep-alive frame re-emission retains ScreenCaptureKit pool buffers
- `handleVideo` stores `lastVideoBuffer = CMSampleBufferGetImageBuffer(...)`
  (`Cue/Capture/ScreenRecorder.swift:404`) and the keep-alive timer re-wraps and
  re-appends that same `CVImageBuffer` (`:201-221`). Two problems:
  1. SCK vends IOSurface-backed buffers from a small pool (`queueDepth = 6`); holding one
     indefinitely can starve the stream and stall frame delivery.
  2. SCK may recycle/overwrite the surface while the encoder still reads it → torn or
     stale frames written during static-screen stretches.
- **Fix:** deep-copy the pixel buffer (a pooled `CVPixelBufferCreate` + copy, or
  `VTPixelTransferSession`) once when it becomes the "last frame", and re-emit the copy.

#### A6. Thread-safety races around writer/camera state
- `ScreenRecorder.firstFrameAnchor` is written on the capture queue (`:386`) and read
  from the MainActor in `RecordingEngine.stop()`; `sessionStarted` is read for `Result`
  (`:332`) outside the queue; `CameraEngine.recordingStartAnchor` is written on an
  AVFoundation delegate queue (`:279`) and read on the MainActor; `stopContinuation` is
  set on `sessionQueue` and consumed on the delegate callback queue (`:224`, `:286-289`).
  These are real data races (TSan will flag them) even if they mostly work today.
- **Fix:** confine each to its queue and expose values via a small `queue.sync` accessor,
  or make them atomics / `OSAllocatedUnfairLock`-protected. For `stopContinuation`, also
  handle the *spontaneous* stop case (disk full, camera unplugged):
  `fileOutput(_:didFinishRecordingTo:error:)` currently ignores `error` entirely — a
  truncated camera track should surface an error and mark the recording accordingly.

#### A7. Local Node server does not match the app or the README
- `server/index.js` implements only `POST /api/videos`, `GET /api/videos(/:id)`, `/v/:id`
  and `/`. The app's owner actions call `DELETE /api/videos/:id` and
  `POST /api/videos/:id/(enable|disable)` (`Cue/Upload/CueBackendUploadService.swift:95-103`)
  — these 404 against the Node server.
- No auth at all, no `disabled` flag: every registered link is live immediately, `GET /`
  and `GET /api/videos` publicly list the entire catalog. The README's security section
  ("fail-closed", "links off by default", "no public catalog") is only true of the
  Worker. After upload the app also marks the recording `.disabled(url:)`
  (`Cue/App/AppState.swift:494`) — against the Node backend that's wrong: the link works.
- **Fix:** port the Worker's owner-token gate, `disabled` column, delete/enable/disable
  endpoints, and private landing page to `server/index.js` (it's advertised as mirroring
  the Worker API). Also add the missing `audioKey`/`bytes` fields it currently drops.

### P1 — reliability / consistency

#### A8. Upload pipeline has no retry, no resume, and a poor failure mode
- One monolithic SigV4 `PUT` per file (`Cue/Upload/MinIOUploadService.swift:51-85`); any
  network blip at 99 % restarts from zero (this is the second half of Part B).
- In `CueBackendUploadService.upload`, if the *audio sidecar* upload or the metadata
  registration fails after the video PUT succeeded, the whole share is marked failed and
  the uploaded video is orphaned in the bucket (`Cue/Upload/CueBackendUploadService.swift:29-47`).
  **Fix:** treat the sidecar as best-effort (register without `audioKey`), and make
  registration retryable; on definitive failure, delete the uploaded object.
- `AppState.delete` fires the remote delete and forgets it
  (`Cue/App/AppState.swift:547-553`); if it fails, the cloud copy + link stay alive with
  no local record to manage them. **Fix:** await it, surface failure, and/or add a
  reconcile pass that lists `/api/videos` and flags cloud objects with no local entry.

#### A9. Worker transcription will exhaust memory long before its own limit
- `transcribe()` pulls the whole object into an `ArrayBuffer`, then base64-encodes via
  string concatenation (`cloudflare/src/index.js:446-447`, `:510-518`) — peak memory is
  ~3–4× object size. The 100 MB `MAX_TRANSCRIBE_BYTES` cap is far beyond a Worker's
  128 MB memory; in practice this OOMs above roughly 20–25 MB.
- **Fix:** lower the cap to ~20 MB for the inline path, and prefer the audio sidecar
  (already done) — a 20 MB AAC sidecar ≈ 17+ minutes, fine for v1. Longer term, chunk
  the audio and transcribe segments.
- Related: **nothing ever calls `/transcribe`** — not the app, not the dashboard. The
  feature is curl-only despite the README presenting it as a product feature. See C3.

#### A10. Presigned media URLs expire mid-viewing
- When R2 credentials are configured, `/v/:id` embeds a presigned URL with a 30-minute
  TTL (`cloudflare/src/index.js:99-110`). A viewer who pauses, or seeks after the TTL,
  gets failing range requests with no recovery.
- **Fix:** have the player refetch the page / a `GET /v/:id/media-url` endpoint on video
  element `error`, or fall back to `/file/` proxying (which is already fail-closed).

#### A11. Assorted smaller defects
1. **Stale open-pause accounting at stop** — `RecordingEngine.stop()` appends the open
   pause span *without* adding it to `pausedWallTotal` (`RecordingEngine.swift:231-234`),
   then calls `compositionNow()` (`:251`) which no longer subtracts it → a camera-off
   range that is still open when stopping while paused ends too late.
2. **Window capture uses the wrong display's scale factor** —
   `makeFilterAndSize` uses `NSScreen.main` scale for windows
   (`RecordingEngine.swift:325`); a window on a non-retina external display records at
   2× (or vice versa). Resolve the window's actual screen.
3. **MinIO endpoint with a trailing slash breaks SigV4** — `base.absoluteString + path`
   yields `//bucket/key` while the signature is computed over `/bucket/key`
   (`MinIOUploadService.swift:68-70`) → hard-to-debug 403. Normalize the endpoint.
4. **`mixed.caf` is never deleted** — the PCM mixdown (~11 MB/min) stays in the
   recording folder forever (`VideoComposer.swift:526-531`). Delete after export.
5. **Elapsed timer drifts** — `elapsed += 1` per `Timer` tick
   (`AppState.swift:459-467`) accumulates drift on long recordings; derive elapsed from
   anchors instead.
6. **`formattedDuration` has no hours** (`Recording.swift:74-79`) — a 90-minute video
   shows "90:00".
7. **`.area` capture mode is dead** — the mode exists in the model and README
   ("selected region"), but the UI never offers it (`RecorderPopoverView.swift:98-105`)
   and the engine records the *full display* for `.area`
   (`RecordingEngine.swift:319-343`, `default` branch). Either implement region capture
   (`SCStreamConfiguration.sourceRect` + a drag-select overlay) or stop advertising it.
   Implement — Loom/Cap both have it and users expect it (see C6).
8. **Re-registering a video force-disables its link** — `POST /api/videos` upsert sets
   `disabled=1` on conflict (`cloudflare/src/index.js:217-223`); a re-upload of an
   enabled recording silently kills the live link. Preserve the existing `disabled`
   value on update (privacy default only for new rows).
9. **Shared `HTTPUploader` progress handler** — one `uploader` instance per service with
   a mutable `progressHandler` (`MinIOUploadService.swift:185-208`) breaks if two
   uploads ever run concurrently. Make the uploader per-call.
10. **Deprecated export API** — `exportAsynchronously` + `status` polling
    (`VideoComposer.swift:421-425`) is deprecated on macOS 15; migrate to
    `export(to:as:)` / `states(updateInterval:)` which also gives **export progress**
    the UI currently can't show.
11. **Worker CORS is `*` on everything** including owner-token responses
    (`cloudflare/src/index.js:17-21`) — harmless today (token comes from the app), but
    tighten to the app's needs when cookies/analytics arrive.

---

## Part B — Segmented recording & resilient upload (the "chunking" request)

Goal, restated: (1) if anything goes wrong mid-session — crash, kernel panic, battery
death — the user keeps everything captured up to that moment; (2) uploads should be
chunk-based so a flaky network never restarts a big file, and ultimately the upload can
*overlap* the recording, Loom-style, so the link is ready near-instantly.

Research grounding:
- Apple ships first-class APIs for this: `AVAssetWriter` fragmented-MP4 output
  (`outputFileTypeProfile = .mpeg4AppleHLS`, `preferredOutputSegmentInterval`,
  `AVAssetWriterDelegate.assetWriter(_:didOutputSegmentData:segmentType:segmentReport:)`)
  — designed exactly for producing streamable segments during live capture
  ([WWDC20 "Author fragmented MPEG-4 content with AVAssetWriter"](https://developer.apple.com/videos/play/wwdc2020/10011/),
  [`preferredOutputSegmentInterval` docs](https://developer.apple.com/documentation/avfoundation/avassetwriter/preferredoutputsegmentinterval)).
- For plain `.mov` files, [`movieFragmentInterval`](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval?language=objc)
  makes a partially-written file openable up to the last fragment boundary — the
  cheapest possible crash insurance.
- Cap (the other open-source Loom) validated the product shape: its "instant mode"
  uploads HLS segments as they're recorded and the link is watchable while recording
  ([Cap repo](https://github.com/CapSoftware/cap)).
- R2 and MinIO both speak S3 multipart (`CreateMultipartUpload` / `UploadPart` /
  `CompleteMultipartUpload`), min part size 5 MiB except the last part
  ([R2 upload docs](https://developers.cloudflare.com/r2/objects/upload-objects/)) — so
  resumable chunked upload works on both existing backends with the app's existing
  SigV4 signer (it needs query-string signing + the three extra operations).

### B1 — Crash-safe files (do first, ~1 day)
1. Set `movieFragmentInterval = 5s` on the screen `AVAssetWriter`
   (`ScreenRecorder.swift:91`). `camera.mov` via `AVCaptureMovieFileOutput` already
   defaults to 10 s fragments — set it explicitly to 5 s for symmetry.
2. Write a **session manifest** (`session.json`) into the recording folder at record
   start, and update it incrementally on every state change (content-start anchor,
   pause spans, camera-toggle ranges, mode, bubble prefs). Today all of that lives only
   in `RecordingEngine` memory — without it, surviving raw files can't be composed
   correctly after a crash.

### B2 — Recovery flow (~1–2 days)
On launch, scan `~/Movies/Cue` for UUID folders that are not in `index.json`:
- If raw tracks + `session.json` exist → offer "Recover recording?" — run the normal
  `VideoComposer.compose` from the manifest data and insert into the library.
- If files are unusable → offer to reveal/delete (never silently delete).
This also fixes the existing orphan-folder leak from failed/cancelled sessions (A1).

### B3 — Resumable chunked upload of finished files (~2–3 days)
Replace the monolithic PUT in `MinIOUploadService` with S3 multipart:
- `CreateMultipartUpload` → N × `UploadPart` (8–16 MiB parts, ≥5 MiB minimum) →
  `CompleteMultipartUpload`; abort on cancel.
- Per-part retry with exponential backoff; only failed parts are re-sent.
- Persist upload state (`uploadId`, completed part ETags) in the recording folder, so an
  app restart resumes instead of restarting. Files under ~8 MiB keep the simple PUT.
- Wire a "Retry upload" that resumes, and show part-level progress (the current
  progress callback plumbing can stay).

### B4 — Loom-style streaming upload during recording (the big one, ~1–2 weeks)
This is the feature that makes the link ready the moment the user stops:

1. **Segmented capture.** Switch `ScreenRecorder` to fMP4 segment output:
   `outputFileTypeProfile = .mpeg4AppleHLS`, `preferredOutputSegmentInterval = 6s`,
   implement `AVAssetWriterDelegate` and receive `(initialization segment, media
   segments…)` as `Data` in memory. Write each segment to
   `<recording>/segments/` **and** hand it to the uploader queue. Segments on disk are
   themselves the crash-safety story (every closed segment is durable and playable) —
   strictly better than B1's movie fragments for the screen track. Do the same for the
   camera track once camera-only capture moves off `AVCaptureMovieFileOutput` (A4).
2. **Live upload.** A background queue uploads segments as they close (S3 `PUT` per
   segment — small objects, so plain PUTs with retry are fine; no multipart needed).
   Network gone? Segments accumulate on disk and the queue drains when connectivity
   returns — recording is never blocked by upload.
3. **Backend: "processing" state.** Register the video at record *start* with
   `status=recording`; the Worker stores segments under `<id>/segments/…` and the player
   page shows "Still recording / processing" (and can even serve an HLS playlist of the
   raw screen segments for a live-ish preview, which is exactly what Cap does).
4. **Finalize.** On stop, the app composes `final.mp4` as today (PiP, canvas, pause
   excision are *composition-time* features and still need the full tracks), uploads it
   via B3 multipart, then flips the backend record to `status=ready` and (optionally)
   garbage-collects the raw segments. Until then, the share page can already play the
   raw screen segments — the link is useful seconds after stopping, and even a crash
   mid-upload leaves a watchable (raw) video in the cloud.
5. **Settings switch.** "Instant link (upload while recording)" opt-in — self-hosters on
   metered links may prefer upload-after.

Recommended order: B1 → B2 → B3 ship value each on their own; B4 builds on all three.

---

## Part C — Loom feature-gap analysis (essentials to add)

Compared against Loom's current feature set (recorder, editing, player, library —
[Loom docs](https://support.atlassian.com/loom/docs/edit-your-loom-video/)) and what the
README/product doc already promise. Ordered by how essential each is to the core
"record → share a link" loop:

| # | Missing feature | Why it's essential | Notes |
|---|---|---|---|
| C1 | **Instant link on stop** | Loom's signature move: link is on the clipboard the moment you stop. Cue uploads with the link *disabled* and never copies it (`AppState.share`, `AppState.swift:476-503`); the popover's "Link copied" card can't even appear after a fresh recording since `lastShareURL` is only set by enable-link. | Add a setting: "After upload: copy link (enabled/disabled)". Privacy default can stay off-by-default, but one-click enable+copy must be in the stop flow, not buried in the library context menu. Full instant-ness comes from B4. |
| C2 | **Trim editing** | The single most-used post-record edit (cut the fumbled start/end). Loom, Cap and Screen Studio all have it; Cue has zero editing. | v1: trim-range UI over `AVPlayer` in the library detail; re-run `VideoComposer` with head/tail trim (it already supports `leadTrim` — add `tailTrim`), regenerate thumbnail/audio sidecar, re-upload if shared. Stitch/multi-cut later. |
| C3 | **Working transcription pipeline + captions** | Advertised in the README but unreachable (A9): nothing triggers `/transcribe`, and the player never renders `transcript_vtt` as captions. Loom auto-transcribes everything. | After register, the app (or the Worker itself via `ctx.waitUntil`) calls transcribe with the audio sidecar; player adds `<track kind="captions">` from a `/v/:id/captions.vtt` endpoint; dashboard gets a "Transcribe" button; library search matches transcript text. |
| C4 | **Global hotkey** | Start/stop without touching the menu bar — core to "zero friction", and already promised in `docs/PRODUCT.md` §4. | `KeyboardShortcuts`-style global hotkey (default e.g. ⌥⇧C) for start/stop + one for pause. Recording an app in full screen currently *requires* this. |
| C5 | **Rename recordings** | Every recording is stuck as "Cue · Jul 11, 2:41 PM" locally and on the share page. Basic library hygiene. | Editable title in library detail + popover card; `PATCH /api/videos/:id` (Worker + Node) to sync the share page. |
| C6 | **Region ("area") capture** | Advertised in the README, half-exists in the model, records the wrong thing (A11.7). | Drag-select overlay → `SCStreamConfiguration.sourceRect` on the display filter; re-enable the `.area` segment in the popover. |
| C7 | **View analytics** | Loom's "who watched" is a top-3 retention feature. Cue has literally no signal a link was opened. | v1: view count + last-viewed per video (D1 `views` column bumped in `/v/:id`), shown in library + dashboard. Watch-completion heatmaps later. |
| C8 | **Player completeness: download, speed, poster, title** | Viewers expect download (owner-toggleable), playback speed, a poster frame (thumbnail is generated but never uploaded), and the real title. | Upload `thumb.jpg` alongside video (`thumbKey`), `poster=` on the `<video>`, speed menu in the player JS, `?download` route. |
| C9 | **Link security options** | Loom: password-protected links + expiry. Cue's only knob is on/off. | `password_hash`, `expires_at` columns; player prompts for password; app UI to set them. Fits the existing owner-token model. |
| C10 | **Comments & emoji reactions** | Already stubbed in the player UI (`views.js` reactions row is `aria-hidden`) and on the roadmap; the essential async-video conversation loop. | Phase 3 as planned — needs viewer identity (name-only is fine), `comments` table, timestamped reactions. Keep after C1–C9. |
| C11 | **Recording robustness guards** | Loom caps/warns rather than dying: no disk-space check before/during recording, no max-duration guard, no low-disk warning mid-session. | Pre-flight free-space check; warn at <2 GB; auto-stop gracefully at <500 MB. |
| C12 | **Drawing/click emphasis while recording** | Loom pencil / click highlights. Differentiator, not essential to the core loop. | Roadmap after Studio features; cursor smoothing & auto-zoom already tracked in PRODUCT.md Phase 2/3. |

Explicitly *not* recommended right now: team workspaces/SSO (Phase 3 in the product doc,
heavy backend work), AI summaries/chapters/filler-removal (Phase 2, depends on C3
landing first), and custom domains/white-label (cosmetic).

---

## Suggested execution order for Opus

Each block is intended to be a coherent, reviewable PR.

1. **Correctness batch (Part A P0):** A2 duration fix, A3 start/cancel race, A5 buffer
   copy, A6 thread-safety, A11.1–.3 small engine fixes. Pure fixes, no behavior change.
2. **Crash safety (B1 + B2):** movie fragments, session manifest, launch recovery scan.
   This directly answers the "user still has a part of it if something goes wrong"
   requirement.
3. **Backend parity & hygiene (A7, A8, A9-cap, A10, A11.8):** Node server parity +
   auth, sidecar/registration failure handling, transcribe memory cap, presigned-URL
   refresh, upsert keeps `disabled`.
4. **Resumable uploads (B3):** S3 multipart with persisted resume state + retry.
5. **Essential features, wave 1 (C1, C4, C5, C6, C8, C11):** instant-link flow, global
   hotkey, rename, region capture, player completeness, disk guards.
6. **Transcription pipeline (C3)** — auto-trigger, captions track, transcript search.
7. **Trim editing (C2).**
8. **Streaming upload / instant link while recording (B4)** — the Loom-parity
   centerpiece; land last since it builds on 2 + 4 and touches capture, upload, Worker,
   and player.
9. **Analytics + link security (C7, C9)**, then **comments/reactions (C10)**.

### Sources
- [WWDC20 — Author fragmented MPEG-4 content with AVAssetWriter](https://developer.apple.com/videos/play/wwdc2020/10011/)
- [AVAssetWriter.preferredOutputSegmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/preferredoutputsegmentinterval)
- [AVAssetWriter.movieFragmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval?language=objc)
- [Cloudflare R2 — Upload objects (multipart rules)](https://developers.cloudflare.com/r2/objects/upload-objects/)
- [Cap — open-source Loom alternative (segmented instant mode)](https://github.com/CapSoftware/cap)
- [Loom — Edit your video (trim/stitch feature set)](https://support.atlassian.com/loom/docs/edit-your-loom-video/)
- [Loom — product investments / feature overview](https://support.atlassian.com/loom/docs/looms-recent-product-investments/)
