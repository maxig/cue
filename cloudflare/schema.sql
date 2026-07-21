-- Cue metadata store (D1 / SQLite). Mirrors the shape of server/db.json so the
-- Worker and the Node server expose an identical API.

CREATE TABLE IF NOT EXISTS videos (
  id               TEXT    PRIMARY KEY,
  title            TEXT    NOT NULL DEFAULT 'Untitled Cue',
  duration_seconds REAL    NOT NULL DEFAULT 0,
  object_key       TEXT    NOT NULL,
  audio_key        TEXT,             -- audio-only sidecar (audio.m4a) for transcription
  bytes            INTEGER NOT NULL DEFAULT 0,   -- R2 footprint (video + audio), drives the storage cap
  width            INTEGER NOT NULL DEFAULT 0,
  height           INTEGER NOT NULL DEFAULT 0,
  capture_mode     TEXT    NOT NULL DEFAULT 'screen',
  created_at       TEXT    NOT NULL,
  disabled         INTEGER NOT NULL DEFAULT 1,   -- share link OFF by default; owner enables it
  transcript       TEXT,             -- plain text, populated on demand by Whisper
  transcript_vtt   TEXT,             -- WebVTT with segment timing, optional
  summary          TEXT,             -- AI summary (Llama via Workers AI), on demand
  title_updated_at TEXT,             -- independent clocks for native/web reconciliation
  transcript_updated_at TEXT,
  summary_updated_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_videos_created_at ON videos (created_at DESC);

-- Viewer comments on a shared recording (Loom-style). Public viewers post these
-- from the player page; the owner moderates from /app/v/:id. ts_seconds pins a
-- comment to a position in the video. Rows are removed explicitly when a video
-- is deleted/evicted (D1 doesn't enforce ON DELETE CASCADE by default).
CREATE TABLE IF NOT EXISTS comments (
  id          TEXT PRIMARY KEY,
  video_id    TEXT    NOT NULL,
  author      TEXT    NOT NULL DEFAULT 'Anonymous',
  body        TEXT    NOT NULL,
  viewer_id   TEXT,                       -- anonymous browser id (localStorage) for delete-own
  ts_seconds  REAL,                       -- video position the comment is pinned to (nullable)
  created_at  TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_comments_video ON comments (video_id, created_at);

-- Emoji reactions. One row per (video, emoji, viewer) so a viewer can toggle each
-- emoji on/off; aggregate counts come from GROUP BY emoji.
CREATE TABLE IF NOT EXISTS reactions (
  id          TEXT PRIMARY KEY,
  video_id    TEXT    NOT NULL,
  emoji       TEXT    NOT NULL,
  viewer_id   TEXT    NOT NULL,           -- anonymous browser id (localStorage)
  created_at  TEXT    NOT NULL,
  UNIQUE (video_id, emoji, viewer_id)
);
CREATE INDEX IF NOT EXISTS idx_reactions_video ON reactions (video_id);
