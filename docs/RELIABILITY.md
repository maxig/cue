# Recording reliability and upload design

This document records the failure model used by Cue. The local recording is the
source of truth; cloud storage is a replaceable copy.

## What Cue now guarantees

- `screen.mov` is written as a fragmented QuickTime movie. The first fragment is
  flushed after roughly one second and later fragments every ten seconds.
- `camera.mov` uses two-second movie fragments. After a process or OS crash, all
  completed fragments remain usable; only the active fragment may be lost.
- An atomic `recovery.json` journal is created before capture starts. If Cue did
  not reach the normal Library commit, the next launch imports any usable raw
  screen/camera tracks instead of leaving an invisible UUID folder.
- `index.json` is atomic and keeps `index.backup.json`. A corrupt primary index is
  restored from the backup. Local deletion moves media to Finder Trash.
- Quitting normally waits for active capture/composition to finish. Network
  uploads do not block quit because their state is independently checkpointed.
- Large S3/R2/MinIO uploads use uniform 16 MiB multipart parts, three concurrent
  lanes, and retries for transient HTTP/network failures. Upload id + ETags are
  saved beside the recording after every completed part.
- A completed-object checkpoint remains until backend metadata reaches `ready`
  *and* the local Library saves that state. If registration or the local index
  fails after a 2 GB upload, retrying does not send those 2 GB again. A process
  exit leaves the recording in `uploading`; launch resumes it.
- The backend entity and stable `/v/<id>` URL are created before bytes move.
  That page polls a minimal status endpoint and changes from a waiting state to
  the player when multipart completion is globally visible.
- Final MP4s are optimized for network playback, and capture bitrate is capped at
  24 Mbps (rather than 40 Mbps) to reduce upload size without changing format or
  sacrificing H.264 browser compatibility.

## Intentional limits

- Cue still composes `final.mp4` locally before upload. True Loom-style upload
  *during* recording would require uploading source fragments and a durable
  server-side assembly/transcode workflow. It is a worthwhile next phase, but it
  changes the current promise that the bucket receives a ready-to-play final.
- A force quit in the first second of screen capture, or before the first camera
  fragment, may leave no playable media. Fragment intervals bound this window;
  no file-based recorder can guarantee bytes that the OS has not flushed.
- Recovered interrupted recordings prefer raw tracks. Pause ranges, countdown
  trim, and camera placement live in memory during an active session, so a crash
  recovery may require a manual trim and may not include the camera overlay.
- The local Express backend deletes metadata but cannot delete MinIO objects
  without server-side S3 credentials. Use the Cloudflare backend for complete
  remote deletion, or remove the object from MinIO separately.

## Required release verification

The Xcode build and backend tests do not exercise real devices. Before release:

1. Record for about one minute: pause for five seconds, resume, mute for five
   seconds, unmute, hide/show camera, then stop. Check end-of-clip A/V sync,
   duration, every track, and the absence of frozen/black spans.
2. During a second recording, force-quit Cue after at least 15 seconds. Relaunch
   and confirm a **Recovered** Library item plays up to the final fragment.
3. Upload a file larger than 64 MiB, interrupt the network after several parts,
   retry, and confirm the completed-part count resumes rather than returning to 0.
4. Open the copied share URL during upload. Confirm it shows the waiting page,
   then turns into the player without changing URL. Repeat with an upload failure.
5. Quit during upload, relaunch, and confirm automatic resume. Verify a metadata
   failure after object completion does not retransmit the media object.
6. Download `/download` on the deployed landing page and confirm it resolves to
   the signed/notarized `Cue.dmg` stable asset from the latest GitHub release.
